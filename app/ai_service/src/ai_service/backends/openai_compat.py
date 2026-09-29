"""OpenAICompatBackend: talks to any server that implements the OpenAI chat-completions API.

Ollama, vLLM and many hosted services expose this API, so one client covers all of them.
Status: implemented and unit-tested against a fake transport (test_openai_compat_backend.py).
Phase 11 tightened check_ready() (see its docstring) and wires this backend up against a real
Ollama server for the first time (deploy/platform/model-serving/) -- not yet re-confirmed against
that real server from this sandbox (no cluster here); that is this phase's target-machine step,
the same "unit-tested here, run for real there" split every earlier Kubernetes-facing phase in
this project has followed.
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

    async def check_ready(self) -> None:
        """Confirm the backend is reachable AND that the configured model is actually loaded.

        Ollama, vLLM and other OpenAI-compatible servers answer GET <base>/models with the
        OpenAI API's own shape: {"object": "list", "data": [{"id": "<model-name>", ...}, ...]}.
        Before Phase 11 this only checked that the endpoint answered 200 -- which proves the
        server process is up, but not that POLARIS_OPENAI_MODEL is actually pulled/loaded there.
        A mistyped model name, or one that was configured but never pulled, would have passed
        GET /readyz and only surfaced as a 502 on the first real chat request. Phase 11 closes
        that gap: it is testable now that a real model server exists to define the response
        shape against (see test_openai_compat_backend.py). Messages carry no URL or upstream
        body -- same discipline as generate() and the rest of this class.
        """
        try:
            response = await self._client.get("models")
            response.raise_for_status()
        except httpx.TimeoutException as exc:
            raise BackendTimeout("model backend timed out") from exc
        except httpx.HTTPStatusError as exc:
            raise BackendError(f"model backend returned HTTP {exc.response.status_code}") from exc
        except httpx.RequestError as exc:
            raise BackendError("model backend unreachable") from exc

        try:
            data = response.json()
            model_ids = {entry["id"] for entry in data["data"]}
        except (ValueError, KeyError, TypeError) as exc:
            raise BackendError("model backend returned a malformed models list") from exc
        if self._model not in model_ids:
            raise BackendError("configured model is not loaded on the model backend")

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()
