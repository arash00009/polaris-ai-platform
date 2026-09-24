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

Status: **fully run for real on the target machine (2026-09-22), including a real chart bug found and fixed along the way.** `make helm-apply-dev/-staging/-prod` plus `make verify-dev/-staging/-prod` all reported genuine, healthy `PASS` results with real `kubectl top pod` metrics. The first deliberate `--set config.POLARIS_MOCK_READY=false` failure-injection test did not produce a failure, though — not because the script was wrong, but because it exposed a real gap in Phase 5's Helm chart: `deployment.yaml` had no `checksum/config` annotation, so a ConfigMap-only value change never triggered a Kubernetes rollout, and the already-running pods (confirmed identical by name/ReplicaSet hash before and after) never picked up the new value. The fix (the annotation, plus static check 50 enforcing it) was hand-verified in the sandbox first, then applied and re-tested for real: the same override now produces a genuine `FAIL rollout: ...` with a real, never-ready new pod, and reverting (after rebuilding the image for the fix's own commit — a separate, minor gotcha, `deployment.yaml`'s image tag is tied to the git SHA) produces a clean `PASS` again with yet another distinct ReplicaSet — see `docs/troubleshooting.md`, Phase 7, and ADR-25 for the full before/after evidence. `make test` (140 static checks, up from 127 at the end of Phase 6) passes, including checks that verify the script's own design decisions in code — not just that it exists: that all six checks are defined and actually called from `main()`, that the metrics check can only warn and never fail the whole run, that no individual check calls `die()` (which would stop the script before every check has run), and that `deployment.yaml` carries the checksum annotation this finding required.

### Post-deploy verification (`scripts/verify/post-deploy.sh`)

| Question | Answer |
|----------|--------|
| 1. Problem | Answers a question Phase 5's `helm-smoke-<env>` cannot: not "did the last deploy finish", but "is what is running right now, in a persistent environment, actually healthy" — rollout status, health, readiness, a real (non-empty) AI answer, structured-log presence, and (advisory) pod resource metrics. This is ADR-12's second verification loop, "in the local cluster" — distinct from Phase 6's ephemeral, pre-merge CI loop, which only ever sees one deploy and is torn down immediately after. |
| 2. Why | A host-side script calling `kubectl`/`curl`, the same pattern every other phase's cluster-facing code in this project already uses (`scripts/deploy/app.sh`, `scripts/deploy/helm.sh`, Phase 1's `smoke-test.sh`) — verified genuinely end to end on the target machine, rather than an unverified Kubernetes Job manifest with its own container image and RBAC (see ADR-25's "Alternatives" for why that was not built now). All six checks always run and are reported together, not fail-fast, because a real bad deploy is more useful to debug from a full report than from the first symptom alone. |
| 3. Failure | By design: `check_rollout`/`check_health`/`check_ready`/`check_ai_answer`/`check_logs` each independently `record_fail` and the script exits non-zero if any of them do. The guide's deliberate-failure test (`--set config.POLARIS_MOCK_READY=false`) proved this in two rounds. Round 1, against the unfixed chart, proved something more useful than expected: the injected change never reached any pod (a missing `checksum/config` annotation meant no rollout happened), so every check correctly reported `PASS` against what was genuinely, still, running — the script did not fail to detect a bad deploy, there was no bad deploy yet to detect. Round 2, after the chart fix, is the real proof: the same override produced a genuine `FAIL rollout: Waiting for deployment "ai-service" rollout to finish: 1 out of 2 new replicas have been updated...`, with a real new pod that never became Ready — while `healthz`/`readyz`/`ai-answer` correctly stayed `PASS`, because Kubernetes' rolling update kept the old, healthy pods serving traffic the whole time, exactly as the Phase 7 guide warned in advance. `check_metrics` can only `record_warn`, enforced at the test level (`tests/bootstrap/test_static.sh` check 46) — a missing or not-yet-populated metrics reading is never, by itself, treated as a bad deploy, since there is no threshold-based analysis until Phase 9/10/18. |
| 4. Scale | Six `curl`/`kubectl` calls against one release; runs in a few seconds once the cluster and pods are warm. Would not meaningfully slow down as the platform grows within this project's scope — the real scaling question is *when* this runs (on demand here; on a schedule or after every GitOps sync once Phase 8/18 exist), not how long one run takes. |
| 5. Security | Read-only against the cluster (`kubectl rollout status`, `kubectl logs`, `kubectl top pod`, `curl` against the service's own public contract) — it changes nothing, matching the "verification", not "remediation", scope the roadmap gives Phase 7. Logs are read through the same field-allow-list guarantee Phase 3 (ADR-20) already established; this script does not add a new way for a prompt to leak. |
| 6. Cloud | The production equivalent is a Kubernetes `Job` or `CronJob` running the same checks from inside the cluster (documented, not built here — ADR-25), or, once Phase 9/10/18 exist, an Argo Rollouts `AnalysisTemplate` querying Prometheus with real thresholds instead of a script that can only report presence/absence. |

## Phase 8

Status: **written and shellchecked; not yet installed on a real cluster.** `make test` (166 static checks, up from 140 at the end of Phase 7) passes, including checks that compare `scripts/bootstrap/argocd.sh`'s rollout-wait lists against the real, independently re-verified contents of the pinned Argo CD install manifest — the manifest itself, and the sha256 pinned in `versions.env`, were downloaded and checked for real, twice, in two separate sandbox sessions (`curl` to `raw.githubusercontent.com`, then Python's `yaml.safe_load_all`), not assumed. What has not happened yet: `make argocd-install` against a live cluster, `make gitops-bootstrap` reconciling the three `Application` resources, and the deliberate self-heal demonstration. Those are the target-machine steps the Phase 8 guide walks through next — the same "written here, run for real on the target machine" split every previous phase's Kubernetes-facing work went through first (Phase 4/5/7 in particular).

### Argo CD control plane (`scripts/bootstrap/argocd.sh`)

| Question | Answer |
|----------|--------|
| 1. Problem | Gets a working, upgradeable GitOps engine running inside the cluster without a manual, undocumented `kubectl apply` someone has to remember — the same "pinned, checksum-verified, no sudo" bar Phase 1's `install-tools.sh` set for k3d/kubectl/helm, applied to a tool that is not a local binary but a set of in-cluster resources. |
| 2. Why | Argo CD over Flux + Flagger (ADR-02, decided in Phase 0): both are legitimate, widely used GitOps engines; Argo CD was chosen specifically because it demonstrates something new rather than restating the Flux experience already on record elsewhere. The install manifest has no published checksums file the way k3d/kubectl/gitleaks/actionlint's release assets do, so the pin works like `PYTHON_BASE_DIGEST`/`TRIVY_IMAGE_DIGEST` instead: downloaded once for a specific tag, its sha256 computed and committed to `versions.env`, every future download checked against that fixed value before anything is applied to the cluster. |
| 3. Failure | `cmd_install` waits for a rollout of all 6 Deployments and the 1 StatefulSet the manifest creates, each with its own `--timeout`, and `die()`s with the exact `kubectl describe` command to run if one does not become ready. A checksum mismatch — a re-tagged release, a compromised mirror, a corrupted download — refuses to apply anything at all, loudly, rather than applying unverified YAML. Not yet observed for real: this whole path runs against a live cluster only on the target machine; the sandbox has no cluster to install into (same gap Phase 4/5/7's deploy scripts had before their first real run). |
| 4. Scale | One-time, or occasional (a version bump). Not something that runs per-deploy the way `helm-apply-<env>` does — installing Argo CD is closer to Phase 1's `make cluster-up` than to Phase 5's `make helm-apply-dev`. |
| 5. Security | The manifest is applied into its own `argocd` namespace, separate from `polaris-dev/-staging/-prod`; `cmd_uninstall` re-downloads and re-verifies the same pinned manifest before deleting, so uninstall removes exactly what install created, nothing guessed. **Not done:** restricting Argo CD's own RBAC beyond what the upstream manifest ships (it is cluster-admin-capable by default, appropriate for this single-tenant local cluster, not for a shared one — documented, not narrowed, this phase); Sealed Secrets (ADR-10), since no real secret exists yet for Argo CD to need one for. |
| 6. Cloud | A managed alternative (Argo CD as a hosted/managed service, or a vendor's own GitOps product) exists at several cloud providers; this project installs the open-source control plane directly because operating it — not just pointing at someone else's — is the thing being demonstrated. |

### GitOps flow (`polaris-gitops`: app-of-apps, multi-source Helm, promotion, self-heal)

| Question | Answer |
|----------|--------|
| 1. Problem | Turns "apply the right image to the right environment" from a person running `make helm-apply-<env>` by hand (Phase 5/7's model) into Git as the single source of truth: a commit to `polaris-gitops` is the deployment action, and the cluster is made to match it automatically rather than by someone remembering to run a command. |
| 2. Why | ADR-08's planned repository split, realized in this phase: `polaris-ai-platform` keeps the application, its chart, its CI, and its docs; `polaris-gitops` holds only deployment configuration — three `Application` manifests (an "app of apps" rooted at `bootstrap/root-app.yaml`) and one `environments/<env>/image.yaml` fragment per environment. Each `Application` uses Argo CD's multi-source-Helm feature so `polaris-gitops` never duplicates the chart's own `values-<env>.yaml` — it contributes only the one field that changes on every build, the image tag, since `helm/ai-platform/values.yaml` deliberately ships no default (ADR-19). This also realizes "pull not push": Argo CD, running inside the cluster, pulls from both repositories; neither repository's CI is ever given cluster credentials. |
| 3. Failure | Per-environment sync policy is the concrete demonstration of `docs/architecture.md`'s promotion table: `dev` and `staging` are `syncPolicy.automated` (staging's gate is the pull request into `polaris-gitops`'s `main`, not a second manual step); `prod` has no automated sync policy at all, so a merge updates its desired state and Argo CD marks it `OutOfSync`, but nothing reaches the cluster until an explicit sync — the honest, working substitute for a PR-approval-gated CD system this project does not have (see ADR-26's Consequences for the caveat: this enforces "requires a manual action", not "requires a *reviewed* manual action"). Not yet observed for real: no environment has been synced on the target machine yet. |
| 4. Scale | Three `Application` resources today, one per environment; the `platform/` directory is reserved, empty, for cluster-wide components a later phase adds the same way. Argo CD's default poll interval (about three minutes) plus webhook-triggered refreshes is unrelated to this project's size — it is the same mechanism whether it watches one Application or a thousand. |
| 5. Security | Neither repository's CI has write access to the cluster (`pull not push`). `polaris-gitops` has no secrets in it — none exist yet (the mock backend needs none); Sealed Secrets (ADR-10) is the documented plan once a real one does. Migrating the three existing Helm releases to Argo CD management uses a deliberately simple full-namespace-recreate (`make helm-uninstall-<env>` then `kubectl delete namespace polaris-<env>`) rather than Argo CD's resource-adoption process — a simplification a real production migration, with real traffic and no easy do-over, would not take; named explicitly as such in ADR-26 rather than presented as the general answer. |
| 6. Cloud | This already is the general shape a real GitOps setup uses; what changes at scale is more environments and more platform components under `platform/` (not a different mechanism), an `ApplicationSet` generating per-environment `Application`s instead of three hand-written files, and Argo Rollouts (already named for Phase 18) replacing a plain Kubernetes rolling update with canary/blue-green analysis gated on Prometheus metrics once Phase 9/10 exist. |

## Phase 9

Status: **written and shellchecked/tested; not yet installed on a real cluster.** `make test` (196 static checks, up from 169 at the end of Phase 8) passes; `app/ai_service`'s own suite (141 tests, 99.27 % coverage) runs and passes for real in the sandbox, the same way Phase 2's did — this is application code, not cluster-dependent, so it could be genuinely exercised here, unlike the four Helm releases this phase also adds. What has not happened yet: `make obs-install` against a live cluster, the `ai-platform` Helm upgrade that turns `serviceMonitor`/OTLP on in `polaris-dev`, and confirming Grafana actually shows the dashboard's seven panels with real data. Those are the target-machine steps `docs/observability.md` walks through next.

### `ai_service` instrumentation (`telemetry.py`: Prometheus metrics, OTLP traces/logs)

| Question | Answer |
|----------|--------|
| 1. Problem | Answers "is this service healthy and how is it behaving" with real signals instead of only the probe endpoints Phase 3 already had — request rate, error rate and latency per route without reading logs by hand, plus traces and structured logs a collector can correlate once Phase 10 curates them. |
| 2. Why | Prometheus scrape for metrics, OTLP for traces/logs — ADR-06's shape, decided in Phase 0, now actually wired up. `prometheus-fastapi-instrumentator` and the official `opentelemetry-*` SDK packages, not a hand-rolled exporter, chosen for the same "mainstream, not reinvented" reasoning as ADR-17's toolchain choices. |
| 3. Failure | Metrics are always on and cost nothing extra if nobody scrapes `/metrics`; traces/logs are opt-in (`POLARIS_OTEL_ENABLED`, default `false`) precisely because a real network call to a collector that does not exist in most of this project's environments should never be the default. Three real bugs were found by actually running the code, not by reading documentation: a self-referential logging loop from attaching the log handler to the root logger (fixed by scoping to `"ai_service"`), an unbounded shutdown that measured ~8s against an unreachable collector against a ~10s termination-grace budget (fixed with an explicit, bounded `otel_exporter_timeout_s`), and a metrics-registry collision across tests from sharing `prometheus_client`'s global registry (fixed with a private `CollectorRegistry()` per app instance). All three, and how they were found, are in `docs/troubleshooting.md` and ADR-27. |
| 4. Scale | Metrics: negligible — an in-process counter/histogram update per request. Traces/logs: batched (`BatchSpanProcessor`/`BatchLogRecordProcessor`), so a slow or unreachable collector cannot make a request slower; `test_requests_are_not_slowed_by_an_unreachable_collector` asserts this directly rather than assuming it from the SDK's documentation. |
| 5. Security | ADR-20's rule against logging prompts is unchanged and untouched by this phase — OTel logs carry the same structured fields the existing logger already produces, nothing new is added to what gets shipped off-box. `/metrics` and the OTLP endpoints carry no authentication (matching this project's existing "cluster-internal, `NetworkPolicy`-restricted" trust model, not a public-internet one); the `NetworkPolicy` ingress rule added this phase only opens scraping from the `observability` namespace specifically, not from everywhere. |
| 6. Cloud | The same OpenTelemetry SDK calls work unchanged against any OTLP-compatible backend — a managed observability platform (Grafana Cloud, Datadog, a cloud provider's own) swaps in by changing `POLARIS_OTEL_EXPORTER_OTLP_ENDPOINT`, not by changing application code. |

### Observability platform (kube-prometheus-stack, Loki, Tempo, OTel Collector — `deploy/platform/observability/`, `scripts/bootstrap/observability.sh`)

| Question | Answer |
|----------|--------|
| 1. Problem | Gives metrics, logs and traces somewhere to land and a way to look at all three together (Grafana, with Loki/Tempo wired in as datasources) — without which `ai_service`'s new instrumentation above has nothing to talk to. |
| 2. Why | kube-prometheus-stack bundles Prometheus + Grafana + the standard Kubernetes exporters behind one well-maintained chart rather than assembling each piece by hand; Loki and Tempo are Grafana Labs' own log/trace stores, chosen for the same "matches what the rest of the stack already expects" reasoning, and OTLP ingestion into both (rather than a vendor-specific push format) keeps `ai_service`'s exporter code backend-agnostic (see the row above). The OTel Collector sits in front of both as the single place `ai_service` sends OTLP to, rather than the application knowing about Loki's and Tempo's endpoints directly. |
| 3. Failure | `serviceMonitor.enabled`/`config.POLARIS_OTEL_ENABLED` default to `false` in every environment except `values-dev.yaml`, specifically to avoid a real failure mode: `ServiceMonitor` is a CRD owned by kube-prometheus-stack, and a Helm release that renders one before that CRD exists fails outright with "no matches for kind ServiceMonitor" (ADR-27, `docs/troubleshooting.md`). Four smaller issues were found and fixed while building this layer without ever having a live cluster to test against — a missing `ports.metrics.enabled` on the OTel Collector chart, a `dashboard-configmap` script that mangled a quote character, a Makefile target that referenced a subcommand that does not exist, and an incorrect claim about kube-prometheus-stack's default scrape interval — each caught by reading the actual upstream chart source or running the actual script, not by assuming either (`docs/troubleshooting.md`). Not yet observed for real: this entire layer runs against a live cluster only on the target machine. |
| 4. Scale | One Prometheus, one Grafana, one Loki and one Tempo instance for the whole cluster (`retention: 3d` on Prometheus, no persistence on Tempo, ephemeral by design — matching this project's "torn down and rebuilt" cluster philosophy, ADR-11). `kubeStateMetrics` stays on for pod-level metrics (needed for the dashboard's restart panel); the heavier per-node `nodeExporter` DaemonSet stays off, a deliberate footprint trade-off, not an oversight (ADR-27). |
| 5. Security | Prometheus discovers any `ServiceMonitor` in the cluster (`serviceMonitorSelectorNilUsesHelmValues: false`) and Loki runs with `auth_enabled: false` — both explicit single-tenant, single-cluster simplifications, named as such in ADR-27 rather than presented as the general answer; a shared cluster would need both revisited individually. Grafana's admin password (`polaris-local-only`) is a plaintext chart value, acceptable only because nothing behind it is real or reachable outside this local cluster — Sealed Secrets (ADR-10) is the documented plan for anything that would need to be a real secret. |
| 6. Cloud | The same LGTM-shaped stack (Loki, Grafana, Tempo, Mimir/Prometheus) is what many managed observability offerings run internally; moving to a managed backend means pointing the OTel Collector's exporters at it instead of at in-cluster Loki/Tempo, and Grafana Cloud (or similar) instead of a self-hosted Grafana — the same "swap the endpoint, not the code" property `ai_service`'s instrumentation already has. |

