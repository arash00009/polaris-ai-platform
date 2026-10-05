"""Test doubles: a fake ai_service reached over httpx.MockTransport, same technique
app/ai_service/tests/test_openai_compat_backend.py already uses against a fake model server.
No network, no real ai_service -- the gateway's own proxy logic is what is under test here.
"""

from collections.abc import Callable

import httpx

Handler = Callable[[httpx.Request], httpx.Response]


class FakeUpstream:
    """Records every request it receives and answers with whatever handler is configured."""

    def __init__(self, handler: Handler) -> None:
        self.requests: list[httpx.Request] = []
        self._handler = handler

    def _recording(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return self._handler(request)

    def client(self, *, base_url: str = "http://ai-service.test") -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self._recording), base_url=base_url)


def ok_chat_handler(*, response: str = "a mock answer", model: str = "mock-1") -> Handler:
    """Answers like ai_service's real POST /v1/chat success contract (schemas.ChatResponse).

    Echoes back whatever x-request-id it was sent, same as the real ai_service's own
    request_id middleware does for a trusted, client(here: gateway)-supplied id -- so a test
    can assert the gateway's own request id round-trips through the whole proxy.
    """

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/healthz":
            return httpx.Response(200, json={"status": "ok"})
        request_id = request.headers.get("x-request-id", "upstream-generated-rid")
        return httpx.Response(
            200,
            json={
                "response": response,
                "model": model,
                "request_id": request_id,
                "latency_ms": 1.0,
            },
            headers={"x-request-id": request_id},
        )

    return handler


def error_chat_handler(status_code: int, *, code: str = "backend_error") -> Handler:
    """Answers like ai_service's own ErrorResponse envelope for a given status."""

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/healthz":
            return httpx.Response(200, json={"status": "ok"})
        return httpx.Response(
            status_code,
            json={"error": {"code": code, "message": "upstream says no", "request_id": "up-1"}},
        )

    return handler


def unreachable_handler() -> Handler:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    return handler


def timeout_handler() -> Handler:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timed out", request=request)

    return handler


def unhealthy_handler() -> Handler:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            503, json={"error": {"code": "not_ready", "message": "no", "request_id": "x"}}
        )

    return handler
