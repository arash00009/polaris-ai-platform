"""The Phase 16 governance manifest (ADR-37): model/prompt version, as declared, not guessed.

docs/architecture.md section 6 named a "governance record" (Manifest in Git + a /v1/meta
endpoint + a Prometheus info metric) and section A4 explicitly left the choice between MLflow and
a Git-based manifest open until this phase. ADR-37 records that choice: a Git-based manifest,
because this project's own declared bias against adding infrastructure without a concrete,
proven need (ADR-31's OpenCost-over-Kubecost, ADR-33's Sealed-Secrets-over-Vault, and others)
applies here exactly as it did there -- a second persistent service (MLflow's own tracking
server plus a SQLite/Postgres backend) buys nothing this single-model, single-prompt-template
project cannot already get from a few git-tracked files, and "document the production-grade
alternative, build the honest local-scale one" is this project's own established pattern, not a
new one invented for this phase.

``manifest.json`` (packaged alongside this module, loaded from the installed package, not the
repository root -- see ADR-37 for why: the Docker build context for ai_service is scoped to
app/ai_service, so a repository-root governance/ directory would never reach the built image)
is the single declared source of truth for which model version and which prompt-template
version this project calls "governed" for each backend. ``load_governance_info()`` reads it once
at startup (``main.py``'s ``create_app()``) and fails fast and loudly if it is missing or
malformed -- the same "never guess a value, fail closed" discipline ADR-23 already established
for ``ai-gateway``'s tenant-limits JSON, applied here to the model/prompt registry instead.

The declared model version is deliberately compared, on every single request, against what the
backend itself actually reports answering with (``BackendResult.model`` -- see
``main.py``'s ``chat()``): a mismatch is logged as a real "governance drift" warning, not just
decoration. That comparison is the entire point of a model/prompt registry -- it is what lets
you *know* when a model was swapped, a prompt edited, or a quantization re-pulled, without that
change also being reflected here.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass
from importlib import resources


class GovernanceManifestError(Exception):
    """The governance manifest is missing, malformed, or missing an entry this process needs.

    Raised at startup (never mid-request): a bad manifest should fail the deployment loudly,
    the same way a missing POLARIS_OPENAI_MODEL already fails config.py's own startup validator,
    not get silently patched over with a guessed value.
    """


@dataclass(frozen=True, slots=True)
class GovernanceInfo:
    schema_version: int
    prompt_version: str
    system_prompt: str
    model_versions: dict[str, str]

    def declared_model_version(self, backend: str) -> str:
        """The model version this manifest declares as "governed" for ``backend``.

        Raises GovernanceManifestError if the active backend has no entry at all -- e.g. a new
        ModelBackend implementation added without the manifest being updated to match, caught at
        startup rather than silently reporting an empty/wrong governance field forever.
        """
        try:
            return self.model_versions[backend]
        except KeyError as exc:
            raise GovernanceManifestError(
                f"governance manifest has no declared model version for backend={backend!r}"
            ) from exc


def _parse_manifest(manifest_text: str, read_prompt_file: Callable[[str], str]) -> GovernanceInfo:
    """The pure parsing/validation half of load_governance_info() below, split out so its error
    paths (a malformed manifest, a missing field, a missing/empty prompt file) are directly
    unit-testable against arbitrary text -- see test_governance.py -- without needing to
    replace files inside the installed package to exercise them, the same "test the validation
    logic directly, not through the file system" shape config.py's own Settings validators
    already use.
    """
    try:
        manifest = json.loads(manifest_text)
    except json.JSONDecodeError as exc:
        raise GovernanceManifestError(
            "ai_service/governance/manifest.json is not valid JSON"
        ) from exc

    try:
        schema_version = manifest["schema_version"]
        prompt_version = manifest["prompt"]["version"]
        prompt_file = manifest["prompt"]["file"]
        model_versions = dict(manifest["models"])
    except (KeyError, TypeError) as exc:
        raise GovernanceManifestError(
            "ai_service/governance/manifest.json is missing a required field "
            "(schema_version, prompt.version, prompt.file, models)"
        ) from exc
    # The one non-data key the manifest carries (see manifest.json's own top-level comment):
    # never a real backend name, so never a valid governed-model entry.
    model_versions.pop("_comment", None)

    try:
        prompt_text = read_prompt_file(prompt_file).strip()
    except FileNotFoundError as exc:
        raise GovernanceManifestError(
            f"governance prompt file {prompt_file!r} (named by manifest.json) is missing"
        ) from exc
    if not prompt_text:
        raise GovernanceManifestError(f"governance prompt file {prompt_file!r} is empty")

    return GovernanceInfo(
        schema_version=schema_version,
        prompt_version=prompt_version,
        system_prompt=prompt_text,
        model_versions=model_versions,
    )


def load_governance_info() -> GovernanceInfo:
    """Read manifest.json and its referenced prompt file from the installed package.

    Called once per app instance from main.py's create_app() (the same place Settings() and
    build_backend() are constructed) -- never per-request, and deliberately not memoised at
    module scope with functools.lru_cache: tests build many short-lived apps in one process
    (create_app() is called per test), and a process-wide cache would make one test's monkeypatch
    of the packaged manifest leak into every test after it, exactly the kind of cross-test state
    this project's own CollectorRegistry-per-app-instance fix (telemetry.py, Phase 9) already
    avoided once.
    """
    package = resources.files("ai_service.governance")
    try:
        manifest_text = package.joinpath("manifest.json").read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise GovernanceManifestError("ai_service/governance/manifest.json is missing") from exc

    def _read_prompt_file(name: str) -> str:
        return package.joinpath(name).read_text(encoding="utf-8")

    return _parse_manifest(manifest_text, _read_prompt_file)
