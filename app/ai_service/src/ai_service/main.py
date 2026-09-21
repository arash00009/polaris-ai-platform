"""The FastAPI application: POST /v1/chat in front of a ModelBackend.

Run locally:  uvicorn ai_service.main:create_app --factory --host 127.0.0.1 --port 8000
"""

import asyncio
import logging
import re
import time
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from ai_service import __version__
from ai_service.backends import BackendError, BackendTimeout, ModelBackend, build_backend
from ai_service.config import Settings
from ai_service.schemas import ChatRequest, ChatResponse, ErrorBody, ErrorDetail, ErrorResponse

logger = logging.getLogger("ai_service")

REQUEST_ID_HEADER = "x-request-id"
# A client-supplied request id is only trusted if it is short and made of harmless characters.
# Otherwise it could inject fake lines into logs or blow up the cardinality of a label.
_SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


class ApiError(Exception):
    """An error that maps to a specific HTTP status and a stable error code."""

    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


def _request_id_of(request: Request) -> str:
    return getattr(request.state, "request_id", "unknown")


def _error_response(
    request: Request,
    status_code: int,
    code: str,
    message: str,
    details: list[ErrorDetail] | None = None,
) -> JSONResponse:
    body = ErrorResponse(
        error=ErrorBody(
            code=code, message=message, request_id=_request_id_of(request), details=details
        )
    )
    return JSONResponse(status_code=status_code, content=body.model_dump(exclude_none=True))


def _configure_logging(level: str) -> None:
    # No-op if the process already configured logging (uvicorn, pytest). Structured JSON
    # logging replaces this simple format in Phase 3.
    logging.basicConfig(level=level, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    logger.setLevel(level)


def create_app(settings: Settings | None = None, backend: ModelBackend | None = None) -> FastAPI:
    """Build the app. ``settings`` and ``backend`` can be injected, which keeps tests simple."""
    settings = settings or Settings()
    _configure_logging(settings.log_level)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.backend = backend or build_backend(settings)
        try:
            yield
        finally:
            await app.state.backend.aclose()

    app = FastAPI(title="Polaris AI service", version=__version__, lifespan=lifespan)
    app.state.settings = settings

    @app.middleware("http")
    async def request_id_middleware(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        supplied = request.headers.get(REQUEST_ID_HEADER, "")
        request_id = supplied if _SAFE_REQUEST_ID.fullmatch(supplied) else uuid.uuid4().hex
        request.state.request_id = request_id
        response = await call_next(request)
        response.headers[REQUEST_ID_HEADER] = request_id
        return response

    @app.exception_handler(ApiError)
    async def handle_api_error(request: Request, exc: ApiError) -> JSONResponse:
        return _error_response(request, exc.status_code, exc.code, exc.message)

    @app.exception_handler(RequestValidationError)
    async def handle_validation_error(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        # Report which field is wrong and why, but never echo the submitted values: a prompt
        # can contain personal or confidential data.
        details = [
            ErrorDetail(field=".".join(str(part) for part in err["loc"]), problem=err["msg"])
            for err in exc.errors()
        ]
        return _error_response(
            request, 422, "invalid_request", "The request body is not valid.", details
        )

    @app.exception_handler(StarletteHTTPException)
    async def handle_http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        # Routing errors (404, 405) get the same envelope as every other error.
        codes = {404: "not_found", 405: "method_not_allowed"}
        response = _error_response(
            request, exc.status_code, codes.get(exc.status_code, "http_error"), str(exc.detail)
        )
        # Keep headers such as "Allow" on a 405.
        response.headers.update(exc.headers or {})
        return response

    @app.exception_handler(Exception)
    async def handle_unexpected(request: Request, exc: Exception) -> JSONResponse:
        logger.exception("unhandled error request_id=%s", _request_id_of(request))
        return _error_response(request, 500, "internal_error", "Internal server error.")

    @app.post(
        "/v1/chat",
        response_model=ChatResponse,
        responses={
            422: {"model": ErrorResponse, "description": "Invalid request body"},
            502: {"model": ErrorResponse, "description": "The model backend failed"},
            504: {"model": ErrorResponse, "description": "The model backend timed out"},
        },
    )
    async def chat(body: ChatRequest, request: Request) -> ChatResponse:
        request_id = _request_id_of(request)
        started = time.perf_counter()
        try:
            async with asyncio.timeout(settings.backend_timeout_s):
                result = await request.app.state.backend.generate(body.prompt)
        except (TimeoutError, BackendTimeout) as exc:
            # The prompt is deliberately never logged: it can hold personal data.
            logger.warning(
                "chat failed request_id=%s tenant_id=%s code=backend_timeout",
                request_id,
                body.tenant_id,
            )
            raise ApiError(
                504, "backend_timeout", "The model backend did not answer in time."
            ) from exc
        except BackendError as exc:
            logger.warning(
                "chat failed request_id=%s tenant_id=%s code=backend_error reason=%s",
                request_id,
                body.tenant_id,
                exc,
            )
            raise ApiError(502, "backend_error", "The model backend failed.") from exc

        latency_ms = round((time.perf_counter() - started) * 1000, 1)
        logger.info(
            "chat completed request_id=%s tenant_id=%s model=%s latency_ms=%s "
            "prompt_tokens=%s completion_tokens=%s",
            request_id,
            body.tenant_id,
            result.model,
            latency_ms,
            result.prompt_tokens,
            result.completion_tokens,
        )
        return ChatResponse(
            response=result.text,
            model=result.model,
            request_id=request_id,
            latency_ms=latency_ms,
        )

    return app
