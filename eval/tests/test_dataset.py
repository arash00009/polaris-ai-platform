import json
from pathlib import Path

import pytest

from eval_harness.dataset import GoldenDatasetError, load_golden_dataset, parse_golden_dataset

VALID = json.dumps(
    {
        "schema_version": 1,
        "items": [
            {
                "id": "a",
                "category": "cat-a",
                "prompt": "What is A?",
                "expected_keywords": ["foo", "bar"],
            }
        ],
    }
)


def test_parses_a_well_formed_document() -> None:
    dataset = parse_golden_dataset(VALID)
    assert dataset.schema_version == 1
    assert len(dataset.items) == 1
    item = dataset.items[0]
    assert item.id == "a"
    assert item.category == "cat-a"
    assert item.prompt == "What is A?"
    assert item.expected_keywords == ("foo", "bar")


def test_the_real_shipped_golden_dataset_parses_and_is_internally_consistent() -> None:
    real_path = Path(__file__).resolve().parent.parent / "golden_dataset.json"
    dataset = load_golden_dataset(real_path)
    assert len(dataset.items) >= 1
    seen_ids = {item.id for item in dataset.items}
    assert len(seen_ids) == len(dataset.items)
    for item in dataset.items:
        assert item.expected_keywords


def test_rejects_malformed_json() -> None:
    with pytest.raises(GoldenDatasetError, match="not valid JSON"):
        parse_golden_dataset("{not json")


def test_rejects_a_non_object_document() -> None:
    with pytest.raises(GoldenDatasetError, match="must be a JSON object"):
        parse_golden_dataset("[1, 2, 3]")


@pytest.mark.parametrize("field", ["schema_version", "items"])
def test_rejects_a_document_missing_a_required_top_level_field(field: str) -> None:
    raw = json.loads(VALID)
    del raw[field]
    with pytest.raises(GoldenDatasetError, match=field):
        parse_golden_dataset(json.dumps(raw))


def test_rejects_a_non_integer_schema_version() -> None:
    raw = json.loads(VALID)
    raw["schema_version"] = "1"
    with pytest.raises(GoldenDatasetError, match="schema_version must be an integer"):
        parse_golden_dataset(json.dumps(raw))


def test_rejects_an_empty_items_list() -> None:
    raw = json.loads(VALID)
    raw["items"] = []
    with pytest.raises(GoldenDatasetError, match="non-empty list"):
        parse_golden_dataset(json.dumps(raw))


def test_rejects_an_item_that_is_not_an_object() -> None:
    raw = json.loads(VALID)
    raw["items"] = ["not an object"]
    with pytest.raises(GoldenDatasetError, match=r"items\[0\] must be an object"):
        parse_golden_dataset(json.dumps(raw))


@pytest.mark.parametrize("field", ["id", "category", "prompt", "expected_keywords"])
def test_rejects_an_item_missing_a_required_field(field: str) -> None:
    raw = json.loads(VALID)
    del raw["items"][0][field]
    with pytest.raises(GoldenDatasetError, match=field):
        parse_golden_dataset(json.dumps(raw))


def test_rejects_a_non_string_id() -> None:
    raw = json.loads(VALID)
    raw["items"][0]["id"] = 123
    with pytest.raises(GoldenDatasetError, match="id must be a non-empty string"):
        parse_golden_dataset(json.dumps(raw))


def test_rejects_a_blank_category() -> None:
    raw = json.loads(VALID)
    raw["items"][0]["category"] = ""
    with pytest.raises(GoldenDatasetError, match="category must be non-empty"):
        parse_golden_dataset(json.dumps(raw))


def test_rejects_duplicate_item_ids() -> None:
    raw = json.loads(VALID)
    raw["items"].append(dict(raw["items"][0]))
    with pytest.raises(GoldenDatasetError, match="duplicate golden dataset item id"):
        parse_golden_dataset(json.dumps(raw))


def test_rejects_a_blank_prompt() -> None:
    raw = json.loads(VALID)
    raw["items"][0]["prompt"] = "   "
    with pytest.raises(GoldenDatasetError, match="prompt must be non-empty"):
        parse_golden_dataset(json.dumps(raw))


def test_rejects_an_empty_expected_keywords_list() -> None:
    raw = json.loads(VALID)
    raw["items"][0]["expected_keywords"] = []
    with pytest.raises(GoldenDatasetError, match="expected_keywords must be a non-empty list"):
        parse_golden_dataset(json.dumps(raw))


def test_rejects_a_non_string_keyword() -> None:
    raw = json.loads(VALID)
    raw["items"][0]["expected_keywords"] = ["ok", 123]
    with pytest.raises(GoldenDatasetError, match="expected_keywords must be a non-empty list"):
        parse_golden_dataset(json.dumps(raw))


def test_load_golden_dataset_raises_when_the_file_is_missing(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_golden_dataset(tmp_path / "does-not-exist.json")
