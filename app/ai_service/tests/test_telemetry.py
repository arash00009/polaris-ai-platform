"""GET /metrics, and the opt-in OTel tracing/logging wiring (POLARIS_OTEL_ENABLED)."""

import logging
import time
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from opentelemetry.sdk._logs import LoggingHandler

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
