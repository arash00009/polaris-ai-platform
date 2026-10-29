"""Pure scoring logic (ADR-38): keyword-presence scoring, not semantic similarity or an
LLM-as-judge -- see ADR-38's Decision for why. Every function here takes plain values and does
no I/O, so every scoring edge case is unit-testable without a live service.
"""

from __future__ import annotations

from collections.abc import Sequence


def score_item(response_text: str, expected_keywords: Sequence[str]) -> float:
    """The fraction of expected_keywords present in response_text as a case-insensitive
    substring. 1.0 means every expected keyword was found; 0.0 means none were."""
    if not expected_keywords:
        # The dataset loader (dataset.py) already rejects an empty expected_keywords list, so
        # this is defence against a caller bypassing that loader, not a real dataset shape.
        raise ValueError("expected_keywords must not be empty")
    lowered_response = response_text.lower()
    present = sum(1 for keyword in expected_keywords if keyword.lower() in lowered_response)
    return present / len(expected_keywords)


def missing_keywords(response_text: str, expected_keywords: Sequence[str]) -> tuple[str, ...]:
    """Which expected_keywords were NOT found -- the human-readable half of score_item's
    result, kept separate so a report can show both the number and the reason."""
    lowered_response = response_text.lower()
    return tuple(kw for kw in expected_keywords if kw.lower() not in lowered_response)


def mean_score(scores: Sequence[float]) -> float:
    """The mean evaluation score across a run -- docs/architecture.md section 9's SLI wording
    verbatim: "mean evaluation score on the golden dataset"."""
    if not scores:
        raise ValueError("scores must not be empty")
    return sum(scores) / len(scores)
