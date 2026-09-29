"""GET /metrics, and the opt-in OTel tracing/logging wiring (POLARIS_OTEL_ENABLED)."""

import json
import logging
import re
import time
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk._logs import LoggingHandler
from opentelemetry.sdk._logs.export import LogExportResult
from opentelemetry.sdk.trace.export import SpanExportResult

from ai_service import telemetry
from ai_service.config import Settings
from ai_service.main import create_app

VALID = {"tenant_id": "demo", "prompt": "Explain Kubernetes pods"}
# Nothing listens here: connection is refused immediately, which is what makes these tests fast
# even though they exercise the real, unreachable-collector code path end to end.
UNREACHABLE = "http://127.0.0.1:1"


@pytest.fixture(autouse=True)
def _restore_ai_service_logger() -> Iterator[None]:
    """setup_telemetry()/shutdown_telemetry() add and remove a handler on "ai_service". Guard
    against a failed assertion mid-test leaving one attached for every test that runs after it.
    """
    logger = logging.getLogger("ai_service")
    handlers = list(logger.handlers)
    yield
    logger.handlers[:] = handlers


# ---- /metrics (always on, regardless of POLARIS_OTEL_ENABLED) --------------------------------


def test_metrics_endpoint_returns_prometheus_text(client: TestClient) -> None:
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert "http_requests_total" in response.text


def test_metrics_only_accepts_get(client: TestClient) -> None:
    response = client.post("/metrics")
    assert response.status_code == 405
    assert response.json()["error"]["code"] == "method_not_allowed"


def test_metrics_is_not_documented_in_the_openapi_schema(client: TestClient) -> None:
    # include_in_schema=False: it is scraped by Prometheus, not part of the public API surface.
    paths = client.get("/openapi.json").json()["paths"]
    assert "/metrics" not in paths


def test_metrics_use_route_templates_and_grouped_status_not_raw_values(
    client: TestClient,
) -> None:
    client.get("/healthz")
    client.post("/v1/chat", json=VALID)
    client.get("/this-path-does-not-exist")

    text = client.get("/metrics").text

    # Cardinality-safe labels (Phase 0's allow-list: status_class, route template):
    assert 'handler="/healthz"' in text
    assert 'handler="/v1/chat"' in text
    assert 'status="2xx"' in text
    # An unmatched route must never leak the raw, unbounded path into a label.
    assert 'handler="none"' in text
    assert "this-path-does-not-exist" not in text
    # And the raw numeric status code must never appear as a label value either.
    assert 'status="200"' not in text


def test_metrics_requests_are_treated_as_probe_traffic_in_the_access_log(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with TestClient(create_app(Settings(log_format="json"))) as probe_client:
        probe_client.get("/metrics")

    assert '"path": "/metrics"' not in capsys.readouterr().out


# ---- POLARIS_OTEL_ENABLED=false (the default): nothing extra happens -------------------------


def test_otel_disabled_by_default(client: TestClient) -> None:
    assert client.app.state.settings.otel_enabled is False
    assert not hasattr(client.app.state, "otel_tracer_provider")
    assert not hasattr(client.app.state, "otel_logger_provider")
    assert not any(isinstance(h, LoggingHandler) for h in logging.getLogger("ai_service").handlers)


# ---- POLARIS_OTEL_ENABLED=true, pointed at an endpoint nothing listens on --------------------


def _otel_client(**overrides: object) -> TestClient:
    settings = Settings(
        otel_enabled=True,
        otel_exporter_otlp_endpoint=UNREACHABLE,
        otel_exporter_timeout_s=1.0,
        **overrides,
    )
    return TestClient(create_app(settings))


def test_otel_enabled_creates_and_cleans_up_providers_without_raising() -> None:
    with _otel_client() as otel_client:
        assert otel_client.app.state.otel_tracer_provider is not None
        assert otel_client.app.state.otel_logger_provider is not None
        assert any(isinstance(h, LoggingHandler) for h in logging.getLogger("ai_service").handlers)

    # shutdown_telemetry() ran as part of the lifespan's teardown: the handler it added is gone.
    assert not any(isinstance(h, LoggingHandler) for h in logging.getLogger("ai_service").handlers)


def test_an_unreachable_collector_does_not_slow_down_a_request() -> None:
    with _otel_client() as otel_client:
        started = time.perf_counter()
        response = otel_client.get("/healthz")
        elapsed_s = time.perf_counter() - started

    assert response.status_code == 200
    # Generous bound: the real measurement was a few milliseconds. This only guards against the
    # export blocking the request thread, not against normal request overhead.
    assert elapsed_s < 1.0


def test_shutdown_against_an_unreachable_collector_is_bounded(
    caplog: pytest.LogCaptureFixture,
) -> None:
    # otel_exporter_timeout_s=1.0 bounds a single export attempt; shutdown() flushes both
    # providers, so an unbounded version of this would take several seconds per provider (see
    # telemetry.py's module docstring for the real measurement that motivated the timeout).
    client_cm = _otel_client()
    started = time.perf_counter()
    with client_cm:
        pass
    elapsed_s = time.perf_counter() - started

    assert elapsed_s < 8.0


def test_only_the_ai_service_logger_namespace_reaches_the_otel_handler() -> None:
    # Verified for real during Phase 9 development: attaching the OTel handler to the root
    # logger let a failed export's own warning log feed back into the handler. This test proves
    # the mitigation (attach to "ai_service" only) by recording exactly which logger names the
    # handler processes.
    with _otel_client() as otel_client:
        handler = next(
            h for h in logging.getLogger("ai_service").handlers if isinstance(h, LoggingHandler)
        )
        seen: list[str] = []
        original_emit = handler.emit
        handler.emit = lambda record: (seen.append(record.name), original_emit(record))[1]  # type: ignore[method-assign]

        # /v1/chat, not /healthz: probe paths log at DEBUG (root logger's default level is
        # INFO), so they would not produce an "ai_service.access" record to observe here.
        otel_client.post("/v1/chat", json=VALID)
        logging.getLogger("httpx").warning("third-party log, must not be forwarded")

    assert "ai_service" in seen
    assert "ai_service.access" in seen
    assert "httpx" not in seen


def test_otel_enabled_still_serves_chat_requests_normally() -> None:
    with _otel_client() as otel_client:
        response = otel_client.post("/v1/chat", json=VALID)
    assert response.status_code == 200
    assert response.json()["response"]


# ---- Phase 10: span/log attribute curation and log<->trace correlation -----------------------
#
# Every test below patches OTLPSpanExporter.export/OTLPLogExporter.export at the class level to
# capture exactly what would have gone over the wire, instead of attempting (and waiting out the
# timeout of) a real call to UNREACHABLE. This is the seam telemetry.py actually has: neither
# exporter is constructed anywhere accessible before setup_telemetry() runs, so patching the
# class method is the only way to observe a call made deep inside it.


def _capture_exports(monkeypatch: pytest.MonkeyPatch) -> tuple[list, list]:
    captured_spans: list = []
    captured_logs: list = []

    def fake_span_export(self: OTLPSpanExporter, spans: object) -> SpanExportResult:
        captured_spans.extend(spans)
        return SpanExportResult.SUCCESS

    def fake_log_export(self: OTLPLogExporter, batch: object) -> LogExportResult:
        captured_logs.extend(batch)
        return LogExportResult.SUCCESS

    monkeypatch.setattr(OTLPSpanExporter, "export", fake_span_export)
    monkeypatch.setattr(OTLPLogExporter, "export", fake_log_export)
    return captured_spans, captured_logs


def test_span_attributes_are_curated_to_the_allowlist(monkeypatch: pytest.MonkeyPatch) -> None:
    captured_spans, _ = _capture_exports(monkeypatch)

    with _otel_client() as otel_client:
        response = otel_client.post("/v1/chat", json=VALID)
    assert response.status_code == 200

    chat_spans = [s for s in captured_spans if s.name == "POST /v1/chat"]
    assert chat_spans, [s.name for s in captured_spans]
    attrs = dict(chat_spans[0].attributes)

    # Nothing outside docs/architecture.md section 6's allow-list survived -- specifically, none
    # of the attributes FastAPI's/OpenTelemetry's auto-instrumentation adds by default that are
    # not on that list (a real, unfiltered trace pulled from Tempo during Phase 9 development
    # showed exactly these leaking: http.url, net.peer.ip, net.peer.port, http.user_agent).
    assert set(attrs) <= telemetry.SPAN_ATTRIBUTE_ALLOWLIST
    for leaked in ("net.peer.ip", "net.peer.port", "http.user_agent", "http.url", "http.route"):
        assert leaked not in attrs, attrs

    # The business attributes main.py's chat() handler sets explicitly (Phase 10) did survive,
    # and http.route was renamed to the allow-list's "endpoint".
    assert attrs["tenant_id"] == "demo"
    assert attrs["request_id"]
    assert attrs["model"] == "mock-1"
    assert attrs["endpoint"] == "/v1/chat"
    assert attrs["http.status_code"] == 200
    assert isinstance(attrs["latency_ms"], float)
    assert isinstance(attrs["prompt_tokens"], int)
    assert isinstance(attrs["completion_tokens"], int)


def test_log_attributes_reaching_otel_are_curated_to_the_same_allowlist_as_stdout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Nothing in the app itself ever passes a disallowed field -- this is defence in depth,
    # exactly like logging_setup.py's own stdout tests exercise LOG_FIELDS directly rather than
    # only through application code.
    _, captured_logs = _capture_exports(monkeypatch)

    with _otel_client() as otel_client:
        logging.getLogger("ai_service").warning(
            "hypothetical leak",
            extra={"tenant_id": "demo", "prompt": "must never reach Loki"},
        )
        otel_client.app.state.otel_logger_provider.force_flush()

    assert captured_logs, "no log record was exported"
    leaked_record = next(
        (item for item in captured_logs if item.log_record.body == "hypothetical leak"), None
    )
    assert leaked_record is not None, "the test's own log line was not exported at all"
    attrs = dict(leaked_record.log_record.attributes)
    assert attrs.get("tenant_id") == "demo"
    assert "prompt" not in attrs, attrs


def test_log_records_reaching_otel_are_correlated_with_their_span(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured_spans, captured_logs = _capture_exports(monkeypatch)

    with _otel_client() as otel_client:
        otel_client.post("/v1/chat", json=VALID)

    chat_span = next(s for s in captured_spans if s.name == "POST /v1/chat")
    chat_log = next(item for item in captured_logs if item.log_record.body == "chat completed")

    assert chat_log.log_record.trace_id == chat_span.context.trace_id
    assert chat_log.log_record.trace_id != 0


def test_stdout_logs_carry_trace_id_only_while_otel_is_enabled_and_a_span_is_active(
    capsys: pytest.CaptureFixture[str],
) -> None:
    # OTel disabled (the default): no span is ever started, so TraceContextFilter adds nothing.
    with TestClient(create_app(Settings(log_format="json"))) as plain_client:
        plain_client.post("/v1/chat", json=VALID)
    plain_lines = [json.loads(line) for line in capsys.readouterr().out.splitlines() if line]
    assert plain_lines
    assert not any("trace_id" in line for line in plain_lines)

    # OTel enabled: the same "chat completed" line now carries the request's real trace/span id,
    # in the same format Tempo uses, without needing to go through Loki first.
    with _otel_client(log_format="json") as otel_client:
        otel_client.post("/v1/chat", json=VALID)
    otel_lines = [json.loads(line) for line in capsys.readouterr().out.splitlines() if line]
    chat_line = next(line for line in otel_lines if line["message"] == "chat completed")
    assert re.fullmatch(r"[0-9a-f]{32}", chat_line["trace_id"])
    assert re.fullmatch(r"[0-9a-f]{16}", chat_line["span_id"])
