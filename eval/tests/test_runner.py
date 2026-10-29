from eval_harness.dataset import GoldenDataset, GoldenItem
from eval_harness.runner import build_run_result, evaluate, scores_by_category

DATASET = GoldenDataset(
    schema_version=1,
    items=(
        GoldenItem(id="a", category="cat-1", prompt="prompt a", expected_keywords=("foo",)),
        GoldenItem(id="b", category="cat-1", prompt="prompt b", expected_keywords=("bar", "baz")),
        GoldenItem(id="c", category="cat-2", prompt="prompt c", expected_keywords=("qux",)),
    ),
)


def test_evaluate_calls_chat_fn_once_per_item_and_scores_each() -> None:
    answers = {"prompt a": "foo is here", "prompt b": "bar only", "prompt c": "nothing relevant"}
    seen_prompts = []

    def chat_fn(prompt: str) -> str:
        seen_prompts.append(prompt)
        return answers[prompt]

    items = evaluate(DATASET, chat_fn)

    assert seen_prompts == ["prompt a", "prompt b", "prompt c"]
    assert [item.id for item in items] == ["a", "b", "c"]
    assert items[0].score == 1.0
    assert items[1].score == 0.5
    assert items[1].missing_keywords == ("baz",)
    assert items[2].score == 0.0


def test_build_run_result_computes_the_mean_across_items() -> None:
    answers = {"prompt a": "foo", "prompt b": "", "prompt c": ""}
    items = evaluate(DATASET, lambda prompt: answers[prompt])
    result = build_run_result(
        backend="mock", model_version="mock-1", prompt_version="v1", items=items
    )
    assert result.backend == "mock"
    assert result.model_version == "mock-1"
    assert result.prompt_version == "v1"
    assert result.mean_score == (1.0 + 0.0 + 0.0) / 3


def test_scores_by_category_groups_and_averages() -> None:
    items = evaluate(
        DATASET, lambda prompt: {"prompt a": "foo", "prompt b": "bar baz", "prompt c": ""}[prompt]
    )
    by_category = scores_by_category(items)
    assert by_category == {"cat-1": 1.0, "cat-2": 0.0}
