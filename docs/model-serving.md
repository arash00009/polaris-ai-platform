# AI model serving

Covers **Phase 11**: a real, local, CPU-only model server (Ollama) in its own `model-serving`
namespace, and `ai_service`'s `OpenAICompatBackend` (built in Phase 2, unit-tested since then
against a fake transport) wired up against it for the first time — currently in `polaris-dev`
only. `docs/architecture.md` section 18's exact "Done when" wording for this phase: *"Ollama
serves a small model; service uses `OpenAICompatBackend`; serving trade-offs documented."*

**Verified state: written and unit-tested in the sandbox (2026-09-29). Not yet installed or run
on the target machine.** `app/ai_service`'s test suite grew from 145 to 151 tests (98.76 %
coverage, ruff clean); the six new tests exercise this phase's one real code change —
`OpenAICompatBackend.check_ready()` now verifies the configured model is actually present in the
backend's `/v1/models` response, not just that the endpoint answers 200 (see 2.2 below). Every
Kubernetes-facing piece of this phase (the `model-serving` namespace, the Ollama Deployment/PVC/
Service/NetworkPolicy, `scripts/bootstrap/model-serving.sh`) is written and its YAML validated for
real (`python3 -c "import yaml..."`, the same syntax check every earlier phase's sandbox-only
Kubernetes work has used), but none of it has run against a real cluster — there is no Docker
daemon and no cluster in this sandbox (confirmed by trying, not assumed; see
`docs/troubleshooting.md`). Installing it, pulling the model, and confirming a real chat request
answers correctly are this phase's target-machine step, the same order every earlier
Kubernetes-touching phase in this project has followed.

## 1. Architecture

```
polaris-dev namespace                    model-serving namespace
┌─────────────────────────┐              ┌──────────────────────────┐
│ ai-service (FastAPI)     │              │ ollama (Deployment, x1)  │
│  OpenAICompatBackend ────┼── HTTP ──────┼─► :11434  /v1/chat/...   │
│  POLARIS_BACKEND=        │  (allowed    │           /v1/models    │
│    openai_compat         │   only from  │  OLLAMA_MODELS=/models  │
└─────────────────────────┘   polaris-dev,│           │              │
                               NetworkPolicy)  ┌───────▼────────┐    │
                                            │  PVC: ollama-models   │
                                            │  (persists the pulled │
                                            │   model across restarts)│
                                            └────────────────────────┘
```

`ollama.model-serving.svc.cluster.local:11434` is the in-cluster DNS name
`deploy/platform/model-serving/service.yaml` creates; `helm/ai-platform/values-dev.yaml`'s
`POLARIS_OPENAI_BASE_URL` points at it directly (`/v1` appended, matching
`OpenAICompatBackend`'s own `base_url` convention). No change was needed to `ai-service`'s own
`NetworkPolicy` — it only ever restricted *ingress* to `ai-service` (Phase 4), never egress, so
its pods could already reach any namespace before this phase. `model-serving`'s own
`NetworkPolicy` is the thing that actually restricts this pairing, in the other direction: it
only allows ingress from `polaris-dev`.

## 2. What changed

### 2.1 The model server (new)

`deploy/platform/model-serving/` — a plain Kubernetes manifest, not a Helm chart (there is no
official Ollama chart, and a single-instance server with one Deployment/Service/PVC/NetworkPolicy
is exactly the case Phase 4 already established this project writes as raw YAML rather than
reaching for Helm to avoid — see that phase's own reasoning, ADR-23).

- **Namespace, `pod-security.kubernetes.io/enforce: baseline`**, not `restricted` — the same
  reasoning as `deploy/platform/observability/namespace.yaml` (Phase 9): "restricted" was only
  put on `polaris-dev/-staging/-prod` after Phase 3 *verified*, on the target machine, that
  `ai-service`'s own image actually runs non-root, capability-dropped, read-only-root-filesystem
  (`make image-check`). Nothing has done the equivalent check against the upstream
  `ollama/ollama` image yet. The Deployment still asks for a non-root UID, dropped Linux
  capabilities and no privilege escalation as best-effort hardening — but whether the upstream
  image actually *starts* under those restrictions is unverified, and a wrong guess under
  `restricted` enforcement would fail the pod outright with an admission error rather than a
  normal, diagnosable `CrashLoopBackOff`. Tightening this once confirmed is a named follow-up
  (ADR-29), not silently skipped.
- **One replica, no `PodDisruptionBudget`.** `docs/architecture.md` section 4.3 is explicit that
  this is a *single shared* Ollama across environments — a RAM-constraint trade-off for a local
  machine, not the production shape (section 6 below). A `minAvailable: 1` budget on a
  one-replica workload would only block every voluntary disruption outright, not smooth one —
  not declared here, a real trade-off named rather than copied blindly from `ai-service`'s own
  Deployment.
- **A `PersistentVolumeClaim` for pulled models** (`pvc.yaml`) — a deliberate exception to this
  project's usual "ephemeral by design" posture (ADR-11; Tempo/Loki run with no persistence at
  all). A several-hundred-MB-to-multi-GB model download is expensive to reproduce and has exactly
  one correct value, unlike a trace or log line — re-pulling it on every pod restart would only
  waste time and bandwidth for no benefit. `scripts/bootstrap/model-serving.sh pull-model` only
  has to run once; a pod restart re-attaches the same volume.
- **`scripts/bootstrap/model-serving.sh`** (`install`/`status`/`pull-model`/`uninstall`, `make
  model-serving-*`) — same shape as `scripts/bootstrap/observability.sh`: apply the namespace,
  the PVC, a `sed`-substituted Deployment (the `__OLLAMA_IMAGE__` placeholder, same pattern as
  Phase 4's `__AI_SERVICE_IMAGE__`), the Service, wait for the rollout, then apply the
  NetworkPolicy last and re-check readiness — the same ordering `scripts/deploy/app.sh` uses and
  for the same reason (Phase 4's `docs/troubleshooting.md` row on kubelet probe traffic and
  `NetworkPolicy`).

### 2.2 `OpenAICompatBackend.check_ready()` is now stricter

Before this phase, `GET /readyz` against the real backend only proved the model server's HTTP
endpoint answered — a mistyped `POLARIS_OPENAI_MODEL`, or a model that was configured but never
actually pulled, would have passed readiness and only surfaced as a 502 on the first real chat
request (the class's own docstring named this gap explicitly since Phase 2). Now `check_ready()`
parses the OpenAI-API-shaped `GET /models` response (`{"data": [{"id": "..."}, ...]}`, what
Ollama and other OpenAI-compatible servers return) and fails readiness if the configured model's
`id` is not in that list, or if the response does not have that shape at all (a malformed-response
`BackendError`, mirroring how `generate()` already handles a malformed chat-completion response).
Six new/changed unit tests in `test_openai_compat_backend.py` cover this against the existing fake
transport: the configured model present (passes), present-but-different model missing
(fails, `BackendError` mentioning "not loaded"), and five shapes of malformed `/models` response
(all fail with "malformed").

### 2.3 `ai_service` configuration (unchanged shape, real values now set)

`POLARIS_BACKEND`, `POLARIS_OPENAI_BASE_URL`, `POLARIS_OPENAI_MODEL` have existed in
`ai_service/config.py` since Phase 2 — this phase is the first time they are set to real,
non-placeholder values, and only in `values-dev.yaml` (section 3 below).

## 3. Installing (target machine)

Cluster must already be up (`make cluster-up`).

```bash
make model-serving-install   # namespace, PVC, Deployment, Service, then NetworkPolicy last
make model-serving-pull      # ollama pull <OLLAMA_MODEL from versions.env> -- once, persists on the PVC
make model-serving-status    # Deployment/pods/PVC/Service, and `ollama list` inside the pod
```

Then roll `polaris-dev` out with `values-dev.yaml`'s new `config.POLARIS_BACKEND: openai_compat`
already in place (`make helm-apply-dev`, or let Argo CD sync it) — **install and pull the model
first**, or `ai-service`'s pods will come up pointed at a model server that either does not exist
yet or has not pulled the model yet, and `GET /readyz` will correctly, honestly report not-ready
(section 2.2 above) until both are done. This is the same "install the dependency namespace
first" ordering hazard Phase 9's `docs/observability.md` documents for
`serviceMonitor.enabled`/`kube-prometheus-stack`, applied here to `model-serving`/Ollama instead.

`make model-serving-uninstall` removes the Deployment/Service/NetworkPolicy/PVC/namespace — the
pulled model is deleted along with the PVC, so a later reinstall needs `make model-serving-pull`
again.

## 4. Serving trade-offs, honestly

| | This project (LOCAL) | Production equivalent |
|---|---|---|
| Engine | Ollama, CPU-only | vLLM, Triton Inference Server, or NVIDIA NIM on GPU node pools |
| Model | `llama3.2:1b-instruct-q4_K_M` (Meta Llama 3.2, 1B parameters, 4-bit quantized, 808 MB) | Whatever size/precision the workload needs — routinely 7B-70B+, fp16/bf16 or a production-grade quantization, on GPU memory rather than host RAM |
| Concurrency | One shared instance across (currently) one environment; Ollama serializes/queues requests on CPU | Batched, GPU-accelerated concurrent inference; horizontal scaling via replica count and/or model sharding |
| Autoscaling | None — a fixed one-replica Deployment | HPA/KEDA on queue depth, latency and GPU utilization, plus a cluster/node autoscaler for GPU node pools (`docs/architecture.md` section 16) |
| Latency | Not yet measured for real (target-machine step). `docs/architecture.md`'s own SLO note: p95 ≤ 5s for Ollama CPU vs ≤ 300ms for the mock — CPU inference is materially slower, and this phase's honest job is to confirm that number for real, not assume it | Single-digit-to-tens-of-milliseconds per token, GPU-dependent |
| GPU telemetry | **Not implemented — there is no GPU on this machine.** Documented only, never faked: DCGM Exporter → Prometheus → Grafana is the real production pattern (NVIDIA's own exporter, scraped the same way `kube-prometheus-stack` already scrapes everything else in this project). `docs/architecture.md` section 8 is explicit that simulated GPU graphs would be dishonest, and none are shown here | NVIDIA DCGM Exporter, Prometheus, Grafana — same stack this project already runs, one more scrape target |
| Model versioning | A single, hand-pinned tag in `versions.env` (`OLLAMA_MODEL`) | A model registry (Phase 16: Git manifest first, MLflow optional) with versioned artifacts, rollback, and A/B or canary rollout of a new model version |
| Serving-engine swap | Configuration only (`POLARIS_BACKEND`, `POLARIS_OPENAI_BASE_URL`, `POLARIS_OPENAI_MODEL`) — the whole point of the `ModelBackend` interface since Phase 2 | Same principle at larger scale: vLLM, Triton and NIM all speak (or can front) an OpenAI-compatible API, so this project's own `OpenAICompatBackend` needs no code change to point at any of them, only different configuration |

**Why Ollama, not vLLM, for this phase (ADR-05, reconfirmed by ADR-29):** CPU-friendly by design
(vLLM's CPU backend exists but is materially less mature and documented than its GPU path),
trivial single-binary model management (`ollama pull`/`ollama list`), and an OpenAI-compatible API
this project already had a tested client for since Phase 2. `docs/architecture.md`'s own
requirement-coverage matrix marks vLLM/Triton/NIM as **Documented**, with a CPU vLLM
demonstration explicitly optional — not attempted in this delivery; the trade-off table above and
this note are that documentation.

**Why this specific model (`llama3.2:1b-instruct-q4_K_M`):** small enough to run inference on a
CPU within this project's stated hardware floor (`docs/architecture.md` tier A2: ≥16 GB RAM,
≥6 CPU cores, no GPU) without starving everything else sharing that machine (the k3d cluster
itself, the observability stack, Argo CD); "instruct" rather than "text" because `/v1/chat` is a
chat/instruct workload, not raw text completion; `q4_K_M` (808 MB) chosen over eleven other 1B
quantizations Ollama's library lists (581 MB q2_K up to 2.5 GB fp16) as a reasonable quality/size
midpoint, not tuned or benchmarked against the alternatives — a real, named simplification, not a
claim that it is provably the best choice for this hardware.

## 5. Configuration (`POLARIS_*`, unchanged keys, real values now)

| Variable | `values-dev.yaml` | Meaning |
|----------|--------------------|---------|
| `POLARIS_BACKEND` | `openai_compat` | Switches `ai_service` from `MockBackend` to `OpenAICompatBackend` |
| `POLARIS_OPENAI_BASE_URL` | `http://ollama.model-serving.svc.cluster.local:11434/v1` | The in-cluster Ollama Service, OpenAI-compatible path |
| `POLARIS_OPENAI_MODEL` | `llama3.2:1b-instruct-q4_K_M` | Must match `versions.env`'s `OLLAMA_MODEL` exactly — `tests/bootstrap/test_static.sh` checks this, and a mismatch now fails `GET /readyz` honestly (section 2.2) instead of only a chat request |
| `POLARIS_OPENAI_API_KEY` | unset | Ollama needs no authentication locally; the field exists (`SecretStr`, never logged) for a hosted OpenAI-compatible service that does |
| `POLARIS_BACKEND_TIMEOUT_S` | unchanged, `30.0` default | Comfortably above the ≤5s CPU-inference SLO target above; not tightened this phase pending a real measured latency |

`values.yaml`'s shared defaults, and `values-staging.yaml`/`values-prod.yaml`, are **unchanged** —
every environment except `polaris-dev` still runs `MockBackend`. Extending this to
staging/prod is future work, the same "prove it in one environment first" pattern Phase 9's OTel
flags and Phase 5's Helm migration itself both already used — not attempted here because doing so
would mean either a second shared Ollama instance (defeating the RAM-saving point of "one shared
instance") or per-environment instances this local machine likely cannot afford three of at once.

## 6. Known limitations, honestly

- **This entire phase is unverified against a real cluster.** There is no Docker daemon and no
  cluster in the sandbox this was written in (confirmed by trying `docker pull hello-world`, not
  assumed). Installing it, pulling the model, and sending a real chat request through it are the
  next real steps — see the HANDOFF section of the Claude Project doc for this phase.
- **The non-root `securityContext` in `deployment.yaml` is unverified.** The upstream
  `ollama/ollama` image was not built with a specific non-root UID in mind the way this project's
  own `ai-service` image was (Phase 3, `make image-check`). If the pod fails to start under it,
  `docs/troubleshooting.md`'s Phase 11 section has the documented fallback.
- **`OLLAMA_IMAGE_TAG` (`0.34.4`) is pinned from a real GitHub releases page, but the exact
  Docker Hub tag spelling is inferred, not directly confirmed** — this sandbox cannot reach
  `hub.docker.com` either (see `versions.env`'s own comment). A "manifest unknown" error on
  install is the signal to re-check and correct it.
- **`ai-service`'s own resource requests/limits are not re-measured for a real backend call.**
  They remain the Phase 3 `docker run` estimate, unrelated to how long an Ollama CPU inference
  actually takes end-to-end through the full request path.
- **Latency is not yet measured for real.** `docs/architecture.md`'s "p95 ≤ 5s for Ollama CPU" is
  a target this phase is meant to confirm, not a number already observed.
- **GPU telemetry is documented only — no GPU exists on this machine, and no simulated GPU data
  is shown anywhere** (`docs/architecture.md` section 8's explicit rule).
- **`polaris-staging`/`polaris-prod` are not wired up to Ollama.** They stay on `MockBackend`
  (section 5 above).

See ADR-29 for the full reasoning behind every default and simplification named above, and
`docs/troubleshooting.md`'s Phase 11 section for what was actually found while building this
(the `check_ready()` gap, mainly) versus what remains an *expected* failure mode until it is
reproduced for real on the target machine.
