"""The gateway's HTTP behaviour: auth, tenant derivation, rate limit, quota, proxying, probes.

Mirrors app/ai_service/tests/test_chat_api.py's style: a TestClient against create_app(), a
fake transport standing in for the real dependency (there: ModelBackend; here: ai_service
itself), assertions on status code and the ErrorResponse envelope's shape.
"""

import pytest

from gateway.config import Settings
from tests.conftest import DEMO_API_KEY, DEMO_TENANT, auth_headers, chat_body
from tests.fakes import error_chat_handler, timeout_handler, unreachable_handler


def test_missing_api_key_is_401(client):
    response = client.post("/v1/chat", json={"tenant_id": DEMO_TENANT, "prompt": "hi"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


def test_unknown_api_key_is_401(client):
    response = client.post(
        "/v1/chat",
        json={"tenant_id": DEMO_TENANT, "prompt": "hi"},
        headers=auth_headers("sk-not-a-real-key-at-all"),
    )
    assert response.status_code == 401


def test_valid_key_proxies_successfully(client):
    response = client.post(
        "/v1/chat",
        content=chat_body(),
        headers={**auth_headers(), "content-type": "application/json"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["response"] == "a mock answer"
    assert body["model"] == "mock-1"
    # The gateway's own generated request id round-trips: forwarded to the fake upstream,
    # echoed back by it, and present on the response headers too (main.py's docstring step 6).
    assert response.headers["x-request-id"] == body["request_id"]


def test_gateway_derives_tenant_and_forwards_its_own_request_id(build_client):
    test_client, upstream = build_client()
    with test_client as tc:
        response = tc.post(
            "/v1/chat",
            content=chat_body(),
            headers={
                **auth_headers(),
                "content-type": "application/json",
                "x-request-id": "client-rid-123",
            },
        )
    assert response.status_code == 200
    assert len(upstream.requests) == 1
    forwarded = upstream.requests[0]
    # The client-supplied request id is trusted (it matches _SAFE_REQUEST_ID) and forwarded...
    assert forwarded.headers["x-request-id"] == "client-rid-123"
    # ...and the tenant header is set from what the API key resolved to, never copied from a
    # client-controllable header (there is no client-controllable tenant header at all).
    assert forwarded.headers["x-tenant-id"] == DEMO_TENANT
    # The API key itself must never reach ai_service.
    assert "x-api-key" not in forwarded.headers
    assert response.headers["x-request-id"] == "client-rid-123"


def test_tenant_mismatch_is_403(client):
    # The API key resolves to "demo", but the body claims a different tenant.
    response = client.post(
        "/v1/chat",
        content=chat_body(tenant_id="someone-else"),
        headers={**auth_headers(), "content-type": "application/json"},
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "tenant_mismatch"


def test_malformed_body_is_let_through_to_upstream_not_rejected_here(build_client):
    """A body the gateway cannot even read a tenant_id from is not this module's job to
    reject -- ai_service owns full body validation (main.py's docstring, step 3). The fake
    upstream here answers its normal 200, proving the gateway did not short-circuit it.
    """
    test_client, upstream = build_client()
    with test_client as tc:
        response = tc.post(
            "/v1/chat",
            content="not json at all",
            headers={**auth_headers(), "content-type": "application/json"},
        )
    assert response.status_code == 200
    assert len(upstream.requests) == 1


@pytest.mark.parametrize(
    ("upstream_status", "upstream_code"),
    [(422, "invalid_request"), (502, "backend_error"), (504, "backend_timeout")],
)
def test_upstream_error_responses_pass_through_unchanged(
    build_client, upstream_status, upstream_code
):
    test_client, _ = build_client(handler=error_chat_handler(upstream_status, code=upstream_code))
    with test_client as tc:
        response = tc.post(
            "/v1/chat",
            content=chat_body(),
            headers={**auth_headers(), "content-type": "application/json"},
        )
    assert response.status_code == upstream_status
    assert response.json()["error"]["code"] == upstream_code


def test_upstream_unreachable_is_502(build_client):
    test_client, _ = build_client(handler=unreachable_handler())
    with test_client as tc:
        response = tc.post(
            "/v1/chat",
            content=chat_body(),
            headers={**auth_headers(), "content-type": "application/json"},
        )
    assert response.status_code == 502
    assert response.json()["error"]["code"] == "upstream_unreachable"


def test_upstream_timeout_is_504(build_client):
    test_client, _ = build_client(handler=timeout_handler())
    with test_client as tc:
        response = tc.post(
            "/v1/chat",
            content=chat_body(),
            headers={**auth_headers(), "content-type": "application/json"},
        )
    assert response.status_code == 504
    assert response.json()["error"]["code"] == "upstream_timeout"


def test_rate_limit_rejects_after_burst_is_used(build_client):
    settings = Settings(rate_limit_per_minute=60, rate_limit_burst=2, quota_per_day=1000)
    test_client, _ = build_client(settings=settings)
    with test_client as tc:
        headers = {**auth_headers(), "content-type": "application/json"}
        first = tc.post("/v1/chat", content=chat_body(), headers=headers)
        second = tc.post("/v1/chat", content=chat_body(), headers=headers)
        third = tc.post("/v1/chat", content=chat_body(), headers=headers)
    assert first.status_code == 200
    assert second.status_code == 200
    assert third.status_code == 429
    assert third.json()["error"]["code"] == "rate_limited"
    assert "Retry-After" in third.headers


def test_daily_quota_rejects_once_used_up(build_client):
    settings = Settings(rate_limit_per_minute=100_000, rate_limit_burst=100_000, quota_per_day=1)
    test_client, _ = build_client(settings=settings)
    with test_client as tc:
        headers = {**auth_headers(), "content-type": "application/json"}
        first = tc.post("/v1/chat", content=chat_body(), headers=headers)
        second = tc.post("/v1/chat", content=chat_body(), headers=headers)
    assert first.status_code == 200
    assert second.status_code == 429
    assert second.json()["error"]["code"] == "quota_exceeded"


def test_rate_limit_and_quota_are_per_tenant(build_client):
    """One tenant using up its own limit must not affect a different tenant."""
    from gateway.auth import ApiKeyStore

    other_key = "sk-acme-0123456789abcdef"
    keys = ApiKeyStore.from_mapping({DEMO_API_KEY: DEMO_TENANT, other_key: "acme-corp"})
    settings = Settings(rate_limit_per_minute=60, rate_limit_burst=1, quota_per_day=1000)
    test_client, _ = build_client(settings=settings, keys=keys)
    with test_client as tc:
        headers_demo = {**auth_headers(DEMO_API_KEY), "content-type": "application/json"}
        headers_acme = {**auth_headers(other_key), "content-type": "application/json"}
        demo_first = tc.post("/v1/chat", content=chat_body(DEMO_TENANT), headers=headers_demo)
        demo_second = tc.post("/v1/chat", content=chat_body(DEMO_TENANT), headers=headers_demo)
        acme_first = tc.post("/v1/chat", content=chat_body("acme-corp"), headers=headers_acme)
    assert demo_first.status_code == 200
    assert demo_second.status_code == 429
    assert acme_first.status_code == 200


def test_healthz_does_not_depend_on_upstream(build_client):
    test_client, _ = build_client(handler=unreachable_handler())
    with test_client as tc:
        response = tc.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_ok_when_upstream_healthy(client):
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"


def test_readyz_503_when_upstream_unreachable(build_client):
    test_client, _ = build_client(handler=unreachable_handler())
    with test_client as tc:
        response = tc.get("/readyz")
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "not_ready"


def test_zero_keys_configured_still_starts_and_401s(build_client):
    from gateway.auth import ApiKeyStore

    test_client, _ = build_client(keys=ApiKeyStore.from_mapping({}))
    with test_client as tc:
        response = tc.post(
            "/v1/chat",
            content=chat_body(),
            headers={**auth_headers(), "content-type": "application/json"},
        )
    assert response.status_code == 401
