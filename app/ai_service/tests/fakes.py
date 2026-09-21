"""Test doubles."""

import asyncio

from ai_service.backends import BackendResult, ModelBackend


class FakeBackend(ModelBackend):
    """A backend whose behaviour a test controls: return a result or raise an exception."""

    def __init__(
        self,
        *,
        error: Exception | None = None,
        ready_error: Exception | None = None,
        ready_delay_s: float = 0.0,
    ) -> None:
        self.error = error
        # Set (or clear) between requests to make the backend fail and recover in a test.
        self.ready_error = ready_error
        self.ready_delay_s = ready_delay_s
        self.prompts: list[str] = []
        self.closed = False

    async def generate(self, prompt: str) -> BackendResult:
        self.prompts.append(prompt)
        if self.error is not None:
            raise self.error
        return BackendResult(
            text="fake answer", model="fake-model", prompt_tokens=1, completion_tokens=2
        )

    async def check_ready(self) -> None:
        if self.ready_delay_s:
            await asyncio.sleep(self.ready_delay_s)
        if self.ready_error is not None:
            raise self.ready_error

    async def aclose(self) -> None:
        self.closed = True
