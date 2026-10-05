"""Telemetry wiring. The formatting logic itself (span attribute filtering, log attribute
filtering) is byte-for-byte copied from app/ai_service/telemetry.py, already covered there --
see this module's own docstring for why that is not duplicated here. What IS specific to
gateway/telemetry.py, and genuinely new in this phase, is cross-service trace propagation --
that is what these tests pin down.
"""

from gateway.config import Settings
from tests.conftest import auth_headers, chat_body


def test_otel_disabled_by_default_adds_no_traceparent(build_client):
    test_client, upstream = build_client(settings=Settings(otel_enabled=False))
    with test_client as tc:
        tc.post(
            "/v1/chat",
            content=chat_body(),
            headers={**auth_headers(), "content-type": "application/json"},
        )
    assert "traceparent" not in upstream.requests[0].headers


def test_otel_enabled_propagates_traceparent_to_upstream(build_client):
    # A deliberately unreachable collector endpoint: ai_service/telemetry.py's own docstring
    # (and its Phase 9 handoff) already confirmed this never blocks or fails a request, and
    # the exporters are async (BatchSpanProcessor) -- nothing here waits on them.
    settings = Settings(otel_enabled=True, otel_exporter_otlp_endpoint="http://127.0.0.1:1")
    test_client, upstream = build_client(settings=settings)
    with test_client as tc:
        response = tc.post(
            "/v1/chat",
            content=chat_body(),
            headers={**auth_headers(), "content-type": "application/json"},
        )
    assert response.status_code == 200
    assert len(upstream.requests) == 1
    # HTTPXClientInstrumentor injects this W3C Trace Context header on the outbound call --
    # docs/architecture.md section 7, design decision #3 ("traceparent propagated end to end").
    assert "traceparent" in upstream.requests[0].headers


def test_building_two_otel_enabled_apps_in_one_process_does_not_raise(build_client):
    """HTTPXClientInstrumentor().instrument() is process-global. Building a second app with
    OTel enabled (every test in this file does, in the same pytest process) must not raise or
    leave the first app's closed client wired to the second app's calls -- see main.py's
    lifespan shutdown comment on why uninstrument() is paired with instrument().
    """
    settings = Settings(otel_enabled=True, otel_exporter_otlp_endpoint="http://127.0.0.1:1")
    first_client, first_upstream = build_client(settings=settings)
    with first_client as tc:
        tc.post(
            "/v1/chat",
            content=chat_body(),
            headers={**auth_headers(), "content-type": "application/json"},
        )

    second_client, second_upstream = build_client(settings=settings)
    with second_client as tc:
        tc.post(
            "/v1/chat",
            content=chat_body(),
            headers={**auth_headers(), "content-type": "application/json"},
        )

    assert len(first_upstream.requests) == 1
    assert len(second_upstream.requests) == 1
