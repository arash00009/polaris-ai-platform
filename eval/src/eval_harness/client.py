"""Thin I/O wrapper around a live ai_service: GET /v1/meta and POST /v1/chat. Called directly
against ai_service (not through ai-gateway) -- the same way Phase 16's own real target-machine
confirmation checked /v1/meta (docs/troubleshooting.md's Phase 16 section): ai_service has no
API-key check of its own, only ai-gateway does (Phase 12), and this is an internal measurement
tool, not end-user traffic.
"""

from __future__ import annotations

import httpx

# A tenant id distinct from the real gateway tenants (demo/acme/globex, Phase 14) so eval
# traffic is immediately distinguishable in ai_service's own tenant-labelled metrics/logs
# (Phase 13) from real tenant traffic -- matches TENANT_ID_PATTERN in ai_service/schemas.py.
EVAL_TENANT_ID = "eval"


class ServiceClientError(Exception):
    """A call to the live ai_service failed or returned an unexpected shape."""


class ServiceClient:
    def __init__(
        self, base_url: str, *, timeout_s: float = 30.0, client: httpx.Client | None = None
    ) -> None:
        # client injection mirrors OpenAICompatBackend's own pattern (ai_service/backends/
        # openai_compat.py): tests pass a httpx.Client built on httpx.MockTransport, no network.
        self._client = client or httpx.Client(base_url=base_url.rstrip("/"), timeout=timeout_s)

    def get_meta(self) -> dict[str, str]:
        """GET /v1/meta -- the governance record (Phase 16, ADR-37): which model/prompt
        version this running process declares itself to be."""
        try:
            response = self._client.get("/v1/meta")
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise ServiceClientError(f"GET /v1/meta failed: {exc}") from exc
        return response.json()

    def chat(self, prompt: str) -> str:
        """POST /v1/chat and return the response text. Raises ServiceClientError on any
        non-2xx response or unexpected body shape, never returns a partial/guessed answer."""
        try:
            response = self._client.post(
                "/v1/chat", json={"tenant_id": EVAL_TENANT_ID, "prompt": prompt}
            )
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise ServiceClientError(f"POST /v1/chat failed for prompt {prompt!r}: {exc}") from exc
        body = response.json()
        if "response" not in body:
            raise ServiceClientError(f"POST /v1/chat response is missing 'response': {body}")
        return str(body["response"])

    def close(self) -> None:
        self._client.close()
