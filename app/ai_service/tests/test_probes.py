"""GET /healthz (liveness) and GET /readyz (readiness)."""

import pytest
from fastapi.testclient import TestClient

from ai_service.backends import BackendError
from ai_service.config import Settings
from ai_service.main import create_app
from tests.fakes import FakeBackend

VALID = {"tenant_id": "demo", "prompt": "Explain Kubernetes pods"}


def _client(backend: FakeBackend, **settings: object) -> TestClient:
    return TestClient(create_app(Settings(**settings), backend=backend))


def test_healthz_reports_ok(client: TestClient) -> None:
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_healthz_does_not_depend_on_the_backend() -> None:
    # Liveness must stay green while the backend is down, or Kubernetes would restart healthy
    # pods just because the model server is slow.
    with _client(FakeBackend(ready_error=BackendError("down"))) as client:
        assert client.get("/healthz").status_code == 200


def test_readyz_is_ready_with_the_default_mock(client: TestClient) -> None:
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_readyz_returns_503_in_the_error_envelope_without_leaking_details() -> None:
    backend = FakeBackend(ready_error=BackendError("internal detail: password is hunter2"))
    with _client(backend) as client:
        response = client.get("/readyz", headers={"x-request-id": "probe-1"})

    assert response.status_code == 503
    error = response.json()["error"]
    assert error["code"] == "not_ready"
    assert error["request_id"] == "probe-1"
    assert "hunter2" not in response.text


def test_readyz_gives_up_quickly_when_the_backend_check_hangs() -> None:
    backend = FakeBackend(ready_delay_s=1.0)
    with _client(backend, ready_timeout_s=0.05) as client:
        response = client.get("/readyz")

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "not_ready"


def test_mock_ready_false_makes_the_service_not_ready() -> None:
    with TestClient(create_app(Settings(mock_ready=False))) as client:
        assert client.get("/readyz").status_code == 503
        assert client.get("/healthz").status_code == 200


def test_readiness_follows_the_backend_and_recovers() -> None:
    backend = FakeBackend(ready_error=BackendError("starting"))
    with _client(backend) as client:
        assert client.get("/readyz").status_code == 503
        backend.ready_error = None
        assert client.get("/readyz").status_code == 200


def test_readiness_does_not_block_chat_requests() -> None:
    # Readiness tells the platform where to send traffic; it is not a switch inside the service.
    with _client(FakeBackend(ready_error=BackendError("starting"))) as client:
        assert client.get("/readyz").status_code == 503
        assert client.post("/v1/chat", json=VALID).status_code == 200


@pytest.mark.parametrize("path", ["/healthz", "/readyz"])
def test_probe_responses_carry_a_request_id(client: TestClient, path: str) -> None:
    response = client.get(path)
    assert len(response.headers["x-request-id"]) == 32


@pytest.mark.parametrize("path", ["/healthz", "/readyz"])
def test_probes_only_accept_get(client: TestClient, path: str) -> None:
    response = client.post(path)
    assert response.status_code == 405
    assert response.json()["error"]["code"] == "method_not_allowed"


def test_probes_are_documented_in_the_openapi_schema(client: TestClient) -> None:
    paths = client.get("/openapi.json").json()["paths"]
    assert "/healthz" in paths
    assert "503" in paths["/readyz"]["get"]["responses"]
