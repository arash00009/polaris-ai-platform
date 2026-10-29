"""The golden dataset: a pure parser/validator (`parse_golden_dataset`) plus a thin file-reading
wrapper (`load_golden_dataset`) -- the same pure-function/IO-wrapper split
`ai_service/governance/__init__.py` uses (ADR-37), for the same reason: every malformed-input
path is unit-testable with a plain string, no real file needed.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


class GoldenDatasetError(Exception):
    """The golden dataset file is missing, malformed, or fails validation."""


@dataclass(frozen=True, slots=True)
class GoldenItem:
    id: str
    category: str
    prompt: str
    expected_keywords: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class GoldenDataset:
    schema_version: int
    items: tuple[GoldenItem, ...]


def parse_golden_dataset(dataset_text: str) -> GoldenDataset:
    """Parse and validate golden_dataset.json's content. Raises GoldenDatasetError on any
    malformed or incomplete input -- never returns a partially-valid dataset."""
    try:
        raw = json.loads(dataset_text)
    except json.JSONDecodeError as exc:
        raise GoldenDatasetError(f"golden dataset is not valid JSON: {exc}") from exc

    if not isinstance(raw, dict):
        raise GoldenDatasetError("golden dataset must be a JSON object")

    if "schema_version" not in raw:
        raise GoldenDatasetError("golden dataset is missing required field: schema_version")
    schema_version = raw["schema_version"]
    if not isinstance(schema_version, int):
        raise GoldenDatasetError("golden dataset's schema_version must be an integer")

    raw_items = raw.get("items")
    if not isinstance(raw_items, list) or not raw_items:
        raise GoldenDatasetError("golden dataset's items must be a non-empty list")

    items: list[GoldenItem] = []
    seen_ids: set[str] = set()
    for index, raw_item in enumerate(raw_items):
        if not isinstance(raw_item, dict):
            raise GoldenDatasetError(f"items[{index}] must be an object")

        for field in ("id", "category", "prompt", "expected_keywords"):
            if field not in raw_item:
                raise GoldenDatasetError(f"items[{index}] is missing required field: {field}")

        item_id = raw_item["id"]
        if not isinstance(item_id, str) or not item_id:
            raise GoldenDatasetError(f"items[{index}]'s id must be a non-empty string")
        if item_id in seen_ids:
            raise GoldenDatasetError(f"duplicate golden dataset item id: {item_id!r}")
        seen_ids.add(item_id)

        category = raw_item["category"]
        if not isinstance(category, str) or not category:
            raise GoldenDatasetError(f"items[{index}] ({item_id})'s category must be non-empty")

        prompt = raw_item["prompt"]
        if not isinstance(prompt, str) or not prompt.strip():
            raise GoldenDatasetError(f"items[{index}] ({item_id})'s prompt must be non-empty")

        expected_keywords = raw_item["expected_keywords"]
        if (
            not isinstance(expected_keywords, list)
            or not expected_keywords
            or not all(isinstance(kw, str) and kw for kw in expected_keywords)
        ):
            raise GoldenDatasetError(
                f"items[{index}] ({item_id})'s expected_keywords must be a non-empty list of "
                "non-empty strings"
            )

        items.append(
            GoldenItem(
                id=item_id,
                category=category,
                prompt=prompt,
                expected_keywords=tuple(expected_keywords),
            )
        )

    return GoldenDataset(schema_version=schema_version, items=tuple(items))


def load_golden_dataset(path: Path | str) -> GoldenDataset:
    """Read and parse a golden dataset file from disk."""
    text = Path(path).read_text(encoding="utf-8")
    return parse_golden_dataset(text)
