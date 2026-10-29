from collections.abc import Callable

import httpx
import pytest

from eval_harness.client import EVAL_TENANT_ID, ServiceClient, ServiceClientError

Handler = Callable[[httpx.Request], httpx.Response]


def _client(handler: Handler) -> tuple[ServiceClient, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    def recording(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    httpx_client = httpx.Client(
        transport=httpx.MockTransport(recording), base_url="http://ai-service.test"
    )
    return ServiceClient("unused", client=httpx_client), seen


def test_get_meta_returns_the_parsed_body() -> None:
    body = {
        "model_version": "mock-1",
        "prompt_version": "v1",
        "deployment_version": "unset",
        "config_version": "unset",
        "environment": "dev",
    }
    client, seen = _client(lambda _request: httpx.Response(200, json=body))

    result = client.get_meta()

    assert result == body
    assert seen[0].method == "GET"
    assert seen[0].url.path == "/v1/meta"


def test_get_meta_raises_on_a_non_2xx_response() -> None:
    client, _ = _client(lambda _request: httpx.Response(500, json={"error": "boom"}))
    with pytest.raises(ServiceClientError, match="GET /v1/meta failed"):
        client.get_meta()


def test_chat_posts_the_prompt_with_the_eval_tenant_id_and_returns_the_response_text() -> None:
    client, seen = _client(lambda _request: httpx.Response(200, json={"response": "hello there"}))

    result = client.chat("Explain Kubernetes pods")

    assert result == "hello there"
    request = seen[0]
    assert request.method == "POST"
    assert request.url.path == "/v1/chat"
    import json

    body = json.loads(request.content)
    assert body == {"tenant_id": EVAL_TENANT_ID, "prompt": "Explain Kubernetes pods"}


def test_chat_raises_on_a_non_2xx_response() -> None:
    client, _ = _client(lambda _request: httpx.Response(422, json={"error": "bad"}))
    with pytest.raises(ServiceClientError, match="POST /v1/chat failed"):
        client.chat("anything")


def test_chat_raises_when_the_response_body_has_no_response_field() -> None:
    client, _ = _client(lambda _request: httpx.Response(200, json={"unexpected": "shape"}))
    with pytest.raises(ServiceClientError, match="missing 'response'"):
        client.chat("anything")


def test_close_closes_the_underlying_client() -> None:
    client, _ = _client(lambda _request: httpx.Response(200, json={}))
    client.close()
    assert client._client.is_closed
