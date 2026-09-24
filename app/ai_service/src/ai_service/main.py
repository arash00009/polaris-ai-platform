"""The FastAPI application: POST /v1/chat in front of a ModelBackend, plus two probes.

Run locally (see `make app-run`):
  uvicorn ai_service.main:create_app --factory --host 127.0.0.1 --port 8000 --no-access-log
The service writes its own access log line per request, which carries the request id, so
uvicorn's access log is switched off.
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
from ai_service.logging_setup import configure_logging
from ai_service.schemas import (
    ChatRequest,
    ChatResponse,
    ErrorBody,
    ErrorDetail,
    ErrorResponse,
    StatusResponse,
)
from ai_service.telemetry import setup_telemetry, shutdown_telemetry

logger = logging.getLogger("ai_service")
access_logger = logging.getLogger("ai_service.access")

REQUEST_ID_HEADER = "x-request-id"
# A client-supplied request id is only trusted if it is short and made of harmless characters.
# Otherwise it could inject fake lines into logs or blow up the cardinality of a label.
_SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
# Probes hit these every few seconds; their access lines would drown everything else. /metrics
# joins them from Phase 9: Prometheus scrapes it on the same cadence as a probe.
_PROBE_PATHS = frozenset({"/healthz", "/readyz", "/metrics"})


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


def create_app(settings: Settings | None = None, backend: ModelBackend | None = None) -> FastAPI:
    """Build the app. ``settings`` and ``backend`` can be injected, which keeps tests simple."""
    settings = settings or Settings()
    configure_logging(settings.log_level, settings.log_format)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.backend = backend or build_backend(settings)
        try:
            yield
        finally:
            await app.state.backend.aclose()
            shutdown_telemetry(app)

    app = FastAPI(title="Polaris AI service", version=__version__, lifespan=lifespan)
    app.state.settings = settings
    # Metrics (always) and, if POLARIS_OTEL_ENABLED, traces/logs (see ai_service/telemetry.py).
    # Done before any other middleware is registered, same as upstream's own recommendation for
    # both instrumentors: prometheus-fastapi-instrumentator's request middleware and
    # OpenTelemetry's ASGI wrapper both want to see the request before anything else touches it.
    setup_telemetry(app, settings)

    @app.middleware("http")
    async def request_id_middleware(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        supplied = request.headers.get(REQUEST_ID_HEADER, "")
        request_id = supplied if _SAFE_REQUEST_ID.fullmatch(supplied) else uuid.uuid4().hex
        request.state.request_id = request_id
        started = time.perf_counter()
        status = 500  # what the client gets if the handler below raises past this middleware
        try:
            response = await call_next(request)
            status = response.status_code
            response.headers[REQUEST_ID_HEADER] = request_id
            return response
        finally:
            # Path only, never the query string: it can carry data the caller did not mean to
            # log. Probe requests are logged at DEBUG so they do not flood the log.
            access_logger.log(
                logging.DEBUG if request.url.path in _PROBE_PATHS else logging.INFO,
                "http request",
                extra={
                    "request_id": request_id,
                    "method": request.method,
                    "path": request.url.path,
                    "status": status,
                    "duration_ms": round((time.perf_counter() - started) * 1000, 1),
                },
            )

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
        logger.exception("unhandled error", extra={"request_id": _request_id_of(request)})
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
                "chat failed",
                extra={
                    "request_id": request_id,
                    "tenant_id": body.tenant_id,
                    "code": "backend_timeout",
                },
            )
            raise ApiError(
                504, "backend_timeout", "The model backend did not answer in time."
            ) from exc
        except BackendError as exc:
            logger.warning(
                "chat failed",
                extra={
                    "request_id": request_id,
                    "tenant_id": body.tenant_id,
                    "code": "backend_error",
                    "reason": str(exc),
                },
            )
            raise ApiError(502, "backend_error", "The model backend failed.") from exc

        latency_ms = round((time.perf_counter() - started) * 1000, 1)
        logger.info(
            "chat completed",
            extra={
                "request_id": request_id,
                "tenant_id": body.tenant_id,
                "model": result.model,
                "latency_ms": latency_ms,
                "prompt_tokens": result.prompt_tokens,
                "completion_tokens": result.completion_tokens,
            },
        )
        return ChatResponse(
            response=result.text,
            model=result.model,
            request_id=request_id,
            latency_ms=latency_ms,
        )

    @app.get("/healthz", response_model=StatusResponse, tags=["probes"])
    async def healthz() -> StatusResponse:
        """Liveness: the process is running and can answer HTTP.

        It checks nothing else on purpose. If liveness depended on the model backend, a slow
        model server would make Kubernetes restart healthy pods, which only adds load.
        """
        return StatusResponse(status="ok")

    @app.get(
        "/readyz",
        response_model=StatusResponse,
        tags=["probes"],
        responses={503: {"model": ErrorResponse, "description": "The backend is not ready"}},
    )
    async def readyz(request: Request) -> StatusResponse:
        """Readiness: the service can take traffic now, meaning its backend is reachable."""
        try:
            async with asyncio.timeout(settings.ready_timeout_s):
                await request.app.state.backend.check_ready()
        except (TimeoutError, BackendError) as exc:
            logger.warning(
                "readiness check failed",
                extra={
                    "request_id": _request_id_of(request),
                    "code": "not_ready",
                    "reason": str(exc) or "readiness check timed out",
                },
            )
            raise ApiError(503, "not_ready", "The model backend is not ready.") from exc
        return StatusResponse(status="ready")

    return app
