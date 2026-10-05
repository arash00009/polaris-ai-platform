import json

import pytest
from pydantic import ValidationError

from gateway.auth import ApiKeyStore
from gateway.config import Settings


def test_default_settings_have_no_keys_configured():
    settings = Settings()
    assert json.loads(settings.api_keys_json.get_secret_value()) == {}


def test_api_keys_json_must_be_valid_json():
    with pytest.raises(ValidationError):
        Settings(api_keys_json="not json")


def test_api_keys_json_must_be_an_object_not_a_list():
    with pytest.raises(ValidationError):
        Settings(api_keys_json=json.dumps(["sk-0123456789abcdef"]))


def test_api_keys_json_rejects_a_too_short_key():
    with pytest.raises(ValidationError):
        Settings(api_keys_json=json.dumps({"short": "demo"}))


def test_api_keys_json_rejects_an_invalid_tenant_id():
    with pytest.raises(ValidationError):
        Settings(api_keys_json=json.dumps({"sk-0123456789abcdef": "Not Valid!"}))


def test_api_keys_json_accepts_a_well_formed_mapping():
    settings = Settings(api_keys_json=json.dumps({"sk-0123456789abcdef": "demo"}))
    store = ApiKeyStore.from_settings(settings)
    assert store.resolve("sk-0123456789abcdef") == "demo"


def test_settings_repr_never_contains_the_raw_api_keys_json():
    settings = Settings(api_keys_json=json.dumps({"sk-0123456789abcdef": "demo"}))
    assert "sk-0123456789abcdef" not in repr(settings)
    assert "sk-0123456789abcdef" not in str(settings)


def test_openai_compat_style_backend_timeout_defaults_above_phase_11s_90s_dev_setting():
    # Phase 11 raised POLARIS_BACKEND_TIMEOUT_S to 90 in values-dev.yaml after a real cold
    # Ollama load measured ~50.5s (ADR-29). This gateway's own upstream_timeout_s must default
    # to at least that, or the gateway would time out while ai_service is still legitimately
    # waiting on the model -- see config.py's own comment.
    assert Settings().upstream_timeout_s >= 90.0
