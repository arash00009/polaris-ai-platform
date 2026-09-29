"""Logging for the service: one place that decides what a log line looks like.

Two formats, chosen with POLARIS_LOG_FORMAT:

* ``text`` (default, for a developer terminal): ``time LEVEL logger message key=value ...``
* ``json`` (the container image sets this): one JSON object per line, which log pipelines
  (Loki in Phase 10) can parse without regular expressions.

Only fields on an allow-list are ever written from a log call's ``extra``. That is a safety
net for the rule "prompts are never logged": even if someone later writes
``logger.info("...", extra={"prompt": text})``, the prompt does not reach the output.

Phase 10 (OpenTelemetry) reuses this exact allow-list -- not a second, parallel one -- to also
curate what reaches the OTel-exported copy of these same log lines (see
``telemetry._LogAttributeAllowlistFilter`` in ``ai_service/telemetry.py``). Before Phase 10, this
module's filtering only protected stdout; a value passed via ``extra`` that was not in
LOG_FIELDS was silently dropped from the terminal/container log but was *not* dropped from what
OpenTelemetry's ``LoggingHandler`` sends to Loki, since that handler reads a log record's raw
``extra`` fields directly and has no knowledge of this list. One allow-list, enforced on both
paths, closes that gap and means there is only one place to update when a new safe field is
added.

Phase 10 also adds ``trace_id``/``span_id`` to this list (see ``TraceContextFilter`` below): a
deliberate way to correlate a line in ``kubectl logs``/stdout directly with a trace in Tempo,
without first having to go through Loki. Both are hex strings taken from the OpenTelemetry span
that is active (if any) when the log call happens, and are simply absent from a line logged
outside of any span, or whenever ``POLARIS_OTEL_ENABLED=false`` (no span is ever started, so
there is nothing to attach).
"""

import json
import logging
import re
import sys
from datetime import UTC, datetime
from typing import Final

from opentelemetry import trace

SERVICE_NAME: Final = "ai-service"

# The only structured fields that may appear in a log line -- on stdout AND (from Phase 10) in
# what is exported to Loki over OTLP. There is deliberately no "prompt".
LOG_FIELDS: Final[tuple[str, ...]] = (
    "request_id",
    "tenant_id",
    "model",
    "latency_ms",
    "prompt_tokens",
    "completion_tokens",
    "code",
    "reason",
    "method",
    "path",
    "status",
    "duration_ms",
    # Phase 10: log<->trace correlation. See TraceContextFilter below.
    "trace_id",
    "span_id",
)


class TraceContextFilter(logging.Filter):
    """Stamps ``trace_id``/``span_id`` onto every log record from the OpenTelemetry span that is
    active when the record is created, if any.

    Installed on the root stdout handler (unconditionally -- see ``configure_logging`` below),
    not only on the OTel log handler, so a stdout/``kubectl logs`` line carries the same
    correlation id as its OTel-exported copy in Loki. Cheap and side-effect-free when
    ``POLARIS_OTEL_ENABLED=false``: ``trace.get_current_span()`` is part of ``opentelemetry-api``
    (always installed, unlike the SDK pieces that are only used when OTel is enabled) and returns
    a non-recording span with an invalid context when no tracer provider ever started a real
    span, so nothing is added and no OTel SDK import is required here.

    Verified in the sandbox (test_telemetry.py): present, matching the exported span's ids, only
    for log lines emitted while a span is active; absent otherwise.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        span_context = trace.get_current_span().get_span_context()
        if span_context.is_valid:
            record.trace_id = format(span_context.trace_id, "032x")
            record.span_id = format(span_context.span_id, "016x")
        return True


# Marks the handler this module installs, so calling configure_logging twice replaces it
# instead of printing every line twice.
_HANDLER_MARK: Final = "_polaris_handler"

# Values matching this are printed bare in text format; anything else is JSON-quoted, which
# escapes newlines and quotes. A client-controlled value (such as a request path) can then
# not forge a second log line.
_BARE_VALUE = re.compile(r"[A-Za-z0-9._:/@+-]*")


def _fields_of(record: logging.LogRecord) -> dict[str, object]:
    return {name: record.__dict__[name] for name in LOG_FIELDS if name in record.__dict__}


def _render_value(value: object) -> str:
    if isinstance(value, str) and not _BARE_VALUE.fullmatch(value):
        return json.dumps(value)
    if isinstance(value, str) or value is None or isinstance(value, bool | int | float):
        return str(value)
    return json.dumps(str(value))


class TextFormatter(logging.Formatter):
    def __init__(self) -> None:
        super().__init__("%(asctime)s %(levelname)s %(name)s %(message)s")

    def formatMessage(self, record: logging.LogRecord) -> str:
        line = super().formatMessage(record)
        fields = _fields_of(record)
        if fields:
            line += " " + " ".join(f"{key}={_render_value(value)}" for key, value in fields.items())
        return line


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created, tz=UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "service": SERVICE_NAME,
            "message": record.getMessage(),
        }
        payload.update(_fields_of(record))
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        # ensure_ascii keeps the line pure ASCII, so no byte sequence can confuse a collector.
        return json.dumps(payload, default=str)


class _StdoutHandler(logging.StreamHandler):
    """Writes to whatever ``sys.stdout`` is at the moment of each call.

    A container runtime collects stdout. Looking it up on every emit (instead of remembering
    it once) also keeps tests safe when pytest swaps stdout for its own capture object.
    """

    def __init__(self) -> None:
        logging.Handler.__init__(self)

    @property
    def stream(self):
        return sys.stdout


def configure_logging(level: str, log_format: str) -> None:
    """Install one stdout handler on the root logger with the chosen format."""
    root = logging.getLogger()
    for existing in [h for h in root.handlers if getattr(h, _HANDLER_MARK, False)]:
        root.removeHandler(existing)

    handler = _StdoutHandler()
    handler.setFormatter(JsonFormatter() if log_format == "json" else TextFormatter())
    handler.addFilter(TraceContextFilter())
    setattr(handler, _HANDLER_MARK, True)
    root.addHandler(handler)
    root.setLevel(level)

    # uvicorn installs its own handlers (a different text format) on these loggers. Hand them
    # over to the root handler so startup and error lines use the same format as ours.
    for name in ("uvicorn", "uvicorn.error"):
        logger = logging.getLogger(name)
        logger.handlers.clear()
        logger.propagate = True

    # httpx logs every outgoing request URL at INFO. Not secret, but noise in a service log.
    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)
