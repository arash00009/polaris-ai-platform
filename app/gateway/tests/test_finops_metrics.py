"""Phase 13 (FinOps): the gateway's one cost-attribution counter, ai_gateway_requests_total,
exposed on GET /metrics alongside prometheus-fastapi-instrumentator's generic HTTP ones. See
gateway/telemetry.py's module docstring for exactly what it means, why these labels, and why
they are cardinality-safe -- and ai_service/tests/test_finops_metrics.py for the service-side
counters this one is deliberately kept separate from (ai_service never sees a request the
gateway itself rejected).

Same technique as that module: every assertion reads the real exposition text off GET /metrics,
not the in-memory Counter, so a labelling mistake that would also break a real Prometheus scrape
cannot hide behind a test that only calls .labels() "correctly".
"""

import re

from gateway.config import Settings
from tests.conftest import DEMO_API_KEY, DEMO_TENANT, auth_headers, chat_body
from tests.fakes import error_chat_handler, timeout_handler, unreachable_handler


def _metric_value(text: str, name: str, **labels: str) -> float | None:
    label_str = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
    pattern = rf"^{re.escape(name)}\{{{re.escape(label_str)}\}} ([0-9.e+-]+)$"
    for line in text.splitlines():
        match = re.match(pattern, line)
        if match:
            return float(match.group(1))
    return None


def _json_headers() -> dict[str, str]:
    return {**auth_headers(), "content-type": "application/json"}


def test_missing_api_key_is_counted_as_unauthorized_with_tenant_unknown(client):
    client.post("/v1/chat", json={"tenant_id": DEMO_TENANT, "prompt": "hi"})
    text = client.get("/metrics").text
    assert (
        _metric_value(
            text, "ai_gateway_requests_total", tenant_id="unknown", outcome="unauthorized"
        )
        == 1.0
    )


def test_tenant_mismatch_is_counted_under_the_resolved_tenant_not_the_claimed_one(client):
    # The API key resolves to "demo"; the body claims a different tenant_id. The counter must
    # use the authenticated tenant -- counting a mismatch under an attacker-claimed tenant would
    # let anyone pollute another tenant's cost series just by naming it in a request body.
    client.post("/v1/chat", content=chat_body(tenant_id="someone-else"), headers=_json_headers())
    text = client.get("/metrics").text
    assert (
        _metric_value(
            text, "ai_gateway_requests_total", tenant_id=DEMO_TENANT, outcome="tenant_mismatch"
        )
        == 1.0
    )


def test_a_successful_proxy_is_counted_as_proxied_regardless_of_upstream_status(build_client):
    test_client, _ = build_client(handler=error_chat_handler(422, code="invalid_request"))
    with test_client as tc:
        tc.post("/v1/chat", content=chat_body(), headers=_json_headers())
        text = tc.get("/metrics").text
    # "proxied" means the gateway genuinely forwarded the call and got a response of some kind
    # back -- ai_service's own 422 is still a successfully *proxied* request from the gateway's
    # point of view; ai_service's own ai_requests_total is what would reflect ai_service's side.
    assert (
        _metric_value(text, "ai_gateway_requests_total", tenant_id=DEMO_TENANT, outcome="proxied")
        == 1.0
    )


def test_upstream_unreachable_and_timeout_get_their_own_outcomes(build_client):
    unreachable_client, _ = build_client(handler=unreachable_handler())
    with unreachable_client as tc:
        tc.post("/v1/chat", content=chat_body(), headers=_json_headers())
        text = tc.get("/metrics").text
    assert (
        _metric_value(
            text, "ai_gateway_requests_total", tenant_id=DEMO_TENANT, outcome="upstream_unreachable"
        )
        == 1.0
    )

    timeout_client, _ = build_client(handler=timeout_handler())
    with timeout_client as tc:
        tc.post("/v1/chat", content=chat_body(), headers=_json_headers())
        text = tc.get("/metrics").text
    assert (
        _metric_value(
            text, "ai_gateway_requests_total", tenant_id=DEMO_TENANT, outcome="upstream_timeout"
        )
        == 1.0
    )


def test_rate_limited_and_quota_exceeded_get_their_own_outcomes(build_client):
    rate_limited_settings = Settings(
        rate_limit_per_minute=60, rate_limit_burst=1, quota_per_day=1000
    )
    test_client, _ = build_client(settings=rate_limited_settings)
    with test_client as tc:
        tc.post("/v1/chat", content=chat_body(), headers=_json_headers())
        tc.post("/v1/chat", content=chat_body(), headers=_json_headers())
        text = tc.get("/metrics").text
    assert (
        _metric_value(text, "ai_gateway_requests_total", tenant_id=DEMO_TENANT, outcome="proxied")
        == 1.0
    )
    assert (
        _metric_value(
            text, "ai_gateway_requests_total", tenant_id=DEMO_TENANT, outcome="rate_limited"
        )
        == 1.0
    )

    quota_settings = Settings(
        rate_limit_per_minute=100_000, rate_limit_burst=100_000, quota_per_day=1
    )
    quota_client, _ = build_client(settings=quota_settings)
    with quota_client as tc:
        tc.post("/v1/chat", content=chat_body(), headers=_json_headers())
        tc.post("/v1/chat", content=chat_body(), headers=_json_headers())
        text = tc.get("/metrics").text
    assert (
        _metric_value(
            text, "ai_gateway_requests_total", tenant_id=DEMO_TENANT, outcome="quota_exceeded"
        )
        == 1.0
    )


def test_requests_from_different_tenants_are_kept_as_separate_series(build_client):
    from gateway.auth import ApiKeyStore

    other_key = "sk-acme-0123456789abcdef"
    keys = ApiKeyStore.from_mapping({DEMO_API_KEY: DEMO_TENANT, other_key: "acme-corp"})
    test_client, _ = build_client(keys=keys)
    with test_client as tc:
        tc.post("/v1/chat", content=chat_body(DEMO_TENANT), headers=_json_headers())
        tc.post("/v1/chat", content=chat_body(DEMO_TENANT), headers=_json_headers())
        tc.post(
            "/v1/chat",
            content=chat_body("acme-corp"),
            headers={**auth_headers(other_key), "content-type": "application/json"},
        )
        text = tc.get("/metrics").text
    assert (
        _metric_value(text, "ai_gateway_requests_total", tenant_id=DEMO_TENANT, outcome="proxied")
        == 2.0
    )
    assert (
        _metric_value(text, "ai_gateway_requests_total", tenant_id="acme-corp", outcome="proxied")
        == 1.0
    )


def test_gateway_metrics_are_on_the_same_registry_as_generic_http_metrics(client):
    # Same Phase 9 regression this project already learned the hard way for ai_service: a
    # counter on a different registry than the Instrumentator's would silently never appear in
    # a real Prometheus scrape of this process's one /metrics endpoint.
    client.post("/v1/chat", content=chat_body(), headers=_json_headers())
    text = client.get("/metrics").text
    assert "http_requests_total" in text
    assert "ai_gateway_requests_total" in text


def test_gateway_metrics_are_present_even_with_otel_disabled(client):
    assert client.app.state.settings.otel_enabled is False
    client.post("/v1/chat", content=chat_body(), headers=_json_headers())
    text = client.get("/metrics").text
    assert (
        _metric_value(text, "ai_gateway_requests_total", tenant_id=DEMO_TENANT, outcome="proxied")
        == 1.0
    )
