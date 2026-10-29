# AI governance: a declared, git-tracked model/prompt registry

Covers **Phase 16**: every response, log line and trace span from `ai_service` carries the
declared model/prompt version it ran with, alongside the deployment/config version Helm actually
deployed — `docs/architecture.md`'s own "Done when" wording for this phase: *"Every response and
signal carries model/prompt/deployment/config version; registry manifest; MLflow decision
recorded."* See ADR-37 for the full design record, including why a Git-based manifest was chosen
over MLflow.

**Status: confirmed on the target machine (Darya), 2026-10-29.** 183 tests pass in the sandbox,
coverage is 99.32 % (the 95 % gate), `ruff check`/`ruff format --check` are clean. On the real
cluster, after a real image rebuild/push and a GitOps tag bump (see `docs/troubleshooting.md`'s
Phase 16 section for the full sequence and two real gotchas hit along the way), `GET /v1/meta`
and the `ai_service_governance_info` Prometheus metric both showed real, non-`"unset"` values on
a running Pod:

```
$ curl -s localhost:8000/v1/meta
{"model_version":"llama3.2:1b-instruct-q4_K_M","prompt_version":"v1","deployment_version":"0.4.0-4531878b9203","config_version":"0.3.0","environment":"dev"}

$ curl -s localhost:8000/metrics | grep governance_info
ai_service_governance_info{config_version="0.3.0",deployment_version="0.4.0-4531878b9203",model_version="llama3.2:1b-instruct-q4_K_M",prompt_version="v1"} 1.0
```

`deployment_version` matches the exact image tag deployed; `config_version` matches
`Chart.yaml`'s `0.3.0`. See §6 for what this confirmation needed and §4 of
`docs/troubleshooting.md`'s Phase 16 section for the two real pipeline gotchas it surfaced.

## 1. The two things "governed" means here

**Declared** (what this project says it means to run): `ai_service/governance/manifest.json`,
a small, git-tracked file naming, per backend, which model version is "governed" and which
prompt-template version is "governed." Loaded once at startup (`load_governance_info()`); a
missing or malformed manifest, or an active backend with no declared entry, fails the process at
startup rather than silently falling back to a guess.

**Actual** (what genuinely answered): `BackendResult.model` — the model name the backend itself
reports having used (Phase 11), self-reported by Ollama/vLLM's own response body for
`OpenAICompatBackend`, or `MockBackend`'s own configured name.

Every `/v1/chat` response, and every "chat completed"/"chat failed" log line, carries both: the
existing `model` field stays the *actual* self-reported value; the new `model_version` field is
the *declared* one. `main.py`'s `chat()` handler compares them on every single request and logs
a `WARNING`-level "governance drift detected" line when they differ — never raises, since a
mismatch should not turn a successful answer into a failed request, only make the gap visible.
This comparison is the actual point of having a registry at all: it is what lets a model being
swapped, a different quantization being pulled, or a prompt being edited without the manifest
being updated to match, be *caught*, not just recorded after the fact.

## 2. Where each version actually comes from

| Field | Source | Why |
|---|---|---|
| `model_version` | `ai_service/governance/manifest.json`'s `models.<backend>` entry | Declared, git-tracked; `models.openai_compat` is checked by `tests/bootstrap/test_static.sh` to equal `versions.env`'s `OLLAMA_MODEL` — the two cannot silently drift apart |
| `prompt_version` | The same manifest's `prompt.version` | Declared, git-tracked |
| `deployment_version` | `POLARIS_DEPLOYMENT_VERSION`, set by `helm/ai-platform/templates/configmap.yaml` to `.Values.image.tag` | The exact image tag this release actually runs — never `Chart.yaml`'s `appVersion`, which its own comment warns can drift from the real deployed tag |
| `config_version` | `POLARIS_CONFIG_VERSION`, set by the same template to `.Chart.Version` | Reuses `Chart.yaml`'s own "bump on any template/values-shape change" field rather than computing a second number that could drift from it |

Outside Helm (a bare `uvicorn`/`make app-run`, every unit test in this suite),
`deployment_version`/`config_version` both default to the literal string `"unset"` —
`config.py`'s own Settings fields, a clearly-wrong-looking sentinel on purpose, never a
fabricated version string.

## 3. The versioned prompt template is a real system message, not decoration

`ModelBackend.generate()` (`backends/base.py`) gained an optional `system_prompt: str | None =
None` parameter. `main.py`'s `chat()` passes the governance manifest's
`governance.system_prompt` on every call. `OpenAICompatBackend` sends it as a genuine leading
`{"role": "system", ...}` chat message — the OpenAI chat-completions shape Ollama/vLLM already
speak has a dedicated role for exactly this, so the model actually sees it as an instruction
distinct from the user's own prompt, not text concatenated into one blob. `MockBackend` accepts
the parameter (so every real call site stays uniform across backends) but its deterministic,
lookup-based answers do not depend on it — documented in its own module docstring, not silently
ignored.

The prompt text itself lives at `ai_service/governance/prompts/v1-system.txt`, named by the
manifest's `prompt.file` field. Bumping the prompt (a new version string, a new file, the
manifest updated to point at it) is how "prompt version" changes for real, the same way a new
image tag is how `deployment_version` changes for real.

## 4. The governance record's three forms

`docs/architecture.md` section 6 named all three of these explicitly, in Phase 0, before any of
them existed:

1. **`GET /v1/meta`** — a dedicated, unauthenticated, non-tenant-scoped endpoint returning the
   declared `model_version`/`prompt_version`/`deployment_version`/`config_version` plus
   `environment`. Not a probe (`/healthz`/`/readyz`): it answers a question about the
   deployment, not about a request, so it is cheap to call but not expected to be polled every
   few seconds.
2. **The Prometheus info metric** — `ai_service_governance_info`, a `Gauge` fixed at `1` with
   the four version strings as *labels*, the standard "info metric" pattern already used by
   `kube_pod_info`/`node_exporter_build_info` in real Prometheus deployments. Set once at
   startup, never incremented again: one series per running Pod is the entire cardinality cost.
3. **Every `/v1/chat` response body and log line** — see §1/§2 above.

`model_version`/`prompt_version` are also set as OpenTelemetry span attributes
(`SPAN_ATTRIBUTE_ALLOWLIST` reserved both names since Phase 10, three phases before this one, with
a comment reading "never set yet" — this phase is what fills that gap). `deployment_version` is
instead an OTel Resource attribute (set once per process, attached automatically to every
span/log a provider exports, exactly like `deployment.environment` already is) rather than a
per-span one, because it is a per-process fact, not something that could vary request to
request. `config_version` is deliberately not in either curated list: `docs/architecture.md`
section 6's own allow-list was fixed in Phase 0 without it, and a Helm chart's schema version
changes far less often than a deployment does, so tracing it per-request would add a label that
is almost always identical to the last one. It still appears in the response body and `/v1/meta`
either way — this is a scope decision about tracing/logging cardinality, not about hiding the
field.

## 5. Why a Git-based manifest, not MLflow — and what would change that

See ADR-37 for the full reasoning. In short: this project has exactly one model per backend and
one prompt template at a time, so a few git-tracked files already give a model/prompt registry
everything it needs to prove at this scale — a single declared source of truth, versioned by git
history itself, diffable in a pull request, comparable against what actually answered a
request. MLflow would mean a second persistent service (its own tracking server plus a SQLite/
Postgres backend, a new namespace, a new Helm release to operate and keep healthy) for a need
this project does not yet have — the same "every piece of infrastructure needs a proven need"
discipline already applied to choosing OpenCost over Kubecost (ADR-31) and Sealed Secrets over
Vault (ADR-33). This would be worth revisiting the moment a second model or prompt template is
genuinely in play *at once* (A/B testing a prompt, comparing two quantizations side by side), or
once Phase 17 (AI evaluation) needs to join evaluation scores to a specific prompt/model version
— the real forcing function `docs/architecture.md`'s own roadmap already anticipates MLflow for.

## 6. Target-machine verification — confirmed, and what it took

Everything in this phase that is pure Python — the manifest loader's validation, the drift
check, the new response/log/span/metric fields — is fully exercised by the sandbox's own unit
tests, with no cluster needed (unlike Phase 15's Cosign/Kyverno work, which genuinely could not
be proven without a real registry and a real admission webhook). The Helm-chart half — whether
`POLARIS_DEPLOYMENT_VERSION`/`POLARIS_CONFIG_VERSION` actually reach a running Pod's environment
from `.Values.image.tag`/`.Chart.Version`, and whether `GET /v1/meta`/`GET /metrics` on that real
Pod show the real tag/chart-version instead of `"unset"` — needed Darya, since this sandbox has
no `helm` binary and no Docker daemon.

It took more than a plain `helm upgrade`, and the extra steps are a real lesson about this
project's deploy pipeline, not incidental friction: a **config-only** change (this phase's two
new `configmap.yaml` keys) rolls out automatically the moment it's committed, via the
`checksum/config` annotation Phase 7 added — Argo CD's own self-heal picked it up with no manual
step. But the governance **code** itself (the `/v1/meta` route, the manifest loader, the metric)
ships inside the container image, and nothing about a chart/ConfigMap change rebuilds that image.
The first real check against the live Pod returned `/v1/meta`'s `not_found` — the correct,
honest result, since the Pod was still running the previous phase's image. Confirming for real
meant the full pipeline: `make image-build && make image-push`, then
`make gitops-bump-dev ARGS=--push` to move the new tag through GitOps (which also required
rebuilding `ai-gateway` at the same git sha, since this repo's tag-bump script ties both
services' tags to one commit — see `docs/troubleshooting.md`'s Phase 16 section for the exact
error and fix). Once the new image was actually running:

```
$ curl -s localhost:8000/v1/meta
{"model_version":"llama3.2:1b-instruct-q4_K_M","prompt_version":"v1","deployment_version":"0.4.0-4531878b9203","config_version":"0.3.0","environment":"dev"}

$ curl -s localhost:8000/metrics | grep governance_info
ai_service_governance_info{config_version="0.3.0",deployment_version="0.4.0-4531878b9203",model_version="llama3.2:1b-instruct-q4_K_M",prompt_version="v1"} 1.0
```

Real, non-`"unset"` values on both — `deployment_version` matches the exact deployed image tag,
`config_version` matches `Chart.yaml`'s `0.3.0`. This closes the one gap this document and
ADR-37 had both named as not yet done.
