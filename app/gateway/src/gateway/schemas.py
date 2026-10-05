"""Shapes the gateway itself needs to know about.

ai-gateway does not define the chat API's request/response bodies -- it proxies them
byte-for-byte to ai_service and back (main.py's ``_proxy``). It only needs to know the one
field it must look at to enforce docs/architecture.md section 7's rule #1 ("a tenant identity
supplied by the caller must never be authoritative"): ``tenant_id``. TENANT_ID_PATTERN is
duplicated from ai_service/schemas.py on purpose -- the two services are separate deployable
units with no shared library (see config.py's module docstring) -- and must stay in sync by
hand; test_auth.py pins this with a literal copy of the pattern.
"""

from pydantic import BaseModel

TENANT_ID_PATTERN = r"^[a-z0-9][a-z0-9_-]{0,31}$"


class ErrorDetail(BaseModel):
    field: str
    problem: str


class ErrorBody(BaseModel):
    code: str
    message: str
    request_id: str
    details: list[ErrorDetail] | None = None


class ErrorResponse(BaseModel):
    """Same envelope as ai_service/schemas.py's ErrorResponse, deliberately -- a client should
    not be able to tell, from the shape of an error body alone, whether it was rejected at the
    gateway or by ai_service itself.
    """

    error: ErrorBody


class StatusResponse(BaseModel):
    status: str
