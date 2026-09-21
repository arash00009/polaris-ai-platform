import asyncio
import logging

import pytest
from fastapi.testclient import TestClient

from ai_service.backends import BackendError, BackendResult, BackendTimeout, ModelBackend
from ai_service.config import Settings
from ai_service.main import create_app
from tests.fakes import FakeBackend

VALID = {"tenant_id": "demo", "prompt": "Explain Kubernetes pods"}


def test_chat_returns_the_documented_shape(client: TestClient) -> None:
    response = client.post("/v1/chat", json=VALID)

    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"response", "model", "request_id", "latency_ms"}
    assert body["model"] == "mock-1"
    assert body["response"].startswith("[mock] ")
    assert "smallest deployable unit" in body["response"]
    assert isinstance(body["latency_ms"], int | float)
    assert body["latency_ms"] >= 0


def test_same_prompt_gives_same_answer(client: TestClient) -> None:
    first = client.post("/v1/chat", json=VALID).json()["response"]
    second = client.post("/v1/chat", json=VALID).json()["response"]
    assert first == second


def test_unknown_topic_gets_generic_mock_answer(client: TestClient) -> None:
    body = client.post("/v1/chat", json={**VALID, "prompt": "tell me a joke"}).json()
    assert body["response"].startswith("[mock] This is a mock answer")


def test_request_id_is_generated_and_returned_in_body_and_header(client: TestClient) -> None:
    response = client.post("/v1/chat", json=VALID)
    request_id = response.json()["request_id"]

    assert len(request_id) == 32
    assert response.headers["x-request-id"] == request_id


def test_two_requests_get_different_generated_ids(client: TestClient) -> None:
    first = client.post("/v1/chat", json=VALID).json()["request_id"]
    second = client.post("/v1/chat", json=VALID).json()["request_id"]
    assert first != second


def test_a_valid_client_request_id_is_kept(client: TestClient) -> None:
    response = client.post("/v1/chat", json=VALID, headers={"x-request-id": "trace-42.a_b"})
    assert response.json()["request_id"] == "trace-42.a_b"
    assert response.headers["x-request-id"] == "trace-42.a_b"


@pytest.mark.parametrize(
    "unsafe",
    ["x" * 65, "has space", 'quote"inside', "semi;colon", "slash/slash", ""],
)
def test_an_unsafe_client_request_id_is_replaced(client: TestClient, unsafe: str) -> None:
    response = client.post("/v1/chat", json=VALID, headers={"x-request-id": unsafe})
    request_id = response.json()["request_id"]
    assert request_id != unsafe
    assert len(request_id) == 32


@pytest.mark.parametrize("tenant", ["demo", "team-a", "a_b", "0", "a" * 32])
def test_valid_tenant_ids_are_accepted(client: TestClient, tenant: str) -> None:
    assert client.post("/v1/chat", json={**VALID, "tenant_id": tenant}).status_code == 200


@pytest.mark.parametrize(
    "tenant", ["", "UPPER", "has space", "-leading", "_leading", "a" * 33, "åäö", "a/b"]
)
def test_invalid_tenant_ids_are_rejected(client: TestClient, tenant: str) -> None:
    response = client.post("/v1/chat", json={**VALID, "tenant_id": tenant})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_request"


@pytest.mark.parametrize("prompt", ["", "   ", "\n\t "])
def test_empty_or_blank_prompts_are_rejected(client: TestClient, prompt: str) -> None:
    assert client.post("/v1/chat", json={**VALID, "prompt": prompt}).status_code == 422


def test_prompt_length_limit(client: TestClient) -> None:
    assert client.post("/v1/chat", json={**VALID, "prompt": "a" * 4000}).status_code == 200
    assert client.post("/v1/chat", json={**VALID, "prompt": "a" * 4001}).status_code == 422


def test_missing_fields_and_unknown_fields_are_rejected(client: TestClient) -> None:
    assert client.post("/v1/chat", json={"prompt": "x"}).status_code == 422
    assert client.post("/v1/chat", json={"tenant_id": "demo"}).status_code == 422
    assert client.post("/v1/chat", json={**VALID, "temperature": 2}).status_code == 422


def test_invalid_json_is_rejected(client: TestClient) -> None:
    response = client.post(
        "/v1/chat", content=b"{not json", headers={"content-type": "application/json"}
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_request"


def test_validation_errors_never_echo_the_prompt(client: TestClient) -> None:
    private_text = "my-confidential-prompt-text"
    response = client.post("/v1/chat", json={"tenant_id": "Bad Tenant", "prompt": private_text})

    assert response.status_code == 422
    assert private_text not in response.text
    error = response.json()["error"]
    assert error["request_id"] == response.headers["x-request-id"]
    assert error["details"][0]["field"] == "body.tenant_id"


def test_routing_errors_use_the_same_error_envelope(client: TestClient) -> None:
    not_found = client.get("/does-not-exist")
    assert not_found.status_code == 404
    assert not_found.json()["error"]["code"] == "not_found"

    wrong_method = client.get("/v1/chat")
    assert wrong_method.status_code == 405
    assert wrong_method.json()["error"]["code"] == "method_not_allowed"
    assert wrong_method.headers["allow"] == "POST"


def test_openapi_schema_describes_the_chat_endpoint(client: TestClient) -> None:
    schema = client.get("/openapi.json").json()
    assert "/v1/chat" in schema["paths"]
    assert {"200", "422", "502", "504"} <= set(schema["paths"]["/v1/chat"]["post"]["responses"])


# ---- failure mapping -------------------------------------------------------------------


def _client_with(backend: ModelBackend, **settings: object) -> TestClient:
    # raise_server_exceptions=False: we want to see the 500 response, not the exception.
    return TestClient(
        create_app(Settings(**settings), backend=backend), raise_server_exceptions=False
    )


def test_backend_error_becomes_502_without_leaking_details() -> None:
    backend = FakeBackend(error=BackendError("internal detail: db password is hunter2"))
    with _client_with(backend) as client:
        response = client.post("/v1/chat", json=VALID)

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "backend_error"
    assert "hunter2" not in response.text


def test_backend_timeout_becomes_504() -> None:
    with _client_with(FakeBackend(error=BackendTimeout("slow"))) as client:
        response = client.post("/v1/chat", json=VALID)

    assert response.status_code == 504
    assert response.json()["error"]["code"] == "backend_timeout"


def test_service_side_timeout_becomes_504() -> None:
    # The mock waits 200 ms, the service allows only 0.05 s in total.
    settings = {"mock_latency_ms": 200, "backend_timeout_s": 0.05}
    with TestClient(create_app(Settings(**settings))) as client:
        response = client.post("/v1/chat", json=VALID)

    assert response.status_code == 504
    assert response.json()["error"]["code"] == "backend_timeout"


def test_unexpected_exception_becomes_500_with_request_id_and_no_traceback() -> None:
    with _client_with(FakeBackend(error=RuntimeError("boom with secret"))) as client:
        response = client.post("/v1/chat", json=VALID, headers={"x-request-id": "abc-1"})

    assert response.status_code == 500
    error = response.json()["error"]
    assert error["code"] == "internal_error"
    assert error["request_id"] == "abc-1"
    assert "secret" not in response.text
    assert "Traceback" not in response.text


def test_mock_with_failure_rate_one_always_returns_502() -> None:
    with TestClient(create_app(Settings(mock_failure_rate=1.0))) as client:
        statuses = {client.post("/v1/chat", json=VALID).status_code for _ in range(5)}
    assert statuses == {502}


def test_injected_backend_is_used_and_closed_on_shutdown() -> None:
    backend = FakeBackend()
    with TestClient(create_app(Settings(), backend=backend)) as client:
        body = client.post("/v1/chat", json=VALID).json()
        assert body["response"] == "fake answer"
        assert body["model"] == "fake-model"
        assert backend.prompts == [VALID["prompt"]]
        assert backend.closed is False
    assert backend.closed is True


# ---- logging ---------------------------------------------------------------------------


def _record(caplog: pytest.LogCaptureFixture, message: str, logger_name: str) -> logging.LogRecord:
    return next(r for r in caplog.records if r.name == logger_name and r.getMessage() == message)


def test_logs_carry_ids_but_never_the_prompt(
    client: TestClient, caplog: pytest.LogCaptureFixture
) -> None:
    private_prompt = "please summarise my confidential contract"
    with caplog.at_level(logging.INFO, logger="ai_service"):
        response = client.post("/v1/chat", json={"tenant_id": "acme", "prompt": private_prompt})

    request_id = response.json()["request_id"]
    completed = _record(caplog, "chat completed", "ai_service")
    assert completed.request_id == request_id
    assert completed.tenant_id == "acme"
    assert completed.model == "mock-1"
    # Neither the formatted text nor any attribute of any record may hold the prompt.
    assert private_prompt not in caplog.text
    assert private_prompt not in repr([record.__dict__ for record in caplog.records])


def test_backend_failures_are_logged_without_the_prompt(caplog: pytest.LogCaptureFixture) -> None:
    private_prompt = "another confidential prompt"
    with (
        caplog.at_level(logging.WARNING, logger="ai_service"),
        _client_with(FakeBackend(error=BackendError("upstream said no"))) as client,
    ):
        client.post("/v1/chat", json={"tenant_id": "acme", "prompt": private_prompt})

    failed = _record(caplog, "chat failed", "ai_service")
    assert failed.code == "backend_error"
    assert failed.tenant_id == "acme"
    assert failed.reason == "upstream said no"
    assert private_prompt not in caplog.text
    assert private_prompt not in repr([record.__dict__ for record in caplog.records])


def test_concurrent_requests_do_not_share_request_ids() -> None:
    # Guards against request-scoped state leaking between simultaneous requests.
    async def run() -> set[str]:
        import httpx

        app = create_app(Settings(mock_latency_ms=20))
        async with (
            app.router.lifespan_context(app),
            httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            ) as http,
        ):
            replies = await asyncio.gather(*(http.post("/v1/chat", json=VALID) for _ in range(20)))
        return {reply.json()["request_id"] for reply in replies}

    assert len(asyncio.run(run())) == 20


def test_backend_result_defaults_allow_missing_token_counts() -> None:
    result = BackendResult(text="x", model="m")
    assert result.prompt_tokens is None
    assert result.completion_tokens is None


def test_reported_version_matches_the_installed_package(client: TestClient) -> None:
    import ai_service

    assert client.get("/openapi.json").json()["info"]["version"] == ai_service.__version__
    assert ai_service.__version__ == "0.3.0"
