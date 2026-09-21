"""Backend selection: the only place that knows which implementations exist."""

from ai_service.backends.base import BackendError, BackendResult, BackendTimeout, ModelBackend
from ai_service.backends.mock import MockBackend
from ai_service.backends.openai_compat import OpenAICompatBackend
from ai_service.config import Settings

__all__ = [
    "BackendError",
    "BackendResult",
    "BackendTimeout",
    "MockBackend",
    "ModelBackend",
    "OpenAICompatBackend",
    "build_backend",
]


def build_backend(settings: Settings) -> ModelBackend:
    if settings.backend == "openai_compat":
        return OpenAICompatBackend(
            base_url=settings.openai_base_url,
            model=settings.openai_model,
            api_key=settings.openai_api_key.get_secret_value() if settings.openai_api_key else None,
            timeout_s=settings.backend_timeout_s,
        )
    return MockBackend(
        model=settings.mock_model_name,
        latency_ms=settings.mock_latency_ms,
        failure_rate=settings.mock_failure_rate,
        seed=settings.mock_seed,
        ready=settings.mock_ready,
    )
