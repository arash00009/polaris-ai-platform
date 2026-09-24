"""Runtime configuration, read from environment variables (prefix ``POLARIS_``).

Twelve-factor style: the same container image runs in every environment and only the
environment variables change. Nothing is read from files, so there is no hidden state.
"""

from typing import Literal, Self

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="POLARIS_", extra="ignore", frozen=True)

    # Which ModelBackend implementation answers requests.
    backend: Literal["mock", "openai_compat"] = "mock"
    # Upper bound for one backend call, in seconds. Exceeding it becomes HTTP 504.
    backend_timeout_s: float = Field(default=30.0, gt=0, le=300)
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    # "text" is readable in a terminal; "json" (set by the container image) is one JSON object
    # per line, which log pipelines can parse.
    log_format: Literal["text", "json"] = "text"
    # How long GET /readyz waits for the backend to confirm it is ready, in seconds. Kept short
    # on purpose: a readiness probe that hangs is worse than one that fails fast.
    ready_timeout_s: float = Field(default=2.0, gt=0, le=30)
    # Which environment this process is running in. Not used for behaviour -- only attached to
    # every trace/log as deployment.environment / the "env" field (Phase 0's cardinality-safe
    # allow-list). "local" by default so a developer's own laptop is never mistaken for "dev".
    environment: str = Field(default="local", min_length=1, max_length=32)

    # --- Observability (Phase 9): metrics are always on; traces and logs are opt-in because
    # they need somewhere to send OTLP data to. See ai_service/telemetry.py. ---
    otel_enabled: bool = False
    # The OTel Collector's Service DNS name inside the cluster (deploy/platform/observability/).
    # Never blocks or fails a request even if nothing is listening here -- verified in the
    # Phase 9 handoff.
    otel_exporter_otlp_endpoint: str = Field(
        default="http://otel-collector.observability.svc.cluster.local:4318",
        min_length=1,
    )
    # Per-export HTTP timeout, in seconds. Kept short on purpose: shutdown() flushes and retries
    # against this timeout before the process can exit, and terminationGracePeriodSeconds (see
    # helm/ai-platform/values.yaml) only leaves a few seconds for that -- measured for real in
    # the Phase 9 handoff, see ai_service/telemetry.py.
    otel_exporter_timeout_s: float = Field(default=3.0, gt=0, le=10)

    # --- MockBackend (LOCAL / DEMO): deterministic answers, no model involved ---
    mock_model_name: str = Field(default="mock-1", min_length=1, max_length=64)
    # Simulated processing time, to exercise timeouts, latency panels and autoscaling.
    mock_latency_ms: int = Field(default=0, ge=0, le=60_000)
    # Fraction of calls that fail on purpose (0.0 to 1.0). Used for failure engineering.
    mock_failure_rate: float = Field(default=0.0, ge=0.0, le=1.0)
    # Seed for the failure decisions. Set it to make a failure pattern reproducible.
    mock_seed: int | None = None
    # Set to false to make the mock report "not ready" on GET /readyz. Used to practise how
    # a readiness probe removes a pod from a Service (Phase 5) and in failure engineering.
    mock_ready: bool = True

    # --- OpenAICompatBackend: any server that speaks the OpenAI chat-completions API ---
    # Default is Ollama's OpenAI-compatible endpoint on the same host (used from Phase 11).
    openai_base_url: str = "http://localhost:11434/v1"
    # No default on purpose: the model is chosen in Phase 11, not guessed here.
    openai_model: str = ""
    # Never logged and never shown in repr(): SecretStr hides the value.
    openai_api_key: SecretStr | None = None

    @model_validator(mode="after")
    def _openai_needs_a_model(self) -> Self:
        if self.backend == "openai_compat" and not self.openai_model:
            raise ValueError("POLARIS_OPENAI_MODEL must be set when POLARIS_BACKEND=openai_compat")
        return self
