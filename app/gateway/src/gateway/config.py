"""Runtime configuration for ai-gateway, read from environment variables (prefix ``GATEWAY_``).

Same twelve-factor discipline as ai_service/config.py (Phase 2): one image, environment
variables change per environment. Deliberately a *separate* Settings class in a separate
package rather than importing ai_service's -- the gateway is its own deployable unit with its
own Dockerfile and its own release cadence (see docs/gateway.md, ADR-30), and the two services
already share nothing at the Python-import level (there is no shared library in this repo, by
design -- see docs/architecture.md Part D's layout). A handful of fields below are therefore
intentionally duplicated from ai_service/config.py (log_level, log_format, environment,
otel_*) -- same reasoning scripts/deploy/helm.sh's own header gives for its own duplication:
a change to one service's config must never be able to silently alter the other's.

Status: written and unit-tested in the sandbox (test_config.py). Not yet run against a real
Kubernetes Secret for GATEWAY_API_KEYS -- that is this phase's target-machine step, same split
every earlier Kubernetes-facing phase in this project has followed.
"""

import json
import re
from typing import Literal, Self

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from gateway.schemas import TENANT_ID_PATTERN

# A real-looking API key is at least this long. Not a cryptographic property -- just cheap
# protection against someone pasting a tenant id or a placeholder like "changeme" into the
# keys map and getting a working credential by accident.
MIN_API_KEY_LENGTH = 16


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="GATEWAY_", extra="ignore", frozen=True)

    # --- Upstream (ai_service) ---
    # Same-namespace short DNS name: gateway and ai-service are always deployed into the same
    # polaris-<env> namespace (helm/ai-platform/templates/gateway-deployment.yaml), so no FQDN
    # is needed. Port 80 is the ai-service Service's port (templates/service.yaml), not its
    # container port 8000.
    upstream_base_url: str = Field(default="http://ai-service:80", min_length=1)
    # Phase 11 measured a real cold Ollama load at ~50.5s in polaris-dev and raised
    # POLARIS_BACKEND_TIMEOUT_S there to 90s (ADR-29). A gateway timeout shorter than the
    # upstream's own timeout would make the gateway give up and return 504 while ai-service is
    # still legitimately working -- so this default is deliberately >= that 90s, not the
    # generic 30s ai_service itself defaults to. values-dev.yaml sets it explicitly to 95
    # (90s + a 5s margin) rather than relying on this default; see docs/gateway.md.
    upstream_timeout_s: float = Field(default=95.0, gt=0, le=300)

    # --- Auth / tenancy ---
    # A JSON object string, "<api key>": "<tenant_id>", e.g. {"sk-demo-...": "demo"}. Kept as
    # SecretStr (never parsed eagerly on Settings, never exposed by repr()/logs) -- see
    # auth.py's ApiKeyStore.from_settings(), which parses it once at startup into an object
    # that is never logged either. Empty by default so a misconfigured deployment fails closed
    # (every request gets 401) instead of silently accepting none.
    api_keys_json: SecretStr = Field(default=SecretStr("{}"))

    # --- Per-tenant rate limit (token bucket) and quota (fixed daily window) ---
    # Both are LOCAL/DEMONSTRATION: in-memory, per-pod state (see ratelimit.py's module
    # docstring for why, and the honest limitation this creates with replicaCount > 1 or a pod
    # restart). A PRODUCTION EQUIVALENT would back this with Redis (e.g. a Lua-scripted token
    # bucket) shared across every gateway replica -- named here, not built.
    rate_limit_per_minute: int = Field(default=60, ge=1, le=100_000)
    rate_limit_burst: int = Field(default=20, ge=1, le=100_000)
    quota_per_day: int = Field(default=2_000, ge=1, le=10_000_000)

    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    log_format: Literal["text", "json"] = "text"
    ready_timeout_s: float = Field(default=2.0, gt=0, le=30)
    environment: str = Field(default="local", min_length=1, max_length=32)

    # --- Observability (same pattern as ai_service/config.py, Phase 9/10) ---
    otel_enabled: bool = False
    otel_exporter_otlp_endpoint: str = Field(
        default="http://otel-collector.observability.svc.cluster.local:4318",
        min_length=1,
    )
    otel_exporter_timeout_s: float = Field(default=3.0, gt=0, le=10)

    @field_validator("api_keys_json")
    @classmethod
    def _api_keys_must_be_a_json_object(cls, value: SecretStr) -> SecretStr:
        try:
            parsed = json.loads(value.get_secret_value())
        except json.JSONDecodeError as exc:
            raise ValueError("GATEWAY_API_KEYS_JSON must be a JSON object") from exc
        if not isinstance(parsed, dict):
            raise ValueError("GATEWAY_API_KEYS_JSON must be a JSON object, not a list/scalar")
        for api_key, tenant_id in parsed.items():
            if not isinstance(api_key, str) or len(api_key) < MIN_API_KEY_LENGTH:
                raise ValueError(f"API key is shorter than {MIN_API_KEY_LENGTH} characters")
            if not isinstance(tenant_id, str) or not re.fullmatch(TENANT_ID_PATTERN, tenant_id):
                raise ValueError(f"'{tenant_id}' is not a valid tenant_id")
        return value

    @model_validator(mode="after")
    def _warn_on_no_keys(self) -> Self:
        # Not an error -- a gateway with zero keys configured is a valid (if useless) state for
        # tests and for `helm lint`'s placeholder values -- but see main.py's startup log line,
        # which does surface this loudly in a real deployment.
        return self
