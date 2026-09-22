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
