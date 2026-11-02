"""Phase 18 (ADR-39): the rollout-gating latency histogram, ai_chat_duration_seconds, exposed on
GET /metrics alongside the Phase 13 FinOps counters. See ai_service/telemetry.py's module
docstring for exactly why this histogram exists (no generic http_request_duration_seconds is
actually produced by this app -- checked directly against the installed library, not assumed)
and why it is labeled only by outcome, observed on every outcome, not just success.

Every test here reads the real exposition format off GET /metrics, the same way Prometheus (and
this phase's own Argo Rollouts AnalysisTemplate) would scrape it.
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
    """Same helper as test_finops_metrics.py -- pulls one sample's value out of a raw /metrics
    scrape, or None if it is not present at all.
    """
    label_str = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
    pattern = rf"^{re.escape(name)}\{{{re.escape(label_str)}\}} ([0-9.e+-]+)$"
    for line in text.splitlines():
        match = re.match(pattern, line)
        if match:
            return float(match.group(1))
    return None


def test_a_successful_chat_records_the_histogram_with_outcome_success(
    client: TestClient,
) -> None:
    response = client.post("/v1/chat", json=VALID)
    assert response.status_code == 200
    body = response.json()

    text = client.get("/metrics").text
    count = _metric_value(text, "ai_chat_duration_seconds_count", outcome="success")
    assert count == 1.0
    total = _metric_value(text, "ai_chat_duration_seconds_sum", outcome="success")
    assert total is not None
    # The same latency_ms the response body and ai_inference_seconds_total already carry.
    assert total == pytest.approx(body["latency_ms"] / 1000.0)
    # The histogram's own +Inf bucket always exists once any observation has happened, and must
    # carry the full count -- the one bucket every real observation falls into no matter how
    # long it took.
    assert _metric_value(
        text, "ai_chat_duration_seconds_bucket", outcome="success", le="+Inf"
    ) == pytest.approx(1.0)


def test_histogram_is_not_labeled_by_tenant_or_model(client: TestClient) -> None:
    """Unlike ai_requests_total, this histogram is deliberately cardinality-bounded to just
    outcome -- two different tenants' calls must land in the SAME series, not separate ones.
    """
    client.post("/v1/chat", json={"tenant_id": "acme", "prompt": "hello"})
    client.post("/v1/chat", json={"tenant_id": "widgets", "prompt": "hello again"})

    text = client.get("/metrics").text
    assert _metric_value(
        text, "ai_chat_duration_seconds_count", outcome="success"
    ) == pytest.approx(2.0)


def test_backend_timeout_is_recorded_with_its_own_outcome() -> None:
    with TestClient(
        create_app(Settings(), backend=FakeBackend(error=BackendTimeout("slow")))
    ) as timeout_client:
        response = timeout_client.post("/v1/chat", json=VALID)
        assert response.status_code == 504

        text = timeout_client.get("/metrics").text
        assert _metric_value(
            text, "ai_chat_duration_seconds_count", outcome="backend_timeout"
        ) == pytest.approx(1.0)
        # A timed-out call must never be folded into the success series.
        assert _metric_value(text, "ai_chat_duration_seconds_count", outcome="success") is None


def test_backend_error_is_recorded_with_its_own_outcome() -> None:
    with TestClient(
        create_app(Settings(), backend=FakeBackend(error=BackendError("boom")))
    ) as error_client:
        response = error_client.post("/v1/chat", json=VALID)
        assert response.status_code == 502

        text = error_client.get("/metrics").text
        assert _metric_value(
            text, "ai_chat_duration_seconds_count", outcome="backend_error"
        ) == pytest.approx(1.0)


def test_buckets_cover_both_the_mock_and_ollama_sli_thresholds(client: TestClient) -> None:
    """docs/architecture.md section 9's SLI table: p95 latency <= 300ms (mock) / <= 5s (Ollama
    CPU). histogram_quantile() can only be as accurate as the bucket boundaries around the
    threshold it is being compared against -- both real thresholds need a bucket boundary at or
    near them, not just somewhere inside the overall range.
    """
    client.post("/v1/chat", json=VALID)
    text = client.get("/metrics").text
    buckets = {
        float(match.group(1))
        for match in re.finditer(
            r'ai_chat_duration_seconds_bucket\{le="([0-9.]+)",outcome="success"\}', text
        )
    }
    assert 0.3 in buckets
    assert 5.0 in buckets
