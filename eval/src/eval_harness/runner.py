"""Runs the golden dataset against a chat function and assembles the results. `evaluate()` and
`build_run_result()` are pure given their callables -- they take a `chat_fn` rather than a real
HTTP client, the same pure-orchestration/thin-IO-wrapper split `ai_service/governance/
__init__.py` uses (ADR-37) -- so the scoring/assembly logic is fully unit-testable with a fake
`chat_fn`, with no live service needed. `cli.py` supplies the real one.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from eval_harness.dataset import GoldenDataset
from eval_harness.scoring import mean_score, missing_keywords, score_item


@dataclass(frozen=True, slots=True)
class ItemResult:
    id: str
    category: str
    prompt: str
    response_text: str
    score: float
    missing_keywords: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class EvalRunResult:
    backend: str
    model_version: str
    prompt_version: str
    items: tuple[ItemResult, ...]
    mean_score: float


def evaluate(dataset: GoldenDataset, chat_fn: Callable[[str], str]) -> tuple[ItemResult, ...]:
    """Run every item in dataset through chat_fn(prompt) -> response_text and score it.
    chat_fn is the only I/O boundary -- a fake chat_fn in tests, cli.py's real one otherwise."""
    results = []
    for item in dataset.items:
        response_text = chat_fn(item.prompt)
        results.append(
            ItemResult(
                id=item.id,
                category=item.category,
                prompt=item.prompt,
                response_text=response_text,
                score=score_item(response_text, item.expected_keywords),
                missing_keywords=missing_keywords(response_text, item.expected_keywords),
            )
        )
    return tuple(results)


def build_run_result(
    *, backend: str, model_version: str, prompt_version: str, items: tuple[ItemResult, ...]
) -> EvalRunResult:
    return EvalRunResult(
        backend=backend,
        model_version=model_version,
        prompt_version=prompt_version,
        items=items,
        mean_score=mean_score([item.score for item in items]),
    )


def scores_by_category(items: tuple[ItemResult, ...]) -> dict[str, float]:
    """Mean score per category (pods/deployments/services/namespaces), for the per-category
    Grafana breakdown -- docs/ai-evaluation.md §3."""
    by_category: dict[str, list[float]] = {}
    for item in items:
        by_category.setdefault(item.category, []).append(item.score)
    return {category: mean_score(scores) for category, scores in by_category.items()}
