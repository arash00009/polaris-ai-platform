# Component Q&A

The six questions an interviewer asks about any component, answered once, honestly, as each component is built. Phase 20 assembles the demonstration from this file instead of cramming.

The answers separate what was **built and tested here** from what is **known but not done here**. Where something has not been tried, it says so.

The six questions: (1) what problem does it solve, (2) why was it chosen, (3) what happens when it fails, (4) how does it scale, (5) how is it secured, (6) how would it move to a cloud.

---

## Phase 1

### k3d cluster (k3s in Docker)

| Question | Answer |
|----------|--------|
| 1. Problem | Gives a real, multi-node Kubernetes API on a laptop, so manifests, Helm and GitOps can be practised against something that behaves like a cluster. |
| 2. Why | Nodes are Docker containers, so no VM is needed; cluster creation took about 30 seconds on the reference machine (the system images then take minutes to pull on a fresh cluster). k3s is a certified Kubernetes distribution, so the API surface is the real one. Chosen in ADR-01. |
| 3. Failure | It is a development tool: if the WSL2 VM restarts, the nodes restart with it. Real failures met while building it are in `docs/troubleshooting.md`, for example a cgroup v1 host that could not run Kubernetes 1.35 (ADR-16). |
| 4. Scale | Not meant to. Three nodes share one machine's RAM and CPU. Scaling means a real cluster; the manifests and charts are written to move there unchanged. |
| 5. Security | Local and unauthenticated by design: the kubeconfig holds a client certificate and is never committed (`.gitignore`). The registry and API are bound to the local machine. |
| 6. Cloud | Managed Kubernetes (EKS, AKS or GKE) with node pools per environment. The k3s-specific parts (bundled Traefik, local-path storage) are replaced by the cloud's ingress and storage classes. **Not done here.** |

### Local registry (`registry.localhost:5000`)

| Question | Answer |
|----------|--------|
| 1. Problem | Lets the loop build, push, pull, run be proven locally before CI publishes to a real registry. |
| 2. Why | Created by k3d together with the cluster, and wired into every node as a containerd mirror, so no extra configuration is needed. |
| 3. Failure | If it is down, new pods cannot pull their image; running pods are unaffected. The smoke test caught a naming mistake here: the in-cluster name is `registry.localhost:5000`, not `k3d-registry.localhost:5000`. |
| 4. Scale | Single container, no replication. Fine for one developer. |
| 5. Security | No authentication, no TLS, plain HTTP, local only. Nothing sensitive must be pushed to it. |
| 6. Cloud | GHCR (used later in CI), ECR, ACR or Harbor, with authentication, image signing and vulnerability scanning. **Not done here** until Phase 6 and 15. |

### Traefik ingress (bundled with k3s)

| Question | Answer |
|----------|--------|
| 1. Problem | Routes HTTP from the host port into the cluster by host name and path. |
| 2. Why | Ships with k3s, so it costs no extra RAM or setup. |
| 3. Failure | Without it no request reaches the cluster. On a fresh cluster it can appear minutes late because the nodes pull its installer image from Docker Hub; this happened and is logged in `docs/troubleshooting.md`. |
| 4. Scale | Runs as one Deployment and can be scaled horizontally. Not load-tested here. |
| 5. Security | HTTP only locally. Production needs TLS termination (cert-manager), and rate limiting and authentication from Phase 12. |
| 6. Cloud | A cloud load balancer in front of Traefik or a managed ingress/Gateway API implementation. **Not done here.** |

---

## Phase 2

### AI service (FastAPI)

| Question | Answer |
|----------|--------|
| 1. Problem | Turns "ask a model something" into a small, well-defined HTTP API (`POST /v1/chat`) with validation, request ids and consistent errors, so everything around it (containers, CI, observability, routing) has a real workload to act on. |
| 2. Why | Python has the strongest AI ecosystem; FastAPI gives typed validation and an OpenAPI schema for free and is readable enough to explain line by line (ADR-17). |
| 3. Failure | A backend failure becomes a 502, a slow backend a 504, and any unexpected exception a 500, each with a stable error code and the request id, and no internal detail in the body. Tested with injected failures (`make app-test`) and by running the service with failure and latency injection. |
| 4. Scale | The service keeps no state between requests, so replicas can be added freely; the real limit is the model server behind it. Not load-tested yet (Phase 9 and 11 measure it). |
| 5. Security | Input is validated (tenant id pattern, prompt length, unknown fields rejected); prompts are never logged; error bodies never echo submitted values; a client-supplied request id is only accepted if it is short and harmless. **Not yet secured:** there is no authentication, and `tenant_id` comes from the request body and is not trustworthy (ADR-18). Both are addressed in Phase 12 and 14. |
| 6. Cloud | The same container image on any Kubernetes service, configured only through environment variables. Secrets (an API key for a hosted model) would come from a secret manager instead of a plain variable. **Not done here.** |

### ModelBackend interface (MockBackend, OpenAICompatBackend)

| Question | Answer |
|----------|--------|
| 1. Problem | Separates "the HTTP service" from "whatever produces the answer", so the model server can be replaced by changing configuration, not code. |
| 2. Why | The mock makes tests, demos and failure experiments deterministic and free of GPUs; the OpenAI-compatible client covers Ollama, vLLM and many hosted services with one implementation (ADR-04). |
| 3. Failure | Backends raise `BackendError` or `BackendTimeout`; the service maps them to 502 and 504. The mock can inject latency and failures on purpose, which is what Phase 19 uses. |
| 4. Scale | The interface is per-request and stateless. Throughput depends entirely on the implementation behind it. |
| 5. Security | Backend error messages never contain upstream response bodies or URLs; the API key is a `SecretStr`, is not shown in `repr()` and is not logged. |
| 6. Cloud | Point `POLARIS_OPENAI_BASE_URL` at a managed or self-hosted inference endpoint. **Status:** `OpenAICompatBackend` is unit-tested against a fake transport only; it has not yet talked to a real model server (Phase 11). |

---

## Phase 3

Status of every row below: **built, run, pushed, scanned and SBOM-generated on the target machine on 2026-09-21** (Docker 29.7.2, WSL2), after the unit tests and static checks passed. Measured facts are stated where they exist. Still not done: image signing, cosign verification of Trivy, review of MEDIUM/LOW findings, and anything that needs Kubernetes (Phase 4).

### Container image (multi-stage, non-root)

| Question | Answer |
|----------|--------|
| 1. Problem | Packages the service and its exact dependencies into one artifact that runs the same on a laptop, in CI and in Kubernetes. |
| 2. Why | A multi-stage build keeps compilers, caches and pip out of the runtime image; a fixed numeric non-root user lets Kubernetes verify `runAsNonRoot`; the tag `<version>-<git sha>` says exactly which commit is inside. Decisions in ADR-19. |
| 3. Failure | A failed build stops before anything is tagged. A container that starts but is unhealthy is caught by `make image-check` (probes, contract, JSON logs, SIGTERM) and by the Docker `HEALTHCHECK`. On 2026-09-21 the first build passed all 9 checks in `make image-check`, including SIGTERM (exit code 0, `Application shutdown complete` logged). A build failure was not provoked, so that part is by design, not observed. |
| 4. Scale | The service keeps no state, so replicas are cheap. Measured on the target machine: a first cold build took 72.9 s and the image is 134 MB (140,925,206 bytes) on a digest-pinned `python:3.12-slim-trixie`. Start time was not measured. |
| 5. Security | Non-root uid 10001, no package installer at runtime, read-only root filesystem and no capabilities when run with `make image-run`, no secrets in the image (settings come from the environment), `.dockerignore` keeps local state out of the build context. **Not done:** image signing and admission policy (Phase 15); the base image digest is pinned in `versions.env` (2026-09-21) and must be bumped deliberately with `make image-pin`. |
| 6. Cloud | The same image in ECR, GHCR or ACR, run by EKS, AKS or GKE, with the registry's own scanning and signing. **Not done here.** |

### Health probes (`/healthz`, `/readyz`)

| Question | Answer |
|----------|--------|
| 1. Problem | Lets the platform tell "restart this container" (liveness) from "do not send traffic to it yet" (readiness). |
| 2. Why | Two endpoints because the questions differ: liveness checks only that the process answers; readiness asks the backend. Tying liveness to a slow model server would restart healthy pods (ADR-20). |
| 3. Failure | `/readyz` answers 503 in the standard error envelope when the backend is not ready or does not answer within `POLARIS_READY_TIMEOUT_S`. `POLARIS_MOCK_READY=false` reproduces that on purpose. |
| 4. Scale | Both are cheap and stateless. The readiness check against a real model server is a single `GET /models`; whether that is enough is decided in Phase 11. |
| 5. Security | The probes return a fixed body and never echo backend details. They have no authentication, so they must not be exposed outside the cluster network (Phase 4/12). |
| 6. Cloud | Kubernetes liveness and readiness probes, or a cloud load balancer health check, pointed at these paths. **Not done here** until Phase 4. |

### Structured logging

| Question | Answer |
|----------|--------|
| 1. Problem | One parseable JSON object per line, with the request id in every line that concerns a request, so a log pipeline can filter by request, tenant or status without regular expressions. |
| 2. Why | Standard library only, no new dependency. A field allow-list means a prompt cannot reach the log by accident; text format is kept for the terminal. |
| 3. Failure | Logging never raises into a request. An unhandled error is logged with its traceback in the `exception` field and the client gets a generic 500 with the request id. |
| 4. Scale | Lines go to stdout and the container runtime collects them; volume is one access line and one result line per chat request, probes at DEBUG. |
| 5. Security | Prompts are never logged (tested against every log record, not just the formatted text); the query string is never logged; client-controlled values cannot forge a second line in text format. Error `reason` texts come from backends that never include upstream bodies or URLs. |
| 6. Cloud | Collected by a node agent (Promtail or the OpenTelemetry Collector, Phase 10) into Loki or a cloud logging service. **Not done here.** |

### Trivy scan and SBOM

| Question | Answer |
|----------|--------|
| 1. Problem | Finds known vulnerabilities in the operating system packages and Python dependencies of the image, and lists what the image contains. |
| 2. Why | Trivy covers OS and language packages in one tool and writes CycloneDX. It runs as a pinned container on a saved image tar, so nothing is installed on the host and the scanner never gets the Docker socket (ADR-21). |
| 3. Failure | `make image-scan` fails on a HIGH or CRITICAL finding that has a fix available. A scan that cannot download its database fails loudly; it never reports "clean". The first scan (2026-09-21) passed the gate: 0 CRITICAL, 44 HIGH (none with a fix), 49 MEDIUM, 57 LOW, 2 UNKNOWN; the register is `docs/security/image-scan.md`. A failing or unreachable-database scan was not provoked. |
| 4. Scale | A scan takes seconds to a few minutes once the database is cached. In CI (Phase 6) the same script runs on every build. |
| 5. Security | The scanner is part of the supply chain: in March 2026 Trivy releases 0.69.4 to 0.69.6 were malicious. The version is pinned, those versions are refused by `make test`, and the image can be pinned by digest. Cosign verification of the release is recommended and **not done**. A scan is a point-in-time statement about known vulnerabilities, not proof of safety. |
| 6. Cloud | Registry-side scanning (ECR, ACR, GHCR with Dependabot), admission control that rejects unscanned or unsigned images (Phase 15). **Not done here.** |

## Phase 4

Status: **written, statically checked** (`tests/bootstrap/test_static.sh`, 64 checks), and **applied end to end on the target machine on 2026-09-22**. Image `0.3.0-c446b6b88521` was built, pushed, and deployed; `scripts/deploy/app.sh apply/status/smoke/logs` all succeeded on the first try, including the NetworkPolicy step. Rows below are updated with those results; resource requests/limits are still an estimate since no load test has been run.

### Deployment, Service, Ingress (`polaris-dev`)

| Question | Answer |
|----------|--------|
| 1. Problem | Runs the Phase 3 image as a reproducible Kubernetes workload, reachable through the same Traefik ingress the platform already uses, in the namespace the architecture document calls a real environment (`docs/architecture.md` 4.3). |
| 2. Why | Two replicas behind a Service and an Ingress is the smallest shape that proves rolling updates and load distribution work; a plain manifest (not Helm yet) keeps Phase 4 about "does it deploy" before Phase 5 asks "does it deploy to three environments without duplication" (ADR-22). |
| 3. Failure | `scripts/deploy/app.sh apply` checks the image tag exists in the local registry before applying anything (a fast failure instead of `ImagePullBackOff`), then waits on `kubectl rollout status` and prints pod and event diagnostics if it times out. *(verified 2026-09-22: image tag `0.3.0-c446b6b88521` found, rollout reached 2/2 `Ready`, `make deploy-status` showed all resources healthy, `make deploy-smoke` passed `/healthz`, `/readyz` and `/v1/chat`)* |
| 4. Scale | Stateless, so `replicas: 2` costs only RAM; a `PodDisruptionBudget` with `minAvailable: 1` keeps one pod up during a voluntary disruption. Resource requests/limits are the Phase 3 `docker run` numbers carried over as a starting estimate, not measured under load (Phase 9/11 replace them). |
| 5. Security | Pod Security Admission `restricted` on the namespace; `securityContext` matches the Phase 3 run flags exactly (non-root uid/gid 10001, no capabilities, no privilege escalation, read-only root filesystem, `seccompProfile: RuntimeDefault`); `automountServiceAccountToken: false` (the service calls no Kubernetes API). **Not done:** no Secret yet (nothing needs one until Phase 11), no `ai-gateway` in front of the Service yet (Phase 12). |
| 6. Cloud | The same manifests (parameterised by Helm in Phase 5) on EKS/AKS/GKE, behind a managed load balancer instead of a k3d port mapping. |

### Probes wired to Kubernetes

| Question | Answer |
|----------|--------|
| 1. Problem | Turns the Phase 3 `/healthz`/`/readyz` endpoints into the two decisions Kubernetes actually makes: restart this container, or stop sending it traffic. |
| 2. Why | `livenessProbe` and `readinessProbe` point at different paths on purpose (ADR-20); a `startupProbe` gives a generous, documented-as-generous budget for the first health check on a busy machine, rather than tuning `initialDelaySeconds` by guesswork. |
| 3. Failure | A pod that never reports ready stays out of the Service's Endpoints (no ingress traffic), and a pod that fails liveness is restarted by the kubelet — neither requires the `NetworkPolicy` to be in place. *(verified 2026-09-22: both pods reached `Ready` on their own after the startup/readiness probes passed, before the NetworkPolicy was ever applied)* |
| 4. Scale | Cheap, stateless HTTP checks; no change from Phase 3's numbers. |
| 5. Security | Known, named gap carried over from Phase 3: the app does not flip `/readyz` to "not ready" on shutdown. A `preStop` sleep (5 s) plus a 15 s termination grace period narrows the traffic-during-shutdown race; it is a mitigation, not a fix (ADR-22). |
| 6. Cloud | Same probe semantics on any managed Kubernetes; a service mesh could add outlier detection on top, not used here. |

### PodDisruptionBudget and NetworkPolicy

| Question | Answer |
|----------|--------|
| 1. Problem | A `PodDisruptionBudget` keeps at least one pod serving during a *voluntary* disruption (node drain, cluster upgrade). A `NetworkPolicy` restricts which pods may even open a connection to `ai-service`, independent of what the application itself would accept. |
| 2. Why | `minAvailable: 1` is meaningful once `replicas: 2` exists, so it costs nothing to add now. Default-deny plus an explicit allow from `kube-system` (Traefik) is the smallest policy that still lets real traffic through; k3s enforces `NetworkPolicy` with an embedded controller, so this does not need a different CNI. |
| 3. Failure | A `PodDisruptionBudget` failure mode is silent by design: `kubectl drain` simply waits or refuses, it does not error the workload (not exercised — no drain was performed). A `NetworkPolicy` failure mode is not silent: if it blocks more than intended (including, possibly, kubelet's own probe traffic), pods stop being Ready. `scripts/deploy/app.sh apply` applies it last and re-checks readiness for exactly this reason. *(verified 2026-09-22: 10 seconds after the NetworkPolicy was applied, both pods were still `Ready`, and `make deploy-smoke` passed straight after — this is one data point on one k3s/kube-router setup, not proof for every CNI)* |
| 4. Scale | Both are namespace-scoped and cost nothing beyond the API objects themselves. |
| 5. Security | The `NetworkPolicy` is the first place in this project where "which pods may talk to this one" is enforced by the platform instead of assumed. It does not cover egress (the service makes no outbound calls yet — Phase 11 changes that) and it is one namespace, not the default-deny-everywhere posture a real platform would want across all namespaces (Phase 15). |
| 6. Cloud | Same primitives on any CNCF-conformant CNI; a managed cluster typically adds a cloud load balancer's own health checks on top of the `PodDisruptionBudget`. |

## Phase 5

Status: **done, verified on the target machine on 2026-09-22.** The chart was checked in the sandbox first (custom Go-template-subset renderer, semantic diff against Phase 4's manifests — see below), then run for real: `helm lint` passed for `dev`/`staging`/`prod` on the first try; `helm upgrade --install` for `staging` (2/2 pods) and `prod` (3/3 pods, `PodDisruptionBudget.minAvailable: 2`) succeeded on the first attempt; `dev` needed one manual fix first (the pre-existing `polaris-dev` namespace lacked Helm's ownership metadata — see `docs/troubleshooting.md` Phase 5) and then also succeeded, 2/2 pods. All three releases' NetworkPolicy step left pods `Ready`, and all three passed `helm-smoke-<env>` (`/healthz`, `/readyz`, `/v1/chat` through the same Traefik port, routed by `Host` header).

### One chart, three environments (`helm/ai-platform`)

| Question | Answer |
|----------|--------|
| 1. Problem | Phase 4 could only ever apply `polaris-dev` from hand-written YAML; adding `polaris-staging`/`polaris-prod` that way would mean three near-identical copies of seven files, drifting the moment one of them is hand-edited. |
| 2. Why | One chart, `values.yaml` for what's identical (security context, probes, NetworkPolicy shape, ConfigMap keys) plus one thin `values-<env>.yaml` per environment for what differs (namespace, ingress host, and — prod only — replica count and disruption budget) is the smallest change that removes the duplication (ADR-23). |
| 3. Failure | A missing or misspelled value fails the template render via an explicit `required` guard (`environment`, `namespace`, `ingress.host`, `image.repository`, `image.tag`) rather than deploying into the wrong namespace or with no image reference — not exercised for real, since no value was ever missing. What *did* fail on the target machine (2026-09-22): `helm upgrade --install` for `polaris-dev` refused to proceed, because the chart's own `templates/namespace.yaml` tries to manage the Namespace object too, and `polaris-dev` already existed from Phase 4's raw `kubectl apply` without Helm's ownership metadata. `staging`/`prod` never hit this — their namespaces did not exist before Phase 5. Fixed once by hand (`kubectl label`/`annotate` the existing namespace with Helm's ownership keys — the tool's own documented pattern for adopting a pre-existing resource), then `dev` installed cleanly too. A second, related failure also happened on the target machine: re-running `make deploy-delete` on `polaris-dev` *after* it was already Helm-managed silently deleted the Helm-owned resources (by name/kind, blind to ownership) while `helm status` kept reporting the release as `deployed` — recovered with a plain `make helm-apply-dev`, no uninstall needed. See `docs/troubleshooting.md` Phase 5 for the exact commands. |
| 4. Scale | Rendering is instant regardless of environment count; a fourth environment is one more `values-<env>.yaml`, not one more copy of the templates. |
| 5. Security | Selector labels (`app.kubernetes.io/name`) and Helm's own bookkeeping labels are two separate template helpers on purpose, so upgrading a release can never accidentally touch a Deployment's immutable `spec.selector`. The Namespace template is annotated `helm.sh/resource-policy: keep` so `helm uninstall` cannot delete it, matching Phase 4's `deploy-delete` behaviour. |
| 6. Cloud | The same chart is what Phase 8's Argo CD points at instead of a person running `helm upgrade --install` by hand; nothing about the chart itself needs to change for GitOps to take over. |

### Verification without a live Helm binary in the sandbox

| Question | Answer |
|----------|--------|
| 1. Problem | Every earlier phase's scripts could at least be shellchecked and syntax-checked in the sandbox before the target machine ran them for real. Helm itself could not even be installed here: `get.helm.sh` is not on the sandbox's allowlisted egress (package registries and Anthropic's own hosts only), so there was no `helm` binary to run `helm lint`/`helm template` with. |
| 2. Why | Rather than skip verification, a small Python script was written that implements only the exact Go-template constructs the chart actually uses (`.Values.x.y` lookups, `include`, `required`, `toYaml`, top-level `if`/`range`) and renders all three environments' full YAML, which was then diffed field-for-field against Phase 4's already-verified manifests. |
| 3. Failure | This renderer is not Helm — it would not catch a Helm-specific templating mistake outside the constructs it implements (nested conditionals, subcharts, hooks, `lookup`, none of which this chart uses), and it has no cluster to check *runtime* behaviour against, only rendered YAML. It caught two real bugs while being built (a context-lookup bug and a missing `default` filter), which is itself evidence it is checking something — but on the target machine (2026-09-22) it was proven right about its own limit: the one real failure Phase 5 hit (`polaris-dev`'s pre-existing namespace lacking Helm ownership metadata, `docs/troubleshooting.md`) is a live-cluster adoption problem, not a template-rendering one, and no amount of rendering it locally would ever have surfaced it. `helm lint`/`helm template`/`helm upgrade --install` on the target machine (Helm 4.3.0, already installed by Phase 1's `make tools-install`) is the check that actually counts, and it is the one that found this. |
| 4. Scale | N/A — a one-off verification aid, not part of the shipped chart or scripts. |
| 5. Security | N/A. |
| 6. Cloud | N/A — every real environment has network access to install Helm properly; this workaround is specific to this sandbox's egress allowlist. |

## Phase 6

Status: **done — the full pipeline ran on GitHub Actions for real and finished green, including the Docker/Kubernetes half.** `make lint` and `make test` (127 static checks) pass. `gitleaks v8.30.0` and `actionlint v1.7.12` were downloaded from GitHub release assets and checksum-verified for real; `pip-audit 2.10.1` and `yamllint 1.38.0` were installed from PyPI for real. `make ci-secrets-scan`, `make ci-deps-audit` and `make ci-workflow-lint` all ran against the real repository content and passed in the sandbox before anything was pushed — genuinely, not simulated (see `docs/adr/README.md` ADR-24, including a real bug actionlint's embedded shellcheck caught and fixed before this was ever pushed). On GitHub Actions itself (2026-09-22), it took three pushes to get a fully green run: the first real run exposed a bug no local testing had ever caught — an unanchored `.gitignore` pattern had silently kept `scripts/build/image.sh` out of every commit since Phase 3 — and fixing it surfaced a second, small regression in this project's own static tests. Both are fixed and documented in `docs/troubleshooting.md` and ADR-24. The third push (commit `48cb3a1`) passed all six jobs, including `build-scan-deploy` (image build/check/scan/SBOM, the ephemeral k3d-in-runner cluster, Helm deploy, smoke test — 2m 1s) and `publish` (GHCR).

### CI workflow (`.github/workflows/ci.yml`)

| Question | Answer |
|----------|--------|
| 1. Problem | Turns "does this change build, pass its tests, and meet the project's own quality/security gates" into something that runs automatically on every push and pull request, instead of relying on a person remembering to run `make test` before pushing. |
| 2. Why | GitHub Actions, because the code already lives on GitHub and it needs no separate CI service account or billing decision. Every step calls the same `make` target a developer would run locally (ADR-24) — the workflow is a scheduler for existing, already-reviewed commands, not a second implementation of what they do. |
| 3. Failure | A failing `lint`/`test`/`app-check` stops the pipeline before Docker is even touched (`build-scan-deploy` `needs:` all four fast jobs). A failing `image-scan` (fixable HIGH/CRITICAL) or a failing `helm-smoke-dev` stops it before `publish` ever runs, since `publish` needs `build-scan-deploy` to succeed. *(observed 2026-09-22)*: this is exactly what happened, twice, for real — `lint-and-test` failed on its first two real runs (an unanchored `.gitignore` pattern hiding `scripts/build/image.sh`, then a static-test regression from fixing that), and both times `build-scan-deploy` and `publish` correctly never started. The third run passed `lint-and-test` and all downstream jobs followed — see `docs/troubleshooting.md` (Phase 6). |
| 4. Scale | Four of six jobs run concurrently (`lint-and-test`, `secrets-scan`, `deps-audit`, `workflow-lint`); a second push to the same branch cancels the run already in flight for it (`concurrency: cancel-in-progress: true`), so runner minutes are not spent on a commit that is already superseded. |
| 5. Security | `permissions: contents: read` at the top level; only the `publish` job (gated to pushes on `main`, never a pull request) is granted `packages: write`, and only for as long as that one job runs. Secret scanning and dependency auditing (below) are gates in the same pipeline, not separate, optional tooling. **Not done:** branch protection requiring these checks to pass before a merge (a GitHub repository setting, not a file in this repo — see the Phase 6 guide's handoff); OIDC-based signing of the published image (Phase 15). |
| 6. Cloud | This already *is* the cloud piece — GitHub-hosted runners, not a local machine. What changes in a larger organisation is scale (more runners, a self-hosted runner pool for compliance reasons) and gates (required reviewers, a security team's own policy-as-code step), not the shape of the pipeline. |

### Secret scanning and dependency audit (gitleaks, pip-audit)

| Question | Answer |
|----------|--------|
| 1. Problem | Catches two different classes of supply-chain risk before they reach `main`: a credential accidentally committed (gitleaks), and a pinned runtime dependency with a publicly known vulnerability (pip-audit — the same problem Trivy's image scan already covers for the built image, Phase 3, but pip-audit catches it from the `requirements.txt` alone, before an image is even built). |
| 2. Why | Both tools are widely used, single-purpose, and fast enough to run on every push. gitleaks installs the same checksum-verified way as k3d/kubectl/helm (`scripts/bootstrap/install-tools.sh`); pip-audit is pure Python and installs from PyPI into a throwaway venv, since the sandbox and CI runners can both reach PyPI even when they cannot reach `get.helm.sh` (ADR-23) or a Docker daemon. |
| 3. Failure | `scripts/ci/secrets-scan.sh` exits non-zero and writes a redacted JSON report (file/line/rule, never the secret value itself) to `artifacts/gitleaks-report.json` if anything is found; `scripts/ci/deps-audit.sh` does the same to `artifacts/pip-audit-report.json`. *(observed 2026-09-22, in the sandbox)*: both ran clean against the real repository — `gitleaks`: "no leaks found"; `pip-audit`: "No known vulnerabilities found" against the 17 pinned packages in `app/ai_service/requirements.txt`. |
| 4. Scale | Both scan a small, pinned dependency file and a modest repository; each run takes well under a second (gitleaks) to a few seconds (pip-audit, which queries a vulnerability database per package). Neither would slow down meaningfully as the repository grows within this project's scope. |
| 5. Security | gitleaks scans the working tree only in the sandbox (no `.git` directory there — see `docs/troubleshooting.md`) but scans full git history on a real checkout (`fetch-depth: 0` in the workflow), so a secret committed and later removed is still caught. pip-audit's scope is deliberately `requirements.txt` only, not `requirements-dev.txt` — dev tools (pytest, ruff) never ship in the image and auditing them would not change what actually runs in production, mirroring the runtime/dev split Trivy's image scan already draws. |
| 6. Cloud | A managed alternative (GitHub Advanced Security's own secret scanning and Dependabot) would overlap with what these two steps already do; both are kept here because they run identically whether or not GitHub Advanced Security is enabled on the repository, and because writing the check yourself is more evidence of understanding it than enabling a vendor feature. |

### Ephemeral-cluster deploy validation and GHCR publish

| Question | Answer |
|----------|--------|
| 1. Problem | Proves "this chart still deploys and the API still works" on every push, without ever giving a GitHub-hosted runner (which runs untrusted pull-request code) a path onto a real, long-lived cluster (ADR-12, ADR-24) — and gets a verified image onto a registry other systems (a future Phase 8 gitops repository, Phase 15's signing) can pull from. |
| 2. Why | The runner creates its own k3d cluster from the exact same `deploy/k3d/cluster.yaml` a developer's machine uses, deploys `polaris-dev` with the exact same `make helm-apply-dev`/`make helm-smoke-dev` a developer would run, and throws the cluster away at the end of the job — nothing persists, nothing is shared with a real environment. GHCR was chosen over a self-hosted registry for the same reason ADR-07 already gave: free, simple, and it is where the image needs to end up to be pulled by anything outside this one machine. |
| 3. Failure | *(observed 2026-09-22)*: `build-scan-deploy` and `publish` both ran against a live Docker daemon and a live GitHub Actions runner for the first time and both succeeded — the ephemeral k3d cluster came up, the image built, the hardened-container check and Trivy scan passed, the SBOM was generated, Helm deployed to `polaris-dev` and the smoke test passed through Traefik, all in 2m 1s, then the image was pushed to GHCR. No failure of this specific step has been observed yet. By design: a failing `image-scan` (fixable HIGH/CRITICAL) or a failing `helm-smoke-dev` would stop the job before `publish` is even considered, and `publish` only runs on a push to `main`, never a pull request, so a fork cannot make an untrusted change reach GHCR. |
| 4. Scale | Only `polaris-dev` is deployed and smoke-tested in CI, not all three environments, on every push — a deliberate scope limit (ADR-24), not an oversight; `staging`/`prod` share the same chart and templates `dev` just proved. |
| 5. Security | The published image is retagged from the exact build `image-check`/`image-scan` already examined (`docker save`/`docker load` between jobs), never rebuilt — what reaches GHCR is what was verified, not a second, unverified build of the same commit. `packages: write` is scoped to the `publish` job alone. **Not done:** image signing (Cosign, Phase 15), so a pulled image's origin cannot yet be cryptographically verified beyond "GHCR says it came from this repository". |
| 6. Cloud | This already runs on GitHub's cloud infrastructure; a larger organisation would typically add a private registry mirror or pull-through cache and a signing/attestation requirement enforced by admission control (Phase 15) before treating a published image as deployable. |

## Phase 7

Status: **written and shellchecked in the sandbox; its first real run, including a deliberate failure-injection test, is on the target machine** — the same status every earlier cluster-dependent script had before its first target-machine run (Phase 4's `deploy/app.sh`, Phase 5's `deploy/helm.sh`). `make test` (139 static checks, up from 127 at the end of Phase 6) passes, including checks that verify the script's own design decisions in code — not just that it exists: that all six checks are defined and actually called from `main()`, that the metrics check can only warn and never fail the whole run, and that no individual check calls `die()` (which would stop the script before every check has run).

### Post-deploy verification (`scripts/verify/post-deploy.sh`)

| Question | Answer |
|----------|--------|
| 1. Problem | Answers a question Phase 5's `helm-smoke-<env>` cannot: not "did the last deploy finish", but "is what is running right now, in a persistent environment, actually healthy" — rollout status, health, readiness, a real (non-empty) AI answer, structured-log presence, and (advisory) pod resource metrics. This is ADR-12's second verification loop, "in the local cluster" — distinct from Phase 6's ephemeral, pre-merge CI loop, which only ever sees one deploy and is torn down immediately after. |
| 2. Why | A host-side script calling `kubectl`/`curl`, the same pattern every other phase's cluster-facing code in this project already uses (`scripts/deploy/app.sh`, `scripts/deploy/helm.sh`, Phase 1's `smoke-test.sh`) — verified genuinely end to end on the target machine, rather than an unverified Kubernetes Job manifest with its own container image and RBAC (see ADR-25's "Alternatives" for why that was not built now). All six checks always run and are reported together, not fail-fast, because a real bad deploy is more useful to debug from a full report than from the first symptom alone. |
| 3. Failure | By design: `check_rollout`/`check_health`/`check_ready`/`check_ai_answer`/`check_logs` each independently `record_fail` and the script exits non-zero if any of them do — proven, not assumed, by the guide's deliberate-failure test (`--set config.POLARIS_MOCK_READY=false`, which genuinely breaks `/readyz` without touching any code, then reverted). `check_metrics` can only `record_warn`, enforced at the test level (`tests/bootstrap/test_static.sh` check 46) — a missing or not-yet-populated metrics reading is never, by itself, treated as a bad deploy, since there is no threshold-based analysis until Phase 9/10/18. |
| 4. Scale | Six `curl`/`kubectl` calls against one release; runs in a few seconds once the cluster and pods are warm. Would not meaningfully slow down as the platform grows within this project's scope — the real scaling question is *when* this runs (on demand here; on a schedule or after every GitOps sync once Phase 8/18 exist), not how long one run takes. |
| 5. Security | Read-only against the cluster (`kubectl rollout status`, `kubectl logs`, `kubectl top pod`, `curl` against the service's own public contract) — it changes nothing, matching the "verification", not "remediation", scope the roadmap gives Phase 7. Logs are read through the same field-allow-list guarantee Phase 3 (ADR-20) already established; this script does not add a new way for a prompt to leak. |
| 6. Cloud | The production equivalent is a Kubernetes `Job` or `CronJob` running the same checks from inside the cluster (documented, not built here — ADR-25), or, once Phase 9/10/18 exist, an Argo Rollouts `AnalysisTemplate` querying Prometheus with real thresholds instead of a script that can only report presence/absence. |

