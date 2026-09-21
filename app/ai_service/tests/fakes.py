"""Test doubles."""

from ai_service.backends import BackendResult, ModelBackend


class FakeBackend(ModelBackend):
    """A backend whose behaviour a test controls: return a result or raise an exception."""

    def __init__(self, *, error: Exception | None = None) -> None:
        self.error = error
        self.prompts: list[str] = []
        self.closed = False

    async def generate(self, prompt: str) -> BackendResult:
        self.prompts.append(prompt)
        if self.error is not None:
            raise self.error
        return BackendResult(
            text="fake answer", model="fake-model", prompt_tokens=1, completion_tokens=2
        )

    async def aclose(self) -> None:
        self.closed = True
