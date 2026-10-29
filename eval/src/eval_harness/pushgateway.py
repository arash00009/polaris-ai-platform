"""Pushes a run's scores to a Prometheus Pushgateway (ADR-38) as `polaris_eval_score`, one
series for the overall mean (category="overall") and one per golden-dataset category. A fresh
push replaces the previous one for the same `job`/`backend` grouping key -- a Pushgateway holds
the *last* pushed value for a grouping key until it is pushed again or deleted, which is exactly
"the current eval score for this backend," not an accumulating history (docs/ai-evaluation.md
§4 covers what this does and does not give you; a history belongs in the pushed-and-scraped
Prometheus time series instead, once this is scraped at all).
"""

from __future__ import annotations

from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

from eval_harness.runner import EvalRunResult, scores_by_category

METRIC_NAME = "polaris_eval_score"
JOB_NAME = "polaris_eval"


def push_eval_metrics(pushgateway_url: str, result: EvalRunResult) -> None:
    registry = CollectorRegistry()
    gauge = Gauge(
        METRIC_NAME,
        "Mean keyword-presence score (0-1) from the Phase 17 golden-dataset eval harness "
        "(ADR-38). category='overall' is the mean across every item; other values are the "
        "mean within one golden-dataset category.",
        ["backend", "model_version", "prompt_version", "category"],
        registry=registry,
    )
    gauge.labels(
        backend=result.backend,
        model_version=result.model_version,
        prompt_version=result.prompt_version,
        category="overall",
    ).set(result.mean_score)
    for category, score in scores_by_category(result.items).items():
        gauge.labels(
            backend=result.backend,
            model_version=result.model_version,
            prompt_version=result.prompt_version,
            category=category,
        ).set(score)

    push_to_gateway(
        pushgateway_url, job=JOB_NAME, registry=registry, grouping_key={"backend": result.backend}
    )
