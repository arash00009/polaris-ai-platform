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
    async def generate(self, prompt: str, *, system_prompt: str | None = None) -> BackendResult:
        """Return an answer for ``prompt`` or raise BackendError / BackendTimeout.

        ``system_prompt`` (Phase 16, ADR-37) is the governance manifest's versioned prompt
        template (``ai_service/governance``'s ``GovernanceInfo.system_prompt``), passed by
        ``main.py``'s ``chat()`` handler on every call -- never something a backend reads for
        itself, the same "the HTTP layer only knows this interface" seam this class's own
        module docstring already describes. ``None`` is accepted (not required) so a backend
        with nothing to do with it -- MockBackend, whose deterministic answers do not depend on
        any prompt text at all -- is not forced to pretend otherwise.
        """

    async def check_ready(self) -> None:  # noqa: B027 - intentionally optional, not abstract
        """Raise BackendError if the backend cannot serve requests right now.

        Used by GET /readyz. It must be cheap and must not run a real generation. The default
        says "ready", which is right for a backend with nothing to wait for.
        """

    async def aclose(self) -> None:  # noqa: B027 - intentionally optional, not abstract
        """Release resources (connections). Called once when the service shuts down."""
