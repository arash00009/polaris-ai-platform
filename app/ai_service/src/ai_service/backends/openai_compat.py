"""OpenAICompatBackend: talks to any server that implements the OpenAI chat-completions API.

Ollama, vLLM and many hosted services expose this API, so one client covers all of them.
Status: implemented and unit-tested against a fake transport. It has NOT been run against a
real model server yet; that happens in Phase 11.
"""

import httpx

from ai_service.backends.base import BackendError, BackendResult, BackendTimeout, ModelBackend


class OpenAICompatBackend(ModelBackend):
    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        api_key: str | None = None,
        timeout_s: float = 30.0,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._model = model
        # A client passed in (tests) is owned by the caller; one created here is closed here.
        self._owns_client = client is None
        if client is None:
            headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
            client = httpx.AsyncClient(base_url=base_url, timeout=timeout_s, headers=headers)
        self._client = client

    async def generate(self, prompt: str) -> BackendResult:
        payload = {
            "model": self._model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
        }
        # Error messages below never include the upstream response body or the URL: they can
        # contain prompt text or credentials, and these messages end up in logs.
        try:
            response = await self._client.post("chat/completions", json=payload)
            response.raise_for_status()
        except httpx.TimeoutException as exc:
            raise BackendTimeout("model backend timed out") from exc
        except httpx.HTTPStatusError as exc:
            raise BackendError(f"model backend returned HTTP {exc.response.status_code}") from exc
        except httpx.RequestError as exc:
            raise BackendError("model backend unreachable") from exc

        try:
            data = response.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage") or {}
            model = data.get("model") or self._model
            prompt_tokens = usage.get("prompt_tokens")
            completion_tokens = usage.get("completion_tokens")
        except (ValueError, KeyError, IndexError, TypeError, AttributeError) as exc:
            raise BackendError("model backend returned a malformed response") from exc
        if not isinstance(text, str):
            raise BackendError("model backend returned a malformed response")

        return BackendResult(
            text=text,
            model=str(model),
            prompt_tokens=prompt_tokens if isinstance(prompt_tokens, int) else None,
            completion_tokens=completion_tokens if isinstance(completion_tokens, int) else None,
        )

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()
