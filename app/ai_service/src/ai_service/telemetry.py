"""Wires the three observability signals onto the FastAPI app: metrics, traces, logs.

Phase 9 (Observability) got real data flowing for all three signals, per docs/observability.md
and the Phase 0 roadmap's "Done when" wording for that phase ("Grafana shows metrics, logs,
traces and the required dashboards") -- confirmed on the target machine, 2026-09-25 (see
docs/troubleshooting.md).

Phase 10 (OpenTelemetry) scope, per the Phase 0 roadmap's exact wording ("One request traced
gateway/service/model with allow-listed attributes; logs<->traces correlated; cardinality
documented"): curate what Phase 9's spans and logs actually carry down to
docs/architecture.md section 6's allow-list, and make log<->trace correlation a deliberate,
tested property instead of an unexamined side effect. Propagating trace context *across*
service boundaries is explicitly not done here: there is only one service (`ai_service`) until
Phase 12's gateway exists, so there is nothing to propagate a trace across yet -- see "Known
gaps" in this phase's handoff. Three concrete things changed for this:

1. Span attributes. FastAPI's/OpenTelemetry's auto-instrumentation puts several attributes on
   every span that are useful for a browsable trace UI but are not on the architecture's
   allow-list -- ``net.peer.ip`` (a client IP; the allow-list says "Never ... unless explicitly
   justified", and nothing here justifies it), ``http.user_agent``, ``http.url``, ``http.scheme``,
   ``http.flavor``, ``http.host``, ``http.target``. ``_FilteringSpanExporter`` below wraps the
   real OTLP span exporter and rebuilds every finished span with only the allow-listed attribute
   names before it is handed to the real exporter, renaming ``http.route`` to ``endpoint`` (the
   allow-list's name for a route template) along the way. It also adds the attributes that
   nothing sets automatically -- ``tenant_id``, ``request_id``, ``model``, ``latency_ms``,
   ``prompt_tokens``, ``completion_tokens`` -- via explicit ``set_attribute()`` calls added to
   ``main.py``'s ``/v1/chat`` handler, since those are business fields no HTTP auto-instrumentor
   can know about.

   This is a span-*exporter*-level filter, not a span-*processor* one, and that was not a free
   choice: a SpanProcessor's ``on_end``/``_on_ending`` hooks both run after ``Span.end()`` has
   already marked the span's attributes immutable in this pinned SDK version
   (opentelemetry-sdk==1.44) -- verified for real in this phase's development by attempting the
   more obvious "processor that deletes disallowed keys" approach first and watching it raise
   ``TypeError`` on every deletion. Filtering in a wrapping ``SpanExporter`` instead, which
   receives the already-ended (but not yet serialized) spans and constructs fresh
   ``ReadableSpan`` copies with a trimmed ``attributes`` mapping, sidesteps that immutability
   entirely and was confirmed to work with a standalone script before it was written here.

2. Log attributes. ``ai_service/logging_setup.py``'s ``LOG_FIELDS`` allow-list already protected
   stdout from Phase 9 onward, but OpenTelemetry's ``LoggingHandler`` reads a log record's raw
   ``extra`` fields directly and had no knowledge of that list -- a field added to stdout's
   block-list would still have reached Loki over OTLP. ``_LogAttributeAllowlistFilter`` below
   closes that gap by reusing the exact same ``LOG_FIELDS`` tuple (one allow-list, not two) as a
   ``logging.Filter`` attached to the OTel log handler.

3. Log<->trace correlation. This already worked from Phase 9 onward as an unexamined side effect
   of OpenTelemetry's own machinery: ``LoggingHandler`` stamps the *active OTel context* onto
   every exported log record, and the OTLP log exporter derives ``trace_id``/``span_id`` from
   that context, so any log line emitted from inside a traced request already correlated with
   its trace in Tempo/Loki before this phase touched anything (this is how the real Loki<->Tempo
   correlation shown in docs/troubleshooting.md's Phase 9 section happened). What Phase 10 adds
   is: a dedicated, named test that pins this down as an intended property rather than an
   accident (test_telemetry.py), and ``TraceContextFilter`` in ``logging_setup.py``, which stamps
   the same ``trace_id``/``span_id`` onto *stdout* log lines too -- so ``kubectl logs`` alone,
   without going through Loki first, is enough to find the matching trace.

Metrics (always on, no configuration needed): prometheus-fastapi-instrumentator adds a
middleware that records one histogram/counter observation per request and exposes them at
GET /metrics in Prometheus text format. Its default label set is already cardinality-safe
(matches Phase 0's allow-list): "handler" is the route *template* ("/v1/chat"), never the raw
path, and "status" is grouped into a status_class ("2xx", "4xx", ...), never the raw status
code -- verified in the Phase 9 handoff with a real smoke test, not assumed from the docs.
Prometheus finds this endpoint via the ServiceMonitor in
helm/ai-platform/templates/servicemonitor.yaml (ADR-06: metrics by scrape, not push).

Traces and logs (POLARIS_OTEL_ENABLED, default false): OpenTelemetry's FastAPI
auto-instrumentation creates one span per request (also using the route template, not the raw
path) and a second logging.Handler exports the service's own log records over OTLP/HTTP. Both
go to the in-cluster OTel Collector (a plain Deployment, see deploy/platform/observability/),
which forwards spans to Tempo and logs to Loki. OTLP/HTTP was chosen over OTLP/gRPC on purpose:
it needs no grpcio dependency (see requirements.txt).

Both OTLP exporters are asynchronous: BatchSpanProcessor and BatchLogRecordProcessor hand
records to a background thread and export in batches on a timer. Verified in the Phase 9
handoff by pointing both at a closed port and timing real requests: an unreachable collector
adds no latency to a request and raises no exception, it only logs its own retry/failure
warnings. This is why POLARIS_OTEL_ENABLED can default to true in Helm values (see values.yaml)
even before the observability stack is installed, or if its pods are still starting.

Shutdown is a different story, and this was also caught for real rather than assumed: each
provider's shutdown() flushes its queue and retries the export with backoff before giving up,
and with the SDK's default 10s-per-export timeout that took roughly 8 seconds combined (trace +
log) against an unreachable endpoint in a real measurement. The Deployment's
terminationGracePeriodSeconds is 15, of which the preStop hook already spends 5 (see
helm/ai-platform/templates/deployment.yaml and values.yaml), leaving about 10 for the process to
actually receive SIGTERM, run this shutdown, and exit before Kubernetes sends SIGKILL -- an
unbounded (or even an 8-second) OTel shutdown could eat that whole remaining budget by itself,
ahead of the backend's own aclose(). Both exporters are therefore constructed with an explicit,
short `timeout` (POLARIS_OTEL_EXPORTER_TIMEOUT_S, config.py, default 3.0s); shutdown() against
an unreachable endpoint was re-measured at roughly 2.9 seconds per provider with that in place --
about 5.8s worst case for both, inside the ~10s remaining budget alongside backend.aclose().

The OTel logging handler is attached to the "ai_service" logger, deliberately NOT to the root
logger. This was not a style choice -- attaching it to root was tried first, and a real failure
loop showed up: when the OTLP log exporter cannot reach its endpoint, it logs its own warning
through Python's logging module (on an "opentelemetry.exporter..." logger). A handler on root
would pick that record up too, translate it, and hand it back to the very same exporter --
every failed export queues a new log record about the failure. It is bounded (the batch
processor's queue drops the oldest entries once full) so it would not crash the process, but it
is pointless log spam. Attaching to "ai_service" instead avoids it entirely: "ai_service.access"
is a *child* logger of "ai_service" and still propagates up into this handler, so both of the
service's own loggers are still exported, but OpenTelemetry's own exporter loggers and
uvicorn/httpx's loggers are separate top-level hierarchies and are never forwarded. Confirmed
with a dedicated test in this phase's test suite (test_telemetry.py) that counts exactly which
logger names reach the handler.

The OTel handler is a *second* handler on top of the existing stdout handler from
logging_setup.configure_logging(), which Python's logging module supports natively -- every log
call fires both. Phase 10 does add one thing to that stdout path (TraceContextFilter, see
logging_setup.py) but does not touch configure_logging()'s formatting or handler structure.
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

from ai_service import __version__
from ai_service.config import Settings
from ai_service.logging_setup import LOG_FIELDS

# Deliberately not opentelemetry.trace.set_tracer_provider() / opentelemetry._logs.set_logger_
# provider(): those set a *process-global* singleton that the SDK only allows setting once --
# verified for real in the Phase 9 handoff, a second call is silently ignored and logs
# "Overriding of current TracerProvider is not allowed". create_app() can run many times in one
# process (every test does), so a global would make every app after the first silently keep the
# first app's (closed) provider. FastAPIInstrumentor.instrument_app() and LoggingHandler() both
# accept the provider directly instead, which is what is used below, so the global is never
# needed.

SERVICE_NAME = "ai-service"

# Where setup_telemetry stashes the providers it created, so shutdown_telemetry can flush and
# close them. Kept off Settings/app.state's usual attributes to make "nothing to shut down when
# OTel is disabled" an explicit, testable case rather than an AttributeError waiting to happen.
_TRACER_PROVIDER_ATTR = "otel_tracer_provider"
_LOGGER_PROVIDER_ATTR = "otel_logger_provider"

# Phase 10: docs/architecture.md section 6's trace/log attribute allow-list, the names as they
# appear on an exported span after _FilteringSpanExporter below has run. Two allow-listed names
# are deliberately never set anywhere in this codebase yet and are documented as a known gap
# rather than faked: "model_version" and "prompt_version" have no source of truth -- MockBackend
# has no versioning concept beyond its name string, and there is no prompt-template system yet.
# "env" and "deployment_version" are not span attributes at all: they are the
# "deployment.environment"/"service.version" *Resource* attributes set once below and attached
# automatically to every span/log a provider exports, which is exactly what the architecture
# doc's own cardinality section (section 9) means by "bounded" -- there is nothing per-span to
# curate for either one.
SPAN_ATTRIBUTE_ALLOWLIST: Final[frozenset[str]] = frozenset(
    {
        "tenant_id",
        "request_id",
        "model",
        "model_version",  # never set yet -- see comment above
        "prompt_version",  # never set yet -- see comment above
        "endpoint",  # renamed from the auto-instrumentation's "http.route"
        "http.status_code",
        "latency_ms",
        "prompt_tokens",
        "completion_tokens",
    }
)

# The OTel semantic-convention attribute name FastAPI's auto-instrumentation uses for the
# matched route template. Renamed to "endpoint" on export to match docs/architecture.md section
# 6's literal allow-list wording.
_ROUTE_TEMPLATE_ATTR = "http.route"
_ENDPOINT_ATTR = "endpoint"


class _FilteringSpanExporter(SpanExporter):
    """Wraps a real SpanExporter, rebuilding every span with only SPAN_ATTRIBUTE_ALLOWLIST's
    attributes before delegating the actual export.

    Why an exporter wrapper and not a SpanProcessor: see the module docstring's point 1. In
    short, a processor's on_end()/_on_ending() hooks both run after Span.end() has already
    frozen the span's attributes in opentelemetry-sdk==1.44 (mutating or deleting a key then
    raises TypeError -- verified directly, not assumed). ReadableSpan objects are cheap to
    reconstruct with a different `attributes` mapping, which is what happens here instead.
    """

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
    """Attached to the OTel log handler only (see setup_telemetry). Drops any ``extra`` field
    from a log record's attributes that is not in logging_setup.LOG_FIELDS -- the same
    allow-list that already protects stdout -- before OpenTelemetry's LoggingHandler reads the
    record and exports it. See the module docstring's point 2 for why this was needed: the OTel
    handler reads a record's raw ``extra`` fields directly and previously had no knowledge of
    LOG_FIELDS at all.

    Does not touch the handful of attributes OpenTelemetry always adds itself (code.file.path,
    code.function.name, code.line.number) -- those are standard, low-risk source-location
    metadata, not application data, and are not reachable through ``extra`` in the first place
    (LoggingHandler._get_attributes adds them after this filter has already run).
    """

    def filter(self, record: logging.LogRecord) -> bool:
        reserved = _RESERVED_LOG_RECORD_ATTRS
        for key in [k for k in vars(record) if k not in reserved and k not in LOG_FIELDS]:
            delattr(record, key)
        return True


# The stdlib LogRecord's own attributes (never touched by the filter above, allow-list or not) --
# computed once from a throwaway record rather than hand-copied, so it can never drift from
# whatever this Python version's logging module actually sets.
_RESERVED_LOG_RECORD_ATTRS: Final[frozenset[str]] = frozenset(
    vars(logging.LogRecord("x", logging.INFO, "x", 0, "x", None, None))
)


def setup_telemetry(app: FastAPI, settings: Settings) -> None:
    """Call once from create_app(), after configure_logging(). Safe to call every time the app
    is built (including in tests): metrics cost nothing, and tracing/logging only activate when
    POLARIS_OTEL_ENABLED is true.
    """
    # Metrics: unconditional. A histogram/counter in memory until something scrapes /metrics.
    # A dedicated CollectorRegistry, not prometheus_client's process-global default one: without
    # this, every create_app() call in the same process (every test does one) registers metrics
    # of the same name on the same shared registry. That does not raise, but real Phase 9
    # testing found it silently means only the *first* app instance's middleware actually
    # records observations -- later apps' /metrics stayed populated with only their own /metrics
    # scrape, missing every other route. In production create_app() runs once per process, so
    # this never showed up there; it is still the more correct default regardless.
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
    # Phase 10: attributes are curated to SPAN_ATTRIBUTE_ALLOWLIST before they leave the process --
    # see _FilteringSpanExporter's docstring for why this is an exporter wrapper, not a processor.
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

    # opentelemetry-sdk 1.44 marks LoggingHandler deprecated in favour of the separate
    # opentelemetry-instrumentation-logging package (a DeprecationWarning, checked for real:
    # harmless, does not appear in captured stdout, and the class is not removed at this pinned
    # version). That package was deliberately not adopted for Phase 9 after reading its source:
    # LoggingInstrumentor is a process-global BaseInstrumentor (one process-wide instrument()
    # call, awkward with create_app() running many times per process, i.e. every test), it reads
    # the *global* logger provider via get_logger_provider() instead of accepting one directly
    # (reintroducing the "only settable once" problem this module avoids elsewhere), and it
    # attaches to the *root* logger by default -- the exact self-referential export-failure-loop
    # risk documented above. Revisit if a future opentelemetry-sdk release actually removes
    # LoggingHandler.
    otel_handler = LoggingHandler(logger_provider=logger_provider)
    # Phase 10: the same LOG_FIELDS allow-list that already protects stdout now also governs
    # what reaches this handler's export -- see _LogAttributeAllowlistFilter's docstring.
    otel_handler.addFilter(_LogAttributeAllowlistFilter())
    logging.getLogger("ai_service").addHandler(otel_handler)

    FastAPIInstrumentor.instrument_app(app, tracer_provider=tracer_provider)

    setattr(app.state, _TRACER_PROVIDER_ATTR, tracer_provider)
    setattr(app.state, _LOGGER_PROVIDER_ATTR, logger_provider)


def shutdown_telemetry(app: FastAPI) -> None:
    """Flush and close whatever setup_telemetry created. A no-op when OTel was never enabled --
    call it unconditionally from the app's lifespan shutdown, same as backend.aclose().
    """
    tracer_provider = getattr(app.state, _TRACER_PROVIDER_ATTR, None)
    if tracer_provider is not None:
        tracer_provider.shutdown()

    logger_provider = getattr(app.state, _LOGGER_PROVIDER_ATTR, None)
    if logger_provider is not None:
        logger_provider.shutdown()
        # Undo the addHandler() from setup_telemetry: "ai_service" is a shared, module-level
        # logger, so leaving the handler attached would leak across app instances (harmless in
        # production, where the process exits anyway, but it would stack up one handler per
        # test that enables OTel -- see test_telemetry.py).
        app_logger = logging.getLogger("ai_service")
        for handler in list(app_logger.handlers):
            if isinstance(handler, LoggingHandler):
                app_logger.removeHandler(handler)
