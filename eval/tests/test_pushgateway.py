import pytest

from eval_harness import pushgateway as pushgateway_module
from eval_harness.pushgateway import JOB_NAME, METRIC_NAME, push_eval_metrics
from eval_harness.runner import ItemResult, build_run_result


def _result():
    items = (
        ItemResult(
            id="a", category="cat-1", prompt="p", response_text="r", score=1.0, missing_keywords=()
        ),
        ItemResult(
            id="b", category="cat-2", prompt="p", response_text="r", score=0.5, missing_keywords=()
        ),
    )
    return build_run_result(
        backend="mock", model_version="mock-1", prompt_version="v1", items=items
    )


def test_push_eval_metrics_pushes_overall_and_per_category_series(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured = {}

    def fake_push_to_gateway(gateway_url, *, job, registry, grouping_key):
        captured["gateway_url"] = gateway_url
        captured["job"] = job
        captured["grouping_key"] = grouping_key
        # Collect the metric families so the test can assert on real exposition content,
        # not just that *something* was pushed.
        captured["families"] = list(registry.collect())

    monkeypatch.setattr(pushgateway_module, "push_to_gateway", fake_push_to_gateway)

    push_eval_metrics("http://pushgateway.test:9091", _result())

    assert captured["gateway_url"] == "http://pushgateway.test:9091"
    assert captured["job"] == JOB_NAME == "polaris_eval"
    assert captured["grouping_key"] == {"backend": "mock"}

    family = captured["families"][0]
    assert family.name == METRIC_NAME
    samples_by_category = {sample.labels["category"]: sample.value for sample in family.samples}
    assert samples_by_category["overall"] == pytest.approx(0.75)
    assert samples_by_category["cat-1"] == pytest.approx(1.0)
    assert samples_by_category["cat-2"] == pytest.approx(0.5)
    for sample in family.samples:
        assert sample.labels["backend"] == "mock"
        assert sample.labels["model_version"] == "mock-1"
        assert sample.labels["prompt_version"] == "v1"
