import json
from pathlib import Path

import pytest

from eval_harness import cli as cli_module
from eval_harness.client import ServiceClientError

VALID_DATASET = json.dumps(
    {
        "schema_version": 1,
        "items": [
            {
                "id": "a",
                "category": "cat-a",
                "prompt": "What is A?",
                "expected_keywords": ["foo"],
            }
        ],
    }
)


class FakeServiceClient:
    def __init__(self, base_url: str, *, timeout_s: float = 30.0) -> None:
        self.base_url = base_url
        self.closed = False

    def get_meta(self) -> dict:
        return {"model_version": "mock-1", "prompt_version": "v1"}

    def chat(self, prompt: str) -> str:
        return "foo is here"

    def close(self) -> None:
        self.closed = True


class RaisingServiceClient(FakeServiceClient):
    def get_meta(self) -> dict:
        raise ServiceClientError("unreachable")


@pytest.fixture
def dataset_path(tmp_path: Path) -> str:
    path = tmp_path / "golden_dataset.json"
    path.write_text(VALID_DATASET)
    return str(path)


def test_main_runs_successfully_and_prints_a_report(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture, dataset_path: str
) -> None:
    monkeypatch.setattr(cli_module, "ServiceClient", FakeServiceClient)

    exit_code = cli_module.main(
        ["--base-url", "http://ai-service.test", "--backend", "mock", "--dataset", dataset_path]
    )

    assert exit_code == 0
    report = json.loads(capsys.readouterr().out)
    assert report["backend"] == "mock"
    assert report["model_version"] == "mock-1"
    assert report["mean_score"] == 1.0


def test_main_returns_2_for_a_missing_dataset_file(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture, tmp_path: Path
) -> None:
    monkeypatch.setattr(cli_module, "ServiceClient", FakeServiceClient)

    exit_code = cli_module.main(
        [
            "--base-url",
            "http://ai-service.test",
            "--backend",
            "mock",
            "--dataset",
            str(tmp_path / "missing.json"),
        ]
    )

    assert exit_code == 2
    assert "error" in capsys.readouterr().err


def test_main_returns_2_when_the_service_is_unreachable(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture, dataset_path: str
) -> None:
    monkeypatch.setattr(cli_module, "ServiceClient", RaisingServiceClient)

    exit_code = cli_module.main(
        ["--base-url", "http://ai-service.test", "--backend", "mock", "--dataset", dataset_path]
    )

    assert exit_code == 2
    assert "unreachable" in capsys.readouterr().err


def test_main_returns_1_when_the_mean_score_is_below_min_score(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture, dataset_path: str
) -> None:
    monkeypatch.setattr(cli_module, "ServiceClient", FakeServiceClient)

    exit_code = cli_module.main(
        [
            "--base-url",
            "http://ai-service.test",
            "--backend",
            "mock",
            "--dataset",
            dataset_path,
            "--min-score",
            "1.5",
        ]
    )

    assert exit_code == 1
    assert "below --min-score" in capsys.readouterr().err


def test_main_pushes_to_the_gateway_when_a_url_is_given(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture, dataset_path: str
) -> None:
    monkeypatch.setattr(cli_module, "ServiceClient", FakeServiceClient)
    pushed = {}

    def fake_push(url, result):
        pushed["url"] = url
        pushed["result"] = result

    monkeypatch.setattr(cli_module, "push_eval_metrics", fake_push)

    exit_code = cli_module.main(
        [
            "--base-url",
            "http://ai-service.test",
            "--backend",
            "mock",
            "--dataset",
            dataset_path,
            "--pushgateway-url",
            "http://pushgateway.test:9091",
        ]
    )

    assert exit_code == 0
    assert pushed["url"] == "http://pushgateway.test:9091"
    assert pushed["result"].mean_score == 1.0
    assert "pushed to http://pushgateway.test:9091" in capsys.readouterr().err
