"""Phase 13 (FinOps): the three cost-attribution counters exposed on GET /metrics alongside
prometheus-fastapi-instrumentator's generic HTTP ones -- ai_requests_total, ai_tokens_total,
ai_inference_seconds_total. See ai_service/telemetry.py's module docstring for exactly what each
one means, why these three labels, and why they are cardinality-safe.

Every test here reads the real exposition format off GET /metrics, the same way Prometheus
itself would scrape it -- not the in-memory Counter objects directly -- so a labelling mistake
that would also break a real scrape cannot hide behind calling .labels() correctly in the test.
"""

import re

import pytest
from fastapi.testclient import TestClient

from ai_service.backends import BackendError, BackendTimeout
from ai_service.config import Settings
from ai_service.main import create_app
from tests.fakes import FakeBackend

VALID = {"tenant_id": "demo", "prompt": "Explain Kubernetes pods"}


def _metric_value(text: str, name: str, **labels: str) -> float | None:
    """Pulls one sample's value out of a raw /metrics scrape, or None if it is not present at
    all -- a counter with no observations yet is simply absent from the exposition, never a
    zero-valued line, which is itself worth being able to assert on (see the "not double-counted"
    tests below).
    """
    label_str = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
    pattern = rf"^{re.escape(name)}\{{{re.escape(label_str)}\}} ([0-9.e+-]+)$"
    for line in text.splitlines():
        match = re.match(pattern, line)
        if match:
            return float(match.group(1))
    return None


def test_a_successful_chat_records_all_three_counters(client: TestClient) -> None:
    response = client.post("/v1/chat", json=VALID)
    assert response.status_code == 200
    body = response.json()

    text = client.get("/metrics").text
    assert (
        _metric_value(
            text, "ai_requests_total", tenant_id="demo", model="mock-1", outcome="success"
        )
        == 1.0
    )
    # MockBackend always reports both counts, so both "kind" series exist after one call.
    assert _metric_value(
        text, "ai_tokens_total", tenant_id="demo", model="mock-1", kind="prompt"
    ) == pytest.approx(_estimate_tokens(VALID["prompt"]))
    assert (
        _metric_value(text, "ai_tokens_total", tenant_id="demo", model="mock-1", kind="completion")
        is not None
    )
    seconds = _metric_value(text, "ai_inference_seconds_total", tenant_id="demo", model="mock-1")
    assert seconds is not None
    # latency_ms in the response body, converted to seconds, is exactly what was added.
    assert seconds == pytest.approx(body["latency_ms"] / 1000.0)


def _estimate_tokens(prompt: str) -> int:
    return len(prompt.split())


def test_requests_from_different_tenants_are_kept_as_separate_series(client: TestClient) -> None:
    client.post("/v1/chat", json={"tenant_id": "acme", "prompt": "hello"})
    client.post("/v1/chat", json={"tenant_id": "acme", "prompt": "hello again"})
    client.post("/v1/chat", json={"tenant_id": "widgets", "prompt": "hello"})

    text = client.get("/metrics").text
    assert (
        _metric_value(
            text, "ai_requests_total", tenant_id="acme", model="mock-1", outcome="success"
        )
        == 2.0
    )
    assert (
        _metric_value(
            text, "ai_requests_total", tenant_id="widgets", model="mock-1", outcome="success"
        )
        == 1.0
    )


def test_backend_timeout_is_counted_with_model_unknown_and_never_counted_as_tokens_or_seconds(
    client: TestClient,
) -> None:
    with TestClient(
        create_app(Settings(), backend=FakeBackend(error=BackendTimeout("slow")))
    ) as timeout_client:
        response = timeout_client.post("/v1/chat", json=VALID)
        assert response.status_code == 504

        text = timeout_client.get("/metrics").text
        assert (
            _metric_value(
                text,
                "ai_requests_total",
                tenant_id="demo",
                model="unknown",
                outcome="backend_timeout",
            )
            == 1.0
        )
        # A failed call never had a GenerateResult, so it must never appear in these two.
        assert (
            _metric_value(text, "ai_tokens_total", tenant_id="demo", model="unknown", kind="prompt")
            is None
        )
        assert (
            _metric_value(text, "ai_inference_seconds_total", tenant_id="demo", model="unknown")
            is None
        )


def test_backend_error_is_counted_with_its_own_outcome(client: TestClient) -> None:
    with TestClient(
        create_app(Settings(), backend=FakeBackend(error=BackendError("boom")))
    ) as error_client:
        response = error_client.post("/v1/chat", json=VALID)
        assert response.status_code == 502

        text = error_client.get("/metrics").text
        assert (
            _metric_value(
                text,
                "ai_requests_total",
                tenant_id="demo",
                model="unknown",
                outcome="backend_error",
            )
            == 1.0
        )


def test_a_backend_that_reports_no_token_counts_is_simply_absent_from_ai_tokens_total() -> None:
    # Same "not every backend reports token counts" case test_chat_api.py's own
    # test_backend_result_defaults_allow_missing_token_counts already covers for the span
    # attributes -- this is the FinOps-counter equivalent of that same gap.
    from ai_service.backends import BackendResult

    class _NoCounts(FakeBackend):
        async def generate(self, prompt: str) -> BackendResult:
            return BackendResult(text="ok", model="no-counts-1")

    with TestClient(create_app(Settings(), backend=_NoCounts())) as no_counts_client:
        response = no_counts_client.post("/v1/chat", json=VALID)
        assert response.status_code == 200

        text = no_counts_client.get("/metrics").text
        assert (
            _metric_value(
                text, "ai_requests_total", tenant_id="demo", model="no-counts-1", outcome="success"
            )
            == 1.0
        )
        assert (
            _metric_value(
                text, "ai_tokens_total", tenant_id="demo", model="no-counts-1", kind="prompt"
            )
            is None
        )
        assert (
            _metric_value(
                text, "ai_tokens_total", tenant_id="demo", model="no-counts-1", kind="completion"
            )
            is None
        )
        # Inference seconds is the handler's own measured wall clock, never backend-reported --
        # it is recorded on every success regardless of what the backend itself returns.
        assert (
            _metric_value(text, "ai_inference_seconds_total", tenant_id="demo", model="no-counts-1")
            is not None
        )


def test_repeated_requests_accumulate_rather_than_overwrite(client: TestClient) -> None:
    client.post("/v1/chat", json=VALID)
    client.post("/v1/chat", json=VALID)
    client.post("/v1/chat", json=VALID)

    text = client.get("/metrics").text
    assert (
        _metric_value(
            text, "ai_requests_total", tenant_id="demo", model="mock-1", outcome="success"
        )
        == 3.0
    )


def test_finops_metrics_are_on_the_same_registry_as_generic_http_metrics(
    client: TestClient,
) -> None:
    # Regression guard for the exact per-app-registry bug this module's docstring documents
    # (Phase 9): if the FinOps counters were ever registered on a different registry than the
    # Instrumentator's, they would silently vanish from a real Prometheus scrape even though
    # this test's own client.get("/metrics") call would still see them (TestClient always talks
    # to the one app instance it was built with). Asserting both families of metric are present
    # in the SAME response is what a real scrape would also see.
    client.post("/v1/chat", json=VALID)
    text = client.get("/metrics").text
    assert "http_requests_total" in text
    assert "ai_requests_total" in text


def test_finops_metrics_are_present_even_with_otel_disabled(client: TestClient) -> None:
    # The default: POLARIS_OTEL_ENABLED=false. Metrics, like /metrics itself, are never gated on
    # that flag -- only tracing/logging are opt-in (see telemetry.py's module docstring).
    assert client.app.state.settings.otel_enabled is False
    client.post("/v1/chat", json=VALID)
    text = client.get("/metrics").text
    assert (
        _metric_value(
            text, "ai_requests_total", tenant_id="demo", model="mock-1", outcome="success"
        )
        == 1.0
    )
