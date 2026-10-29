"""Phase 16 (ADR-37): the governance manifest loader and its fail-fast validation paths."""

import json
import pathlib

import pytest

import ai_service.governance as governance_module
from ai_service.governance import (
    GovernanceInfo,
    GovernanceManifestError,
    _parse_manifest,
    load_governance_info,
)

_GOOD_MANIFEST = {
    "schema_version": 1,
    "prompt": {"version": "v1", "file": "prompts/v1-system.txt"},
    "models": {"mock": "mock-1", "openai_compat": "llama3.2:1b-instruct-q4_K_M"},
}


def _reader(text: str = "Be helpful.") -> object:
    return lambda _name: text


def test_load_governance_info_reads_the_real_packaged_manifest() -> None:
    info = load_governance_info()
    assert info.schema_version == 1
    assert info.prompt_version == "v1"
    assert info.system_prompt  # non-empty, see governance/prompts/v1-system.txt
    assert info.model_versions["mock"] == "mock-1"
    # The one declared model/backend pair tests/static checks assume stays in sync with
    # versions.env's OLLAMA_MODEL (tests/bootstrap/test_static.sh checks that file, not this
    # one -- this only confirms the manifest itself parses and has the entry at all).
    assert "openai_compat" in info.model_versions


def test_declared_model_version_raises_for_an_undeclared_backend() -> None:
    info = GovernanceInfo(
        schema_version=1, prompt_version="v1", system_prompt="hi", model_versions={"mock": "m1"}
    )
    with pytest.raises(GovernanceManifestError, match="no declared model version"):
        info.declared_model_version("openai_compat")


def test_parse_manifest_accepts_a_well_formed_document() -> None:
    info = _parse_manifest(json.dumps(_GOOD_MANIFEST), _reader("Be helpful."))
    assert info == GovernanceInfo(
        schema_version=1,
        prompt_version="v1",
        system_prompt="Be helpful.",
        model_versions={"mock": "mock-1", "openai_compat": "llama3.2:1b-instruct-q4_K_M"},
    )


def test_parse_manifest_ignores_a_leading_underscore_comment_key_in_models() -> None:
    manifest = {**_GOOD_MANIFEST, "models": {**_GOOD_MANIFEST["models"], "_comment": "note"}}
    info = _parse_manifest(json.dumps(manifest), _reader())
    assert "_comment" not in info.model_versions


def test_parse_manifest_strips_surrounding_whitespace_from_the_prompt_file() -> None:
    info = _parse_manifest(json.dumps(_GOOD_MANIFEST), _reader("\n  Be helpful.  \n"))
    assert info.system_prompt == "Be helpful."


@pytest.mark.parametrize("bad_json", ["{not json", "", "[]", "null"])
def test_parse_manifest_rejects_malformed_or_non_object_json(bad_json: str) -> None:
    with pytest.raises(GovernanceManifestError):
        _parse_manifest(bad_json, _reader())


@pytest.mark.parametrize(
    "missing_key",
    ["schema_version", "prompt", "models"],
)
def test_parse_manifest_rejects_a_document_missing_a_required_top_level_field(
    missing_key: str,
) -> None:
    manifest = {k: v for k, v in _GOOD_MANIFEST.items() if k != missing_key}
    with pytest.raises(GovernanceManifestError, match="missing a required field"):
        _parse_manifest(json.dumps(manifest), _reader())


def test_parse_manifest_rejects_a_prompt_object_missing_its_own_fields() -> None:
    manifest = {**_GOOD_MANIFEST, "prompt": {"version": "v1"}}  # no "file"
    with pytest.raises(GovernanceManifestError, match="missing a required field"):
        _parse_manifest(json.dumps(manifest), _reader())


def test_parse_manifest_raises_when_the_named_prompt_file_does_not_exist() -> None:
    def _missing(_name: str) -> str:
        raise FileNotFoundError(_name)

    with pytest.raises(GovernanceManifestError, match="is missing"):
        _parse_manifest(json.dumps(_GOOD_MANIFEST), _missing)


def test_parse_manifest_rejects_an_empty_prompt_file() -> None:
    with pytest.raises(GovernanceManifestError, match="is empty"):
        _parse_manifest(json.dumps(_GOOD_MANIFEST), _reader("   \n  "))


def test_load_governance_info_raises_when_the_packaged_manifest_is_missing(
    monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
) -> None:
    # A real pathlib.Path to an empty directory stands in for importlib.resources.files()'s
    # return value: same joinpath()/read_text() interface, deliberately missing manifest.json,
    # so this exercises load_governance_info()'s own outer try/except without having to delete
    # anything from the actually-installed package.
    monkeypatch.setattr(governance_module.resources, "files", lambda _pkg: tmp_path)
    with pytest.raises(GovernanceManifestError, match="is missing"):
        load_governance_info()
