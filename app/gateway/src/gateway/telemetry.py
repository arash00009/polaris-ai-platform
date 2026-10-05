"""Wires metrics, traces and logs onto the gateway's FastAPI app.

Near-identical to ai_service/telemetry.py (Phase 9/10) -- same exporter-level span-attribute
filtering, same log-attribute allow-list filter, same reasoning for both (see that module's own
docstring for the full "why", not repeated here). What is new in THIS phase, and is the actual
point of this module existing at all: docs/architecture.md section 10 says cross-service trace
propagation was "explicitly deferred to Phase 12 -- ai_service is still the only service in
this project" (Phase 10's handoff). That gap closes here, and not through any code in this
file: FastAPIInstrumentor.instrument_app() on *this* process extracts the inbound traceparent
header automatically (OpenTelemetry's W3C Trace Context propagator is on by default), so the
span this process starts for an incoming request is already a *child* of whatever span created
it one hop further toward the client (none yet -- clients are not instrumented in this
project). The other half -- making the span this process creates for its *outbound* call to
ai_service carry a traceparent header the far side can pick up -- is HTTPXClientInstrumentor's
job, wired up in main.py next to the httpx.AsyncClient construction, not here. One request
hitting POST /v1/chat through the gateway therefore produces two linked spans (gateway, then
ai_service) under one trace_id, instead of Phase 10's single-service trace -- confirmed in the
sandbox with test_main.py's test_trace_propagation; real confirmation against Tempo is this
phase's target-machine step.
"""

import logging
from collections.abc import Sequence
from typing import Final

from fastapi import FastAPI
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SpanExporter
from prometheus_client import CollectorRegistry
from prometheus_fastapi_instrumentator import Instrumentator

from gateway import __version__
from gateway.config import Settings
from gateway.logging_setup import LOG_FIELDS

SERVICE_NAME = "ai-gateway"

_TRACER_PROVIDER_ATTR = "otel_tracer_provider"
_LOGGER_PROVIDER_ATTR = "otel_logger_provider"

# Same allow-list as ai_service/telemetry.py (docs/architecture.md section 6) -- this process
# never sets model/model_version/prompt_version/prompt_tokens/completion_tokens itself (that
# remains ai_service's job on its own span), but filtering to the same list, rather than a
# gateway-specific subset, keeps there being exactly one allow-list for the whole platform to
# keep in sync by hand (see logging_setup.py's module docstring on why a second one still
# exists for *log* fields: the two lists cover different signals and have never drifted).
SPAN_ATTRIBUTE_ALLOWLIST: Final[frozenset[str]] = frozenset(
    {
        "tenant_id",
        "request_id",
        "model",
        "model_version",
        "prompt_version",
        "endpoint",
        "http.status_code",
        "latency_ms",
        "prompt_tokens",
        "completion_tokens",
    }
)

_ROUTE_TEMPLATE_ATTR = "http.route"
_ENDPOINT_ATTR = "endpoint"


class _FilteringSpanExporter(SpanExporter):
    def __init__(self, wrapped: SpanExporter) -> None:
        self._wrapped = wrapped

    def export(self, spans: Sequence[ReadableSpan]):
        filtered = [self._filtered(span) for span in spans]
        return self._wrapped.export(filtered)

    @staticmethod
    def _filtered(span: ReadableSpan) -> ReadableSpan:
        attributes = dict(span.attributes or {})
        if _ROUTE_TEMPLATE_ATTR in attributes:
            attributes[_ENDPOINT_ATTR] = attributes[_ROUTE_TEMPLATE_ATTR]
        curated = {
            key: value for key, value in attributes.items() if key in SPAN_ATTRIBUTE_ALLOWLIST
        }
        return ReadableSpan(
            name=span.name,
            context=span.context,
            parent=span.parent,
            resource=span.resource,
            attributes=curated,
            events=span.events,
            links=span.links,
            kind=span.kind,
            status=span.status,
            start_time=span.start_time,
            end_time=span.end_time,
            instrumentation_scope=span.instrumentation_scope,
        )

    def shutdown(self) -> None:
        self._wrapped.shutdown()

    def force_flush(self, timeout_millis: int = 30000) -> bool:
        return self._wrapped.force_flush(timeout_millis)


class _LogAttributeAllowlistFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        reserved = _RESERVED_LOG_RECORD_ATTRS
        for key in [k for k in vars(record) if k not in reserved and k not in LOG_FIELDS]:
            delattr(record, key)
        return True


_RESERVED_LOG_RECORD_ATTRS: Final[frozenset[str]] = frozenset(
    vars(logging.LogRecord("x", logging.INFO, "x", 0, "x", None, None))
)


def setup_telemetry(app: FastAPI, settings: Settings) -> None:
    Instrumentator(registry=CollectorRegistry()).instrument(app).expose(
        app, endpoint="/metrics", include_in_schema=False
    )

    if not settings.otel_enabled:
        return

    resource = Resource.create(
        {
            "service.name": SERVICE_NAME,
            "service.version": __version__,
            "deployment.environment": settings.environment,
        }
    )
    endpoint = settings.otel_exporter_otlp_endpoint.rstrip("/")
    timeout = settings.otel_exporter_timeout_s

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(
            _FilteringSpanExporter(
                OTLPSpanExporter(endpoint=f"{endpoint}/v1/traces", timeout=timeout)
            )
        )
    )

    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=f"{endpoint}/v1/logs", timeout=timeout))
    )

    otel_handler = LoggingHandler(logger_provider=logger_provider)
    otel_handler.addFilter(_LogAttributeAllowlistFilter())
    logging.getLogger("gateway").addHandler(otel_handler)

    FastAPIInstrumentor.instrument_app(app, tracer_provider=tracer_provider)

    setattr(app.state, _TRACER_PROVIDER_ATTR, tracer_provider)
    setattr(app.state, _LOGGER_PROVIDER_ATTR, logger_provider)


def shutdown_telemetry(app: FastAPI) -> None:
    tracer_provider = getattr(app.state, _TRACER_PROVIDER_ATTR, None)
    if tracer_provider is not None:
        tracer_provider.shutdown()

    logger_provider = getattr(app.state, _LOGGER_PROVIDER_ATTR, None)
    if logger_provider is not None:
        logger_provider.shutdown()
        app_logger = logging.getLogger("gateway")
        for handler in list(app_logger.handlers):
            if isinstance(handler, LoggingHandler):
                app_logger.removeHandler(handler)
