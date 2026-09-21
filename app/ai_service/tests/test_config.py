import pytest
from pydantic import ValidationError

from ai_service.backends import MockBackend, OpenAICompatBackend, build_backend
from ai_service.config import Settings


def test_defaults_describe_a_quiet_local_mock() -> None:
    settings = Settings()
    assert settings.backend == "mock"
    assert settings.mock_model_name == "mock-1"
    assert settings.mock_latency_ms == 0
    assert settings.mock_failure_rate == 0.0
    assert settings.mock_seed is None
    assert settings.backend_timeout_s == 30.0
    assert settings.log_format == "text"
    assert settings.ready_timeout_s == 2.0
    assert settings.mock_ready is True


def test_values_come_from_environment_variables(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("POLARIS_MOCK_LATENCY_MS", "150")
    monkeypatch.setenv("POLARIS_MOCK_FAILURE_RATE", "0.25")
    monkeypatch.setenv("POLARIS_MOCK_SEED", "42")
    monkeypatch.setenv("POLARIS_LOG_LEVEL", "WARNING")

    settings = Settings()

    assert settings.mock_latency_ms == 150
    assert settings.mock_failure_rate == 0.25
    assert settings.mock_seed == 42
    assert settings.log_level == "WARNING"


def test_container_related_values_come_from_environment_variables(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("POLARIS_LOG_FORMAT", "json")
    monkeypatch.setenv("POLARIS_READY_TIMEOUT_S", "0.5")
    monkeypatch.setenv("POLARIS_MOCK_READY", "false")

    settings = Settings()

    assert settings.log_format == "json"
    assert settings.ready_timeout_s == 0.5
    assert settings.mock_ready is False


def test_unrelated_environment_variables_are_ignored(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("POLARIS_SOMETHING_ELSE", "1")
    monkeypatch.setenv("HOME_PROXY", "x")
    Settings()  # must not raise


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("mock_failure_rate", -0.1),
        ("mock_failure_rate", 1.5),
        ("mock_latency_ms", -1),
        ("mock_latency_ms", 60_001),
        ("backend_timeout_s", 0),
        ("backend_timeout_s", 301),
        ("backend", "gpt"),
        ("log_level", "LOUD"),
        ("log_format", "xml"),
        ("ready_timeout_s", 0),
        ("ready_timeout_s", 31),
    ],
)
def test_out_of_range_values_are_rejected(name: str, value: object) -> None:
    with pytest.raises(ValidationError):
        Settings(**{name: value})


def test_openai_backend_requires_a_model() -> None:
    with pytest.raises(ValidationError, match="POLARIS_OPENAI_MODEL"):
        Settings(backend="openai_compat")
    Settings(backend="openai_compat", openai_model="some-model")  # fine


def test_api_key_never_appears_in_repr_or_str() -> None:
    settings = Settings(backend="openai_compat", openai_model="m", openai_api_key="s3cret-key")
    assert "s3cret-key" not in repr(settings)
    assert "s3cret-key" not in str(settings)
    assert settings.openai_api_key is not None
    assert settings.openai_api_key.get_secret_value() == "s3cret-key"


def test_settings_are_immutable() -> None:
    settings = Settings()
    with pytest.raises(ValidationError):
        settings.backend = "openai_compat"  # type: ignore[misc]


def test_build_backend_selects_by_setting() -> None:
    assert isinstance(build_backend(Settings()), MockBackend)
    chosen = build_backend(Settings(backend="openai_compat", openai_model="m"))
    assert isinstance(chosen, OpenAICompatBackend)
