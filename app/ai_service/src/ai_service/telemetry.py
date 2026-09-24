"""Wires the three observability signals onto the FastAPI app: metrics, traces, logs.

Phase 9 (Observability) scope, per docs/observability.md and the Phase 0 roadmap's exact
"Done when" wording for this phase ("Grafana shows metrics, logs, traces and the required
dashboards"): get real data flowing for all three signals. Curating trace/log attributes down
to the architecture's allow-list, adding trace_id/span_id to every log line for log<->trace
correlation, and propagating trace context across service boundaries are Phase 10's job
("OpenTelemetry") -- there is only one service until Phase 12's gateway exists, so there is
nothing to propagate a trace *across* yet.

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

logging_setup.configure_logging() is not modified for this: the OTel handler is a *second*
handler on top of the existing stdout handler, which Python's logging module supports natively
-- every log call fires both.
"""

import logging

from fastapi import FastAPI
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CollectorRegistry
from prometheus_fastapi_instrumentator import Instrumentator

from ai_service import __version__
from ai_service.config import Settings

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
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{endpoint}/v1/traces", timeout=timeout))
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
