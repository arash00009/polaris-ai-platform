"""ai-gateway: the FastAPI app in front of ai_service. Phase 12.

docs/architecture.md section 7 ("AI request flow") is the spec this module implements:

    C->>I: POST /v1/chat with API key
    I->>G: forward request, W3C traceparent header
    G->>G: authenticate key, resolve tenant, check rate limit and quota
    alt rejected
        G-->>C: 401, 403 or 429 with request_id
    else accepted
        G->>S: forward with x-request-id and x-tenant-id
        ...
        S-->>G: 200 with response, model, request_id, latency_ms
        G-->>C: 200 with same body
    end

Concretely, for every request to a proxied path (currently just POST /v1/chat):

1. A request id is resolved exactly the way ai_service/main.py already does (a trusted
   client-supplied x-request-id, or a fresh one) -- same regex, same header name, so a request
   id assigned at the gateway and one assigned by ai_service directly (if ever called without
   going through the gateway) are indistinguishable in form.
2. The caller's API key (``x-api-key``) is resolved to a tenant_id via auth.ApiKeyStore. Missing
   or unknown key -> 401. This never reads the request body.
3. The request body is parsed just far enough to read ``tenant_id`` (schemas.TENANT_ID_PATTERN).
   If it does not match the tenant the API key resolved to, 403 -- docs/architecture.md section
   7's design decision #1: "a tenant identity supplied by the caller must never be authoritative."
   A body that cannot even be parsed as JSON, or has no tenant_id at all, is let through to
   ai_service unchanged and gets ai_service's own 422 -- the gateway does not duplicate full
   request-body validation (ai_service already owns that contract; see docs/architecture.md
   section 4.1's layer table).
4. Rate limit (token bucket) then daily quota are checked for the resolved tenant. Either one
   failing -> 429, with a ``Retry-After`` header for the rate-limit case (quota has no
   meaningful retry time within a request's lifetime, so none is sent for that case).
5. The request is forwarded to ai_service with x-request-id and x-tenant-id set from what the
   gateway itself resolved (not copied from the client), over an httpx.AsyncClient instrumented
   for trace-context propagation (telemetry.py's module docstring explains why that is enough
   for cross-service tracing with no code in this file).
6. ai_service's response -- status code, JSON body, and headers -- is returned to the caller
   unchanged, except x-request-id is guaranteed to be present (it already will be, since the
   gateway just sent it, but this makes the guarantee explicit rather than incidental).

Streaming (SSE): docs/architecture.md's roadmap line for this phase says "streaming if
practical". It is not built in this delivery -- ai_service's own ModelBackend interface
(backends/base.py) has no streaming method, and OpenAICompatBackend's generate() always sends
"stream": false, so there is no streaming response from ai_service to pass through yet. Adding
it is a two-service change (ai_service's backend interface, then this gateway's proxy), named
here as a deliberate, explicit gap rather than half-built on one side -- see docs/gateway.md
section 6.
"""

import asyncio
import json
import logging
import re
import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

from gateway import __version__
from gateway.auth import API_KEY_HEADER, ApiKeyStore
from gateway.config import Settings
from gateway.logging_setup import configure_logging
from gateway.ratelimit import DailyQuota, TokenBucketLimiter
from gateway.schemas import TENANT_ID_PATTERN, ErrorBody, ErrorResponse, StatusResponse
from gateway.telemetry import setup_telemetry, shutdown_telemetry

logger = logging.getLogger("gateway")
access_logger = logging.getLogger("gateway.access")

REQUEST_ID_HEADER = "x-request-id"
TENANT_ID_HEADER = "x-tenant-id"
_SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
_TENANT_ID_RE = re.compile(TENANT_ID_PATTERN)
# Headers that must never be forwarded as-is in either direction: hop-by-hop headers (RFC 9110
# section 7.6.1) that only make sense between one pair of endpoints, plus content-length, which
# httpx recomputes itself for the outgoing request body and which can go stale if copied.
_DO_NOT_FORWARD = frozenset(
    {
        "connection",
        "keep-alive",
        "transfer-encoding",
        "content-length",
        "host",
        API_KEY_HEADER,  # never forwarded upstream: ai_service has no business seeing it
    }
)

# Only this one route is proxied in this delivery. A gateway that proxies "everything" would
# also have to proxy /healthz, /readyz and /metrics, which would then mean something different
# per-service and collide -- this project deliberately keeps the gateway's own probes and
# ai_service's probes separate (see the two GET handlers below), and only forwards the actual
# chat traffic docs/architecture.md section 7 is written for.
PROXIED_PATH = "/v1/chat"


def _request_id_of(request: Request) -> str:
    return getattr(request.state, "request_id", "unknown")


def _error_response(
    request: Request,
    status_code: int,
    code: str,
    message: str,
    *,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    body = ErrorResponse(
        error=ErrorBody(code=code, message=message, request_id=_request_id_of(request))
    )
    return JSONResponse(
        status_code=status_code, content=body.model_dump(exclude_none=True), headers=headers
    )


def create_app(
    settings: Settings | None = None,
    *,
    client: httpx.AsyncClient | None = None,
    api_keys: ApiKeyStore | None = None,
) -> FastAPI:
    """Build the app. ``client`` and ``api_keys`` can be injected -- same pattern as
    ai_service/main.py's create_app(settings, backend) -- which keeps tests simple: a test can
    point the gateway at an in-process fake transport instead of a real ai_service.
    """
    settings = settings or Settings()
    configure_logging(settings.log_level, settings.log_format)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.api_keys = api_keys or ApiKeyStore.from_settings(settings)
        if len(app.state.api_keys) == 0:
            # Not fatal -- a chart install can legitimately run with no tenants provisioned
            # yet -- but every request will 401, so this is worth a loud startup line rather
            # than a silent surprise the first time someone tries to call the API.
            logger.warning("gateway started with zero API keys configured; every request will 401")
        app.state.http_client = client or httpx.AsyncClient(
            base_url=settings.upstream_base_url, timeout=settings.upstream_timeout_s
        )
        app.state.owns_http_client = client is None
        if settings.otel_enabled:
            # Per-CLIENT instrumentation (wraps this one httpx.AsyncClient's transport
            # directly), not the global HTTPXClientInstrumentor().instrument() the library also
            # offers. This was not the first thing tried: instrument() patches
            # httpx._transports.default.{HTTPTransport,AsyncHTTPTransport} at the class level,
            # which is exactly the right hook for a real connection -- but it is *why*
            # app/ai_service/requirements.txt's own comment calls that instrumentor
            # process-global, and it was confirmed for real in this phase's test suite to never
            # fire against an httpx.MockTransport (test doubles implement
            # handle_async_request() themselves and never go through the patched default
            # transport class at all) -- see test_telemetry.py. instrument_client() wraps the
            # transport instance actually attached to THIS client, which works identically for
            # a real connection and for a MockTransport, and, as a side benefit, is exactly the
            # narrower, non-global instrumentation ai_service's own comment said made the
            # process-global form "not worth the risk".
            HTTPXClientInstrumentor().instrument_client(app.state.http_client)
        app.state.rate_limiter = TokenBucketLimiter(
            capacity=settings.rate_limit_burst,
            rate_per_second=settings.rate_limit_per_minute / 60.0,
        )
        app.state.quota = DailyQuota(limit=settings.quota_per_day)
        try:
            yield
        finally:
            if settings.otel_enabled:
                HTTPXClientInstrumentor().uninstrument_client(app.state.http_client)
            if app.state.owns_http_client:
                await app.state.http_client.aclose()
            shutdown_telemetry(app)

    app = FastAPI(title="Polaris ai-gateway", version=__version__, lifespan=lifespan)
    app.state.settings = settings
    # Metrics (always) and, if GATEWAY_OTEL_ENABLED, traces/logs -- same ordering reasoning as
    # ai_service/main.py: before any other middleware is registered.
    setup_telemetry(app, settings)

    @app.middleware("http")
    async def request_id_middleware(request: Request, call_next):
        supplied = request.headers.get(REQUEST_ID_HEADER, "")
        request_id = supplied if _SAFE_REQUEST_ID.fullmatch(supplied) else uuid.uuid4().hex
        request.state.request_id = request_id
        started = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            response.headers[REQUEST_ID_HEADER] = request_id
            return response
        finally:
            if request.url.path not in ("/healthz", "/readyz", "/metrics"):
                access_logger.log(
                    logging.INFO,
                    "http request",
                    extra={
                        "request_id": request_id,
                        "method": request.method,
                        "path": request.url.path,
                        "status": status,
                        "duration_ms": round((time.perf_counter() - started) * 1000, 1),
                    },
                )

    @app.post(PROXIED_PATH)
    async def chat(request: Request) -> Response:
        request_id = _request_id_of(request)
        span = trace.get_current_span()

        raw_body = await request.body()
        api_key_store: ApiKeyStore = request.app.state.api_keys
        tenant_id = api_key_store.resolve(request.headers.get(API_KEY_HEADER, ""))
        if tenant_id is None:
            logger.warning(
                "chat rejected", extra={"request_id": request_id, "code": "unauthorized"}
            )
            return _error_response(request, 401, "unauthorized", "Missing or unknown API key.")
        span.set_attribute("tenant_id", tenant_id)
        span.set_attribute("request_id", request_id)

        body_tenant_id = _tenant_id_in_body(raw_body)
        if body_tenant_id is not None and body_tenant_id != tenant_id:
            logger.warning(
                "chat rejected",
                extra={"request_id": request_id, "tenant_id": tenant_id, "code": "tenant_mismatch"},
            )
            return _error_response(
                request,
                403,
                "tenant_mismatch",
                "The request body's tenant_id does not match the API key's tenant.",
            )

        limiter: TokenBucketLimiter = request.app.state.rate_limiter
        if not limiter.allow(tenant_id):
            logger.warning(
                "chat rejected",
                extra={"request_id": request_id, "tenant_id": tenant_id, "code": "rate_limited"},
            )
            return _error_response(
                request,
                429,
                "rate_limited",
                "Too many requests for this tenant. Slow down and retry.",
                headers={"Retry-After": "1"},
            )

        quota: DailyQuota = request.app.state.quota
        if not quota.allow(tenant_id):
            logger.warning(
                "chat rejected",
                extra={"request_id": request_id, "tenant_id": tenant_id, "code": "quota_exceeded"},
            )
            return _error_response(
                request, 429, "quota_exceeded", "This tenant's daily request quota is used up."
            )

        started = time.perf_counter()
        client: httpx.AsyncClient = request.app.state.http_client
        forward_headers = {
            key: value
            for key, value in request.headers.items()
            if key.lower() not in _DO_NOT_FORWARD
        }
        forward_headers[REQUEST_ID_HEADER] = request_id
        forward_headers[TENANT_ID_HEADER] = tenant_id
        try:
            upstream_response = await client.post(
                PROXIED_PATH, content=raw_body, headers=forward_headers
            )
        except httpx.TimeoutException:
            logger.warning(
                "chat upstream timeout",
                extra={
                    "request_id": request_id,
                    "tenant_id": tenant_id,
                    "code": "upstream_timeout",
                },
            )
            return _error_response(
                request, 504, "upstream_timeout", "ai-service did not answer in time."
            )
        except httpx.RequestError:
            logger.warning(
                "chat upstream unreachable",
                extra={
                    "request_id": request_id,
                    "tenant_id": tenant_id,
                    "code": "upstream_unreachable",
                },
            )
            return _error_response(
                request, 502, "upstream_unreachable", "ai-service is unreachable."
            )

        latency_ms = round((time.perf_counter() - started) * 1000, 1)
        access_logger.info(
            "chat proxied",
            extra={
                "request_id": request_id,
                "tenant_id": tenant_id,
                "upstream_status": upstream_response.status_code,
                "duration_ms": latency_ms,
            },
        )
        span.set_attribute("latency_ms", latency_ms)
        response_headers = {
            key: value
            for key, value in upstream_response.headers.items()
            if key.lower() not in _DO_NOT_FORWARD
        }
        response_headers[REQUEST_ID_HEADER] = request_id
        return Response(
            content=upstream_response.content,
            status_code=upstream_response.status_code,
            headers=response_headers,
            media_type=upstream_response.headers.get("content-type"),
        )

    @app.get("/healthz", response_model=StatusResponse, tags=["probes"])
    async def healthz() -> StatusResponse:
        """Liveness: the process itself, not ai_service. Same reasoning as ai_service/main.py's
        own healthz: liveness must not depend on anything downstream.
        """
        return StatusResponse(status="ok")

    @app.get(
        "/readyz",
        response_model=StatusResponse,
        tags=["probes"],
        responses={503: {"model": ErrorResponse, "description": "ai-service is not reachable"}},
    )
    async def readyz(request: Request) -> Response:
        """Readiness: can this gateway actually proxy right now, meaning is ai_service's own
        /healthz reachable. Deliberately checks ai_service's liveness probe, not its readiness
        probe: the gateway only needs to know ai_service's process is up and answering HTTP, the
        same distinction ai_service/main.py's own healthz/readyz draws for its model backend.
        """
        client: httpx.AsyncClient = request.app.state.http_client
        settings: Settings = request.app.state.settings
        try:
            async with asyncio.timeout(settings.ready_timeout_s):
                response = await client.get("/healthz")
            response.raise_for_status()
        except (TimeoutError, httpx.HTTPError) as exc:
            logger.warning(
                "readiness check failed",
                extra={
                    "request_id": _request_id_of(request),
                    "code": "not_ready",
                    "reason": str(exc),
                },
            )
            return _error_response(request, 503, "not_ready", "ai-service is not reachable.")
        return JSONResponse(content=StatusResponse(status="ready").model_dump())

    return app


def _tenant_id_in_body(raw_body: bytes) -> str | None:
    """Best-effort read of ``tenant_id`` from a request body, without validating anything else.

    Returns None for "nothing to compare" (not valid JSON, not an object, no tenant_id key, or
    a tenant_id that is not a plausible tenant id at all) -- in every one of those cases, step 3
    in this module's docstring lets the request through to ai_service, which owns full body
    validation and will itself return 422 for a genuinely malformed request. This function's
    only job is to catch a *mismatch* between a well-formed tenant_id and the authenticated
    tenant; it must never be the thing that rejects a malformed body, or the gateway and
    ai_service would disagree about what counts as invalid.
    """
    try:
        parsed = json.loads(raw_body)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(parsed, dict):
        return None
    value = parsed.get("tenant_id")
    if not isinstance(value, str) or not _TENANT_ID_RE.fullmatch(value):
        return None
    return value
