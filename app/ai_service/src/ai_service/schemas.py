"""Request and response bodies of the HTTP API."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

# A tenant id is a short, lower-case slug. It ends up in logs, metrics labels and (later)
# cost reports, so it is restricted to a safe, low-cardinality alphabet.
TENANT_ID_PATTERN = r"^[a-z0-9][a-z0-9_-]{0,31}$"
MAX_PROMPT_CHARS = 4000


class ChatRequest(BaseModel):
    # Unknown fields are an error, not silently ignored: typos surface immediately.
    model_config = ConfigDict(extra="forbid")

    tenant_id: str = Field(pattern=TENANT_ID_PATTERN, examples=["demo"])
    prompt: str = Field(
        min_length=1, max_length=MAX_PROMPT_CHARS, examples=["Explain Kubernetes pods"]
    )

    @field_validator("prompt")
    @classmethod
    def _not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("prompt must contain something other than whitespace")
        return value


class ChatResponse(BaseModel):
    response: str
    model: str
    request_id: str
    # Time spent in the model backend call, in milliseconds (not the whole HTTP request).
    latency_ms: float


class StatusResponse(BaseModel):
    """Body of the two probe endpoints. Deliberately tiny: probes run every few seconds."""

    status: Literal["ok", "ready"]


class ErrorDetail(BaseModel):
    field: str
    problem: str


class ErrorBody(BaseModel):
    code: str
    message: str
    request_id: str
    details: list[ErrorDetail] | None = None


class ErrorResponse(BaseModel):
    error: ErrorBody
