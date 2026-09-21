"""Log format, the field allow-list, log-injection safety and the per-request access line."""

import json
import logging
import sys
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from ai_service.backends import BackendError
from ai_service.config import Settings
from ai_service.logging_setup import JsonFormatter, TextFormatter, configure_logging
from ai_service.main import create_app
from tests.fakes import FakeBackend

VALID = {"tenant_id": "demo", "prompt": "Explain Kubernetes pods"}


@pytest.fixture(autouse=True)
def _restore_root_logger() -> Iterator[None]:
    """configure_logging changes the root logger; put it back so other tests are unaffected."""
    root = logging.getLogger()
    handlers, level = list(root.handlers), root.level
    yield
    root.handlers[:] = handlers
    root.setLevel(level)


def _record(message: str = "hello", **extra: object) -> logging.LogRecord:
    record = logging.LogRecord("ai_service", logging.INFO, __file__, 1, message, None, None)
    for key, value in extra.items():
        setattr(record, key, value)
    return record


def _lines(capsys: pytest.CaptureFixture[str]) -> list[str]:
    return [line for line in capsys.readouterr().out.splitlines() if line.strip()]


# ---- formatters ------------------------------------------------------------------------


def test_json_formatter_writes_one_parseable_object_with_the_known_fields() -> None:
    line = JsonFormatter().format(_record("chat completed", request_id="r1", latency_ms=1.5))

    data = json.loads(line)
    assert "\n" not in line
    assert data["message"] == "chat completed"
    assert data["level"] == "INFO"
    assert data["logger"] == "ai_service"
    assert data["service"] == "ai-service"
    assert data["request_id"] == "r1"
    assert data["latency_ms"] == 1.5
    assert data["ts"].endswith("+00:00")


@pytest.mark.parametrize("formatter", [JsonFormatter(), TextFormatter()])
def test_fields_outside_the_allow_list_are_never_written(
    formatter: logging.Formatter,
) -> None:
    # Defence in depth for "prompts are never logged": even a careless extra={"prompt": ...}
    # does not reach the output.
    line = formatter.format(_record(prompt="my confidential prompt", api_key="s3cret"))
    assert "confidential" not in line
    assert "s3cret" not in line


def test_json_formatter_includes_an_exception_as_a_string() -> None:
    try:
        raise RuntimeError("boom")
    except RuntimeError:
        record = logging.LogRecord(
            "ai_service",
            logging.ERROR,
            __file__,
            1,
            "unhandled error",
            None,
            exc_info=sys.exc_info(),
        )
    data = json.loads(JsonFormatter().format(record))
    assert "RuntimeError: boom" in data["exception"]


def test_text_formatter_appends_key_value_pairs() -> None:
    line = TextFormatter().format(_record("chat completed", request_id="r1", status=200))
    assert line.endswith("chat completed request_id=r1 status=200")


def test_text_formatter_renders_none_and_non_scalar_values_on_one_line() -> None:
    line = TextFormatter().format(_record("x", prompt_tokens=None, reason=["a", "b\nc"]))
    assert "\n" not in line
    assert "prompt_tokens=None" in line
    assert 'reason="' in line  # non-scalar values are quoted, so they stay on one line


def test_text_formatter_quotes_values_that_could_forge_a_log_line() -> None:
    line = TextFormatter().format(_record("http request", path="/a\nINFO ai_service forged=1"))
    assert "\n" not in line
    assert 'path="/a\\nINFO ai_service forged=1"' in line


# ---- configure_logging -----------------------------------------------------------------


def test_configure_logging_replaces_its_own_handler_instead_of_stacking(
    capsys: pytest.CaptureFixture[str],
) -> None:
    configure_logging("INFO", "json")
    configure_logging("INFO", "json")

    logging.getLogger("ai_service").info("once")

    assert len([line for line in _lines(capsys) if '"once"' in line]) == 1


def test_configure_logging_takes_over_uvicorns_loggers() -> None:
    uvicorn_error = logging.getLogger("uvicorn.error")
    uvicorn_error.addHandler(logging.NullHandler())
    uvicorn_error.propagate = False

    configure_logging("INFO", "text")

    assert uvicorn_error.handlers == []
    assert uvicorn_error.propagate is True


# ---- the running app -------------------------------------------------------------------


def test_json_format_end_to_end_every_line_parses_and_has_no_prompt(
    capsys: pytest.CaptureFixture[str],
) -> None:
    private_prompt = "please summarise my confidential contract"
    with TestClient(create_app(Settings(log_format="json"))) as client:
        client.post(
            "/v1/chat",
            json={"tenant_id": "acme", "prompt": private_prompt},
            headers={"x-request-id": "trace-7"},
        )

    output = capsys.readouterr().out
    assert private_prompt not in output
    records = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    by_message = {
        record["message"]: record for record in records if record["logger"].startswith("ai_service")
    }
    assert by_message["chat completed"]["request_id"] == "trace-7"
    assert by_message["chat completed"]["tenant_id"] == "acme"
    assert by_message["chat completed"]["model"] == "mock-1"


def test_the_access_line_has_request_id_method_path_status_and_duration(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with TestClient(create_app(Settings(log_format="json"))) as client:
        client.post("/v1/chat", json=VALID, headers={"x-request-id": "trace-8"})

    access = [
        json.loads(line)
        for line in capsys.readouterr().out.splitlines()
        if line.startswith("{") and '"ai_service.access"' in line
    ]
    assert len(access) == 1
    assert access[0]["request_id"] == "trace-8"
    assert access[0]["method"] == "POST"
    assert access[0]["path"] == "/v1/chat"
    assert access[0]["status"] == 200
    assert access[0]["duration_ms"] >= 0


def test_the_access_line_never_contains_the_query_string(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with TestClient(create_app(Settings(log_format="json"))) as client:
        client.get("/nothing-here?token=hunter2&email=a@b.se")

    # Only the service's own loggers count: the test client library logs the full URL itself.
    ours = [
        line
        for line in capsys.readouterr().out.splitlines()
        if line.startswith("{") and json.loads(line)["logger"].startswith("ai_service")
    ]
    assert ours
    assert not any("hunter2" in line or "a@b.se" in line for line in ours)
    access = json.loads(next(line for line in ours if '"ai_service.access"' in line))
    assert access["path"] == "/nothing-here"
    assert access["status"] == 404


def test_a_forged_path_cannot_create_a_second_log_line_in_text_format(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with TestClient(create_app(Settings(log_format="text"))) as client:
        client.get("/x%0AINFO%20ai_service%20forged=1")

    access_lines = [line for line in _lines(capsys) if "http request" in line]
    assert len(access_lines) == 1
    assert not any(line.startswith("INFO") for line in _lines(capsys))


def test_probe_requests_are_not_in_the_info_access_log(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with TestClient(create_app(Settings(log_format="json"))) as client:
        client.get("/healthz")
        client.get("/readyz")

    assert '"path": "/healthz"' not in capsys.readouterr().out


def test_probe_requests_are_logged_at_debug_level(capsys: pytest.CaptureFixture[str]) -> None:
    with TestClient(create_app(Settings(log_format="json", log_level="DEBUG"))) as client:
        client.get("/healthz")

    assert '"path": "/healthz"' in capsys.readouterr().out


def test_a_failing_readiness_check_is_logged_as_a_warning_with_the_reason(
    capsys: pytest.CaptureFixture[str],
) -> None:
    backend = FakeBackend(ready_error=BackendError("model backend unreachable"))
    with TestClient(create_app(Settings(log_format="json"), backend=backend)) as client:
        client.get("/readyz")

    warning = next(
        json.loads(line)
        for line in capsys.readouterr().out.splitlines()
        if "readiness check failed" in line
    )
    assert warning["level"] == "WARNING"
    assert warning["code"] == "not_ready"
    assert warning["reason"] == "model backend unreachable"


def test_an_unhandled_error_is_logged_with_a_traceback_and_a_500_access_line(
    capsys: pytest.CaptureFixture[str],
) -> None:
    backend = FakeBackend(error=RuntimeError("boom"))
    with TestClient(
        create_app(Settings(log_format="json"), backend=backend), raise_server_exceptions=False
    ) as client:
        response = client.post("/v1/chat", json=VALID)

    assert response.status_code == 500
    records = [
        json.loads(line) for line in capsys.readouterr().out.splitlines() if line.startswith("{")
    ]
    error = next(r for r in records if r["message"] == "unhandled error")
    assert "RuntimeError: boom" in error["exception"]
    access = next(r for r in records if r["logger"] == "ai_service.access")
    assert access["status"] == 500
