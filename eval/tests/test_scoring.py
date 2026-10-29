import pytest

from eval_harness.scoring import mean_score, missing_keywords, score_item


def test_score_item_is_one_when_every_keyword_is_present() -> None:
    assert score_item("A Pod is the smallest deployable unit.", ["smallest deployable unit"]) == 1.0


def test_score_item_is_zero_when_no_keyword_is_present() -> None:
    assert score_item("something unrelated", ["smallest deployable unit"]) == 0.0


def test_score_item_gives_partial_credit() -> None:
    assert score_item("contains foo only", ["foo", "bar"]) == 0.5


def test_score_item_is_case_insensitive() -> None:
    assert score_item("SMALLEST DEPLOYABLE UNIT", ["smallest deployable unit"]) == 1.0


def test_score_item_rejects_empty_expected_keywords() -> None:
    with pytest.raises(ValueError, match="must not be empty"):
        score_item("anything", [])


def test_missing_keywords_lists_only_the_absent_ones() -> None:
    assert missing_keywords("contains foo only", ["foo", "bar"]) == ("bar",)


def test_missing_keywords_is_empty_when_all_present() -> None:
    assert missing_keywords("foo and bar", ["foo", "bar"]) == ()


def test_mean_score_averages() -> None:
    assert mean_score([1.0, 0.5, 0.0]) == pytest.approx(0.5)


def test_mean_score_rejects_empty_input() -> None:
    with pytest.raises(ValueError, match="must not be empty"):
        mean_score([])
