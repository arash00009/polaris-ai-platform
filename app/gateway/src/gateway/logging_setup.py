"""Logging for ai-gateway. Deliberately near-identical to ai_service/logging_setup.py
(Phase 9/10, already tested there) -- same two formats, same allow-list discipline, same
TraceContextFilter for log<->trace correlation -- with only SERVICE_NAME and LOG_FIELDS changed
for this service's own fields. See gateway/config.py's module docstring for why this is a
duplicate module rather than a shared import: the two services are separate deployable units
with no shared library in this repo.

Not re-tested with a dedicated test_logging.py here: the formatting logic itself is unchanged
from the module it was copied from, which already has test coverage in app/ai_service/tests.
What IS specific to this module (LOG_FIELDS' contents) is exercised indirectly by every test
in this package that asserts on a log line's fields -- see test_main.py.
"""

import json
import logging
import re
import sys
from datetime import UTC, datetime
from typing import Final

from opentelemetry import trace

SERVICE_NAME: Final = "ai-gateway"

LOG_FIELDS: Final[tuple[str, ...]] = (
    "request_id",
    "tenant_id",
    "code",
    "reason",
    "method",
    "path",
    "status",
    "upstream_status",
    "duration_ms",
    "trace_id",
    "span_id",
)


class TraceContextFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        span_context = trace.get_current_span().get_span_context()
        if span_context.is_valid:
            record.trace_id = format(span_context.trace_id, "032x")
            record.span_id = format(span_context.span_id, "016x")
        return True


_HANDLER_MARK: Final = "_polaris_gateway_handler"
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
        return json.dumps(payload, default=str)


class _StdoutHandler(logging.StreamHandler):
    def __init__(self) -> None:
        logging.Handler.__init__(self)

    @property
    def stream(self):
        return sys.stdout


def configure_logging(level: str, log_format: str) -> None:
    root = logging.getLogger()
    for existing in [h for h in root.handlers if getattr(h, _HANDLER_MARK, False)]:
        root.removeHandler(existing)

    handler = _StdoutHandler()
    handler.setFormatter(JsonFormatter() if log_format == "json" else TextFormatter())
    handler.addFilter(TraceContextFilter())
    setattr(handler, _HANDLER_MARK, True)
    root.addHandler(handler)
    root.setLevel(level)

    for name in ("uvicorn", "uvicorn.error"):
        logger = logging.getLogger(name)
        logger.handlers.clear()
        logger.propagate = True

    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)
