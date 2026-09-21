"""OpenAICompatBackend against a fake HTTP transport (no network, no model server)."""

import json
from collections.abc import Callable

import httpx
import pytest

from ai_service.backends import BackendError, BackendTimeout, OpenAICompatBackend

pytestmark = pytest.mark.anyio

Handler = Callable[[httpx.Request], httpx.Response]


def _backend(handler: Handler, *, api_key: str | None = None) -> tuple[OpenAICompatBackend, list]:
    seen: list[httpx.Request] = []

    def recording(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(recording),
        base_url="http://upstream.test/v1",
        headers=headers,
    )
    return OpenAICompatBackend(base_url="unused", model="tiny-model", client=client), seen


def _ok(content: str = "hello", **extra: object) -> Handler:
    body = {
        "model": "tiny-model-2025",
        "choices": [{"message": {"role": "assistant", "content": content}}],
        "usage": {"prompt_tokens": 7, "completion_tokens": 3},
        **extra,
    }
    return lambda _request: httpx.Response(200, json=body)


async def test_success_maps_the_openai_response() -> None:
    backend, _ = _backend(_ok("Pods are..."))

    result = await backend.generate("Explain pods")

    assert result.text == "Pods are..."
    assert result.model == "tiny-model-2025"  # the model the server reports wins
    assert result.prompt_tokens == 7
    assert result.completion_tokens == 3


async def test_request_is_a_non_streaming_chat_completion() -> None:
    backend, seen = _backend(_ok())

    await backend.generate("Explain pods")

    (request,) = seen
    assert request.method == "POST"
    assert request.url == "http://upstream.test/v1/chat/completions"
    assert json.loads(request.content) == {
        "model": "tiny-model",
        "messages": [{"role": "user", "content": "Explain pods"}],
        "stream": False,
    }


async def test_api_key_is_sent_as_bearer_token_only_when_configured() -> None:
    with_key, seen_with = _backend(_ok(), api_key="k-123")
    without_key, seen_without = _backend(_ok())

    await with_key.generate("x")
    await without_key.generate("x")

    assert seen_with[0].headers["authorization"] == "Bearer k-123"
    assert "authorization" not in seen_without[0].headers


async def test_missing_usage_and_model_are_tolerated() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"choices": [{"message": {"content": "hi"}}]})

    backend, _ = _backend(handler)
    result = await backend.generate("x")

    assert result.model == "tiny-model"  # falls back to the configured model
    assert result.prompt_tokens is None
    assert result.completion_tokens is None


async def test_timeout_becomes_backend_timeout() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("too slow")

    backend, _ = _backend(handler)
    with pytest.raises(BackendTimeout):
        await backend.generate("x")


async def test_http_error_becomes_backend_error_without_the_response_body() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="secret upstream detail: prompt was 'x'")

    backend, _ = _backend(handler)
    with pytest.raises(BackendError) as excinfo:
        await backend.generate("x")

    assert "500" in str(excinfo.value)
    assert "secret upstream detail" not in str(excinfo.value)
    assert not isinstance(excinfo.value, BackendTimeout)


async def test_unreachable_server_becomes_backend_error() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    backend, _ = _backend(handler)
    with pytest.raises(BackendError, match="unreachable"):
        await backend.generate("x")


@pytest.mark.parametrize(
    "payload",
    [
        "not json at all",
        {},
        {"choices": []},
        {"choices": [{"message": {}}]},
        {"choices": [{"message": {"content": 42}}]},
        ["a", "list"],
    ],
)
async def test_malformed_responses_become_backend_error(payload: object) -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        if isinstance(payload, str):
            return httpx.Response(200, text=payload)
        return httpx.Response(200, json=payload)

    backend, _ = _backend(handler)
    with pytest.raises(BackendError, match="malformed"):
        await backend.generate("x")


async def test_non_integer_token_counts_are_ignored() -> None:
    backend, _ = _backend(_ok(usage={"prompt_tokens": "7", "completion_tokens": None}))
    result = await backend.generate("x")
    assert result.prompt_tokens is None
    assert result.completion_tokens is None


async def test_owned_client_is_closed_but_an_injected_client_is_not() -> None:
    injected = httpx.AsyncClient(transport=httpx.MockTransport(lambda _r: httpx.Response(200)))
    borrowing = OpenAICompatBackend(base_url="http://x", model="m", client=injected)
    await borrowing.aclose()
    assert injected.is_closed is False
    await injected.aclose()

    owning = OpenAICompatBackend(base_url="http://x", model="m")
    await owning.aclose()
    assert owning._client.is_closed is True


# ---- readiness (GET <base_url>/models) -------------------------------------------------


async def test_check_ready_succeeds_when_the_models_endpoint_answers() -> None:
    backend, seen = _backend(lambda _request: httpx.Response(200, json={"data": []}))

    await backend.check_ready()

    (request,) = seen
    assert request.method == "GET"
    assert request.url == "http://upstream.test/v1/models"


async def test_check_ready_fails_on_an_http_error_without_leaking_the_body() -> None:
    backend, _ = _backend(lambda _request: httpx.Response(503, text="secret upstream body"))

    with pytest.raises(BackendError) as caught:
        await backend.check_ready()

    assert "503" in str(caught.value)
    assert "secret upstream body" not in str(caught.value)


async def test_check_ready_maps_timeouts_and_connection_errors() -> None:
    def timeout(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow", request=request)

    def refused(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("http://upstream.test refused", request=request)

    slow, _ = _backend(timeout)
    with pytest.raises(BackendTimeout):
        await slow.check_ready()

    down, _ = _backend(refused)
    with pytest.raises(BackendError) as caught:
        await down.check_ready()
    assert "upstream.test" not in str(caught.value)
