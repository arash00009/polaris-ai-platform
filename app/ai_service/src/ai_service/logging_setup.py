"""Logging for the service: one place that decides what a log line looks like.

Two formats, chosen with POLARIS_LOG_FORMAT:

* ``text`` (default, for a developer terminal): ``time LEVEL logger message key=value ...``
* ``json`` (the container image sets this): one JSON object per line, which log pipelines
  (Loki in Phase 10) can parse without regular expressions.

Only fields on an allow-list are ever written from a log call's ``extra``. That is a safety
net for the rule "prompts are never logged": even if someone later writes
``logger.info("...", extra={"prompt": text})``, the prompt does not reach the output.
"""

import json
import logging
import re
import sys
from datetime import UTC, datetime
from typing import Final

SERVICE_NAME: Final = "ai-service"

# The only structured fields that may appear in a log line. There is deliberately no "prompt".
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
)

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
