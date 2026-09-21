"""The ModelBackend interface: the seam between the service and whatever produces answers.

The HTTP layer only knows this interface. Swapping the mock for a real model server is a
configuration change (POLARIS_BACKEND), not a code change in the API.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass


class BackendError(Exception):
    """The backend could not produce an answer. Messages must be safe to log (no secrets)."""


class BackendTimeout(BackendError):
    """The backend did not answer within the configured timeout."""


@dataclass(frozen=True, slots=True)
class BackendResult:
    text: str
    # The model that actually answered (as reported by the backend where possible).
    model: str
    # None when the backend does not report token counts. Needed later for cost attribution.
    prompt_tokens: int | None = None
    completion_tokens: int | None = None


class ModelBackend(ABC):
    @abstractmethod
    async def generate(self, prompt: str) -> BackendResult:
        """Return an answer for ``prompt`` or raise BackendError / BackendTimeout."""

    async def aclose(self) -> None:  # noqa: B027 - intentionally optional, not abstract
        """Release resources (connections). Called once when the service shuts down."""
