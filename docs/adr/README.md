# Architecture decision records

Short records of significant decisions: what was chosen, why, and when to revisit. The design context is in [../architecture.md](../architecture.md).

| ID | Decision | Reason | Revisit when |
|----|----------|--------|--------------|
| ADR-01 | **k3d** as the local cluster | Light, fast, built-in registry, real Kubernetes | Measurements show a problem |
| ADR-02 | **Argo CD + Argo Rollouts** (not Flux + Flagger) | Best demonstration of GitOps plus progressive delivery; adds new evidence | Depth in Flux is preferred |
| ADR-03 | **Python 3.12 + FastAPI** | AI ecosystem, OpenTelemetry/Prometheus support, readable | Not expected |
| ADR-04 | **`ModelBackend` interface** with `MockBackend` and `OpenAICompatBackend` | Swap engines by configuration; mock enables deterministic failure tests | — |
| ADR-05 | **Ollama** as the local model server | CPU-friendly, OpenAI-compatible API | Phase 11 benchmark shows a better option |
| ADR-06 | Metrics by **Prometheus scrape**; traces and logs by **OTLP** via the Collector | Matches what Argo Rollouts and OpenCost consume | OTel metrics path preferred |
| ADR-07 | **GHCR** instead of Harbor | Free and simple; Harbor documented | Never for local |
| ADR-08 | **Monorepo until Phase 8, then split** into `polaris-ai-platform` and `polaris-gitops` | Simple early phases; the split is a demonstrated architecture change | — |
| ADR-09 | **Thin custom `ai-gateway` behind Traefik**; evaluate Envoy Gateway in Phase 12 | AI-specific policy is application logic; explainable; low RAM | Envoy Gateway proves affordable |
| ADR-10 | **Sealed Secrets** for GitOps secrets | Works with Argo CD without plugins | External Secrets with a local backend is wanted |
| ADR-11 | **Environments = namespaces** in one cluster, one shared model server | Memory constraint of a developer workstation | A 32 GB+ machine is available |
| ADR-12 | **Two verification loops**: ephemeral k3d in CI, Argo Rollouts analysis in the local cluster | GitHub runners cannot reach a laptop cluster | A cloud test cluster is added |
| ADR-13 | **Docker Engine inside WSL2** (not Docker Desktop) | Lighter, Linux-native, no desktop licensing question | Docker Desktop features are needed |
| ADR-14 | **Pinned tool versions** in `versions.env`, installed with verified checksums; Kubernetes version pinned by the k3s image | Reproducibility and supply-chain hygiene | Each upgrade, one tool at a time |
| ADR-15 | **Helm 4** as the Helm major version | Current major at the time of writing | A chart or tool in the stack requires Helm 3 |
| ADR-16 | **Kubernetes 1.34** (k3s v1.34.10) while WSL2 runs cgroup v1 | k3s 1.35.8 does not start on this host (kubelet refuses cgroup v1); 1.34.10 verified working | **Before 2026-10-27** (1.34 upstream end of life), or as soon as WSL2 uses cgroup v2 |
| ADR-17 | **Python service toolchain**: FastAPI, pydantic-settings (environment only), `src` layout, exact pins in `requirements*.txt`, ruff, pytest | Mainstream, readable, testable; reproducible installs; one config source | A build tool with a lock file (uv) is wanted, or `httpx` is replaced by `httpx2` |
| ADR-18 | **API contract rules** for `/v1/chat`: request id policy, tenant id validation, one error envelope, `latency_ms` = backend time, prompts never logged | Safe defaults now, so later phases add to them instead of changing them | Phase 12/14 (gateway derives the tenant) |
| ADR-19 | **Container image**: multi-stage, `python:3.12-slim-trixie`, non-root uid 10001, no pip at runtime, exact pins with binary wheels only, immutable tag `<version>-<git sha>` and no `latest` | Small, reproducible, least-privilege image whose exact origin is always readable from its tag and labels | The base image digest is bumped, Python 3.13 is adopted, or a distroless base is evaluated (Phase 15) |
| ADR-20 | **Probes and structured logs**: `/healthz` (liveness, no dependencies), `/readyz` (backend reachable), JSON logs with a field allow-list, request id in the service's own access line | Kubernetes needs two different answers; log pipelines need parseable lines; prompts must never leak into either | Phase 10 adds trace ids; Phase 11 tightens readiness against a real model server |
| ADR-21 | **Scanner and SBOM**: Trivy 0.74.0 run as a container on a saved image tar (no Docker socket), gate on fixable HIGH/CRITICAL, CycloneDX SBOM, unfixed findings recorded in `docs/security/image-scan.md` | Reproducible without installing anything, and the scanner itself is treated as part of the supply chain | Phase 6 runs the same script in CI; Phase 15 adds signing and admission policy |
| ADR-22 | **Raw Kubernetes manifests** (not Helm yet) for `ai-service` in namespace `polaris-dev`: PSA `restricted`, `securityContext` matching the Phase 3 run flags, a `preStop` sleep instead of a real shutdown-readiness fix, resource requests/limits carried over from `docker run` as an estimate, a `PodDisruptionBudget`, and a default-deny `NetworkPolicy` relying on k3s's bundled netpol controller | One namespace is enough to prove the manifests before Phase 5 parameterises three of them with Helm; every hardening flag already had to exist and be verified in Phase 3 | Phase 5 (Helm chart, `polaris-staging`/`polaris-prod`); Phase 9/11 replace the resource estimate with measurements |
| ADR-23 | **One Helm chart** (`helm/ai-platform/`) renders `polaris-dev`/`polaris-staging`/`polaris-prod` from `values.yaml` + one `values-<env>.yaml` each; Phase 4's raw manifests (`deploy/k8s/ai-service/`) are kept as an unmodified reference, not deleted or templated in place. Migrating `polaris-dev` needed one extra manual step beyond the plan: adopting the pre-existing namespace into the release by hand (`kubectl label`/`annotate`), verified 2026-09-22 | Proves "one chart, three environments" without risking the already-verified Phase 4 YAML; a reference copy is worth more for an interview than a deleted one | Phase 8 (GitOps/Argo CD takes over `helm upgrade --install`); Phase 15 (chart signing/provenance) |

## Records

### ADR-16: Kubernetes 1.34 while the host uses cgroup v1

Status: accepted, temporary.

Context: the reference machine runs WSL2 with kernel 5.15.167.4 and cgroup v1 (`stat -fc %T /sys/fs/cgroup` prints `tmpfs`; `docker info` shows `Cgroup Version: 1`). With `rancher/k3s:v1.35.8-k3s1` the cluster never formed: `k3d-polaris-agent-0` did not register, and the logs showed the kubelet refusing to run on cgroup v1 (Kubernetes 1.35 changed this default). With `rancher/k3s:v1.34.10-k3s1` and kubectl v1.34.10 all three nodes became Ready and `make smoke` passed. According to kubernetes.io/releases (checked 2026-09-21), Kubernetes 1.34 reaches upstream end of life on **2026-10-27**; the supported minors at that date are 1.35, 1.36 and 1.37.

Decision: pin the k3s image to v1.34.10-k3s1 and kubectl to v1.34.10. `make doctor` fails if `cluster.yaml` pins 1.35+ on a cgroup v1 host, so the mismatch is caught before the cluster is created.

Alternatives:

- Move WSL2 to cgroup v2 and run a current Kubernetes. A community write-up (not verified on this machine) says cgroup v2 is the default from WSL 2.5.1 (newer kernel), and that older versions can force it with `kernelCommandLine = cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1` under `[wsl2]` in `%UserProfile%\.wslconfig`. Not done now because it changes the shared WSL2 kernel for every distribution on the machine (Docker Desktop, Podman machine, other local clusters), which is a decision to take on purpose and not in the middle of Phase 1.
- Stay on 1.35+ and disable the kubelet check. Rejected: it hides a real host limitation and is not something to demonstrate as a production practice.

Consequences: the local cluster runs a Kubernetes minor that leaves upstream support on 2026-10-27. That is acceptable for a local lab as long as it is stated plainly, and it must not be described as "current Kubernetes" in the portfolio after that date. Helm charts and manifests written in later phases must stay compatible with 1.34 and with the version it is later upgraded to.

Revisit when: before 2026-10-27, or as soon as the host reports `cgroup2fs`. Procedure: check `wsl --version` (PowerShell) and `stat -fc %T /sys/fs/cgroup`; if v2, change the k3s image and `KUBECTL_VERSION` together to the same supported minor, then `make doctor && make test && make cluster-reset && make smoke`.

### ADR-17: Python service toolchain

Status: accepted.

Context: Phase 2 needs a small service that runs on a laptop, is easy to test, installs identically on every machine, and can be containerised in Phase 3.

Decision: FastAPI on uvicorn; configuration only from environment variables via pydantic-settings; `src` layout with a `pyproject.toml`; exact versions of every direct and transitive dependency in `requirements.txt` and `requirements-dev.txt`; ruff for lint and format; pytest with coverage (gate at 95 %). The service uses `httpx` for outgoing calls to the model server.

Alternatives: Flask (fewer built-in validation and OpenAPI features), a lock-file tool such as uv or Poetry (better tooling, one more tool to learn and install; revisit when the dependency set grows), `httpx2` in the service.

Consequences: `make app-install` needs only Python 3.12 and network access to PyPI. In the development requirements, `httpx2` is installed as well, because Starlette's test client prefers it and warns when only `httpx` is present (observed with Starlette 1.6.0 on 2026-09-21). On PyPI, `httpx2` lists Tom Christie (the author of httpx and Starlette) as author and `github.com/pydantic/httpx2` as its source (checked 2026-09-21). The service itself keeps the tested `httpx` 0.28.1; moving it to `httpx2` is a separate, deliberate change.

Revisit when: a lock-file tool is worth its cost, or `httpx` stops being maintained.

### ADR-18: API contract rules for /v1/chat

Status: accepted; the tenant rule is temporary.

Decisions:

- **Request id:** taken from the `x-request-id` header only if it matches `[A-Za-z0-9._-]{1,64}`; otherwise a random 32-character id is generated. It is returned in the body and the response header and appears in the service's log lines, including the access line it writes for every request (from Phase 3, ADR-20; uvicorn's own access log is switched off). A client-supplied id is not trusted blindly, because it could forge log lines or explode a metrics label.
- **Tenant id:** must match `[a-z0-9][a-z0-9_-]{0,31}` (short, lower-case, low cardinality). In Phase 2 it is taken from the request body and is **not authoritative**: any caller can claim any tenant. From Phase 12/14 the gateway derives the tenant from the API key and rejects a mismatch.
- **Errors:** one JSON envelope `{"error": {"code", "message", "request_id", "details"?}}` for every error, including 404 and 405. 422 for invalid input, 502 when the backend fails, 504 on timeout, 500 for anything unexpected. Validation details name the field and the rule, never the submitted value.
- **`latency_ms`:** time spent in the backend call, not the whole HTTP request, so model time and platform overhead can be told apart later.
- **Prompts are never logged.** Logs carry ids, tenant, model, latency and token counts only. Prompts can contain personal or confidential data.

Consequences: later phases (structured logging, tracing, the gateway) add fields to this contract; they should not have to change it. Not yet covered: request size limits and rate limiting (Phase 12), authentication (Phase 12).

Revisit when: Phase 12/14 introduces authenticated tenants.

### ADR-19: Container image for the AI service

Status: accepted. Built, checked, pushed and run on the target machine on 2026-09-21 (see the Phase 3 guide and `docs/security/image-scan.md`).

Context: Phase 3 turns the service into something Kubernetes can run (Phase 4). The image must be small, must not run as root, must be reproducible, and must say which source revision it was built from.

Decision:

- **Two stages.** A builder stage creates a virtual environment from `requirements.txt` (exact pins, `pip install --only-binary=:all:`, so nothing is compiled and no compiler is needed) and installs the service as a normal package. The runtime stage copies only that virtual environment. pip is removed from both the virtual environment and the base image, so the running container has no package installer.
- **Base image `python:3.12-slim-trixie`.** The Debian release is named in the tag on purpose. `python:3.12-slim` was listed as an alias of the trixie variant in docker-library/official-images when checked on 2026-09-21, and naming it explicitly makes a change of Debian release a reviewed edit. The tag lives in `versions.env` and in the Dockerfile default; `make test` fails if they disagree. `make image-pin` prints the current digest so it can be pinned in `versions.env`; until it is, the build works but is not reproducible, and the build says so.
- **Non-root.** A system user with the fixed numeric id 10001 (Kubernetes can only verify `runAsNonRoot` for a numeric id). The image is run with a read-only root filesystem, no Linux capabilities and `no-new-privileges` by `make image-run` and `make image-check`; the Kubernetes manifests apply the same restrictions in Phase 4.
- **Tags.** `<version>-<12-character git sha>` is immutable and is what gets deployed; a `-dirty` suffix marks a build from uncommitted changes. `<version>` is a moving convenience tag. There is no `latest`. OCI labels carry version, revision, build time, source repository and base image.
- **Runtime flags.** uvicorn runs with `--no-access-log` (the service writes its own access line with the request id, ADR-20) and `--no-server-header`. `POLARIS_LOG_FORMAT=json` is set in the image; every other setting comes from the environment at run time.
- **Registry.** The local registry at `localhost:5000` (the same registry is `registry.localhost:5000` inside the cluster). GHCR comes with CI in Phase 6.

Alternatives: distroless or a hardened vendor base (smaller attack surface, no shell, harder to debug; worth evaluating in Phase 15 once there is something to compare against); Alpine (musl libc causes wheel and behaviour differences for little gain here); the floating `python:3.12-slim` tag (silent changes); buildpacks (less to learn from).

Consequences: `docker exec ... pip install` does not work, by design. Measured on the target machine on 2026-09-21: 134 MB, a 72.9 s cold build, and 44 HIGH findings, all in Debian OS packages with no fix available in trixie (`docs/security/image-scan.md`). The first `make image-build` on a fresh machine needs Docker Hub and PyPI.

Revisit when: the base image digest is bumped (a regular, deliberate change), Python 3.13 becomes the target, or Phase 15 compares a distroless base.

### ADR-20: Probes and structured logging

Status: accepted.

Context: Kubernetes asks two different questions of a container (should it be restarted, should it receive traffic), and a log pipeline needs one parseable object per line. The Phase 2 service answered neither, and uvicorn's access line did not carry the request id.

Decision:

- **`GET /healthz` (liveness)** returns `{"status": "ok"}` and checks nothing else. If liveness depended on the model backend, a slow model server would make Kubernetes restart healthy pods and add load.
- **`GET /readyz` (readiness)** asks the backend (`ModelBackend.check_ready()`), waits at most `POLARIS_READY_TIMEOUT_S` (default 2 s) and answers 503 in the standard error envelope (`not_ready`) if the backend is not ready. Readiness does not block `/v1/chat`: it tells the platform where to send traffic, and is not a switch inside the service. The mock backend is always ready unless `POLARIS_MOCK_READY=false` (used to practise the probe behaviour and in failure engineering). The OpenAI-compatible backend calls `GET <base_url>/models`; that is tested only against a fake transport until Phase 11.
- **Logs.** `POLARIS_LOG_FORMAT` is `text` (default, for a terminal) or `json` (set by the image). Only fields on an allow-list can appear in a log line (`request_id`, `tenant_id`, `model`, `latency_ms`, token counts, `code`, `reason`, `method`, `path`, `status`, `duration_ms`); there is no prompt field, so a careless `extra={"prompt": ...}` cannot leak one. In text format, values that could contain a newline are JSON-quoted so a client-controlled path cannot forge a log line.
- **Access line.** The service writes one `http request` line per request (method, path without query string, status, duration, request id) and uvicorn's own access log is switched off. Probe requests are logged at DEBUG so they do not drown the log.
- uvicorn's own start and stop messages are moved onto the same formatter, so every line on stdout is in one format.

Alternatives: a logging library (`structlog`, `python-json-logger`; one more dependency for a small need), OpenTelemetry logs (Phase 10), a single `/health` endpoint (cannot express "alive but not ready").

Consequences: request ids are now in the access log, which closes a known gap from ADR-18. Not done: readiness does not yet turn false while the process is shutting down (Kubernetes `preStop` and grace period, Phase 4/5), and there is no trace id in the logs (Phase 10).

Revisit when: Phase 10 adds trace and span ids; Phase 11 runs against a real model server and readiness can check that the configured model is loaded.

### ADR-21: Vulnerability scanner and SBOM

Status: accepted. Run on the target machine on 2026-09-21 (scan, SBOM); results in `docs/security/image-scan.md`.

Context: an image that is never scanned has unknown vulnerabilities, not none. In March 2026 the scanner itself was the attack: Trivy releases v0.69.4, v0.69.5 and v0.69.6 were malicious builds, and the `trivy-action` and `setup-trivy` tags were force-pushed to malicious commits (GitHub advisory GHSA-69fq-xp46-6x23; v0.69.2 and v0.69.3 are listed there as safe). A scanner is part of the supply chain.

Decision:

- **Trivy, version 0.74.0**, chosen because it is the latest release on the project's releases page as checked on 2026-09-21 (published 2026-08-14), which is after that incident. The version is pinned in `versions.env`; `make test` refuses 0.69.4, 0.69.5 and 0.69.6. `make image-pin` prints the image digest so it can be pinned too. The `ghcr.io/aquasecurity/trivy:0.74.0` tag was pulled successfully on 2026-09-21 and its digest is pinned in `versions.env`. The release was not signature-verified (cosign); that is not done.
- **Run as a container, on a tar file.** The image is exported with `docker save` and scanned with `--input`. The scanner container is *not* given the Docker socket (access to it is root-equivalent on the host) and runs as the calling user, so files in `artifacts/` are yours.
- **Gate.** `make image-scan` fails when a HIGH or CRITICAL finding has a fix available. Findings without a fix do not fail the run but must be written down in `docs/security/image-scan.md` with the reason they are accepted for now. This matches the policy sketched in the architecture document ("Critical/High vulnerability with a fix available").
- **SBOM.** `make image-sbom` writes a CycloneDX file to `artifacts/`. Reports and SBOMs are build artifacts and are not committed (`artifacts/` is git-ignored); Phase 6 attaches them to the CI run.

Alternatives: Grype and Syft (also good; one scanner is enough to learn from), Docker Scout (tied to Docker's service), installing the Trivy binary from a package repository (installs software on the host and bypasses the digest pin).

Consequences: the first scan downloads the vulnerability database (hundreds of MB) into `artifacts/trivy-cache`. The result depends on the database of the day, so a scan is a point-in-time statement.

Not done: verifying Trivy's release signature with cosign. The advisory describes how (`cosign verify` with the `aquasecurity` GitHub identity and checking Rekor timestamps); pinning by digest after that verification is the stronger control and is recommended before relying on the scanner in CI (Phase 6).

Revisit when: Phase 6 (CI), Phase 15 (signing and admission control), or the scanner project changes ownership or release practice.

### ADR-22: Kubernetes manifests for ai-service (raw, one namespace)

Status: accepted. Written and statically checked (`tests/bootstrap/test_static.sh`, 64 checks); applied to a cluster on the target machine on 2026-09-22 — see the NetworkPolicy bullet below and the Phase 4 guide for the full result.

Context: the image from Phase 3 needs somewhere to run that matches how the platform is supposed to work — probes wired to Kubernetes, non-root enforced by the platform and not just by the image, a namespace that is one of the three environments the architecture document already names (`docs/architecture.md`, section 4.3; ADR-11). Phase 5 (Helm) is where three environments and reusable values arrive; Phase 4 has to prove the manifests work at all, in one namespace, before templating them.

Decision:

- **Namespace `polaris-dev` only.** The architecture document's three environments (`polaris-dev`, `polaris-staging`, `polaris-prod`) are namespaces in one cluster from the same resources; Phase 4 applies only the first. `deploy/k8s/ai-service/` holds plain YAML, not a Kustomize base or a Helm chart, so there is exactly one templating step to add in Phase 5, not two.
- **Pod Security Admission: `restricted`** on the namespace (`docs/architecture.md`'s Security row: "NetworkPolicies, ResourceQuotas... Pod violates Pod Security restricted"). The Deployment's `securityContext` (`runAsNonRoot`, numeric `runAsUser`/`runAsGroup` 10001, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true`) is the same restriction already verified by `make image-check` and `make image-run` in Phase 3, expressed as Kubernetes fields instead of `docker run` flags, so `restricted` should accept it without a second round of loosening flags to find the right set.
- **Probes**: `livenessProbe`/`readinessProbe`/`startupProbe` point at `/healthz`/`/healthz`/`/readyz` from ADR-20. A `preStop` sleep (5 s) plus `terminationGracePeriodSeconds: 15` is added because the service does not flip `/readyz` to "not ready" while shutting down (a named Phase 3 gap): the sleep buys the Service time to drop the pod's Endpoint before SIGTERM. It narrows the race, it does not close it.
- **Resources**: `requests`/`limits` start from the Phase 3 `docker run` numbers (256Mi/1 CPU limit) verbatim, labelled as an estimate in the manifest and in `docs/component-qa.md`. Real numbers come from a load test in Phase 9/11, not from this phase.
- **`PodDisruptionBudget`** with `minAvailable: 1`, since `replicas: 2` makes it meaningful and it costs nothing to add now.
- **`NetworkPolicy`**: default-deny ingress for the namespace, plus an explicit allow from `kube-system` (where k3s runs its bundled Traefik) to port 8000. k3s enforces `NetworkPolicy` out of the box through an embedded controller built on kube-router's netpol module (separate from Flannel, which has no NetworkPolicy support of its own); no extra CNI is installed. This was the one manifest that could not be tested without a cluster: whether kubelet's own probe traffic (which originates from the node, not from another pod) is exempted from an "Ingress" policy is implementation-specific. `scripts/deploy/app.sh apply` applies it last, after the Deployment is already healthy, and re-checks pod readiness afterwards for exactly this reason. **Verified on the target machine, 2026-09-22:** both pods were still `Ready` 10 seconds after the policy was applied, and `make deploy-smoke` passed straight after. This is one data point on one k3s/kube-router setup, not a general guarantee for every CNI — a different CNI or a non-k3s cluster could still behave differently, and that risk is still worth naming in an interview.
- **No `ai-gateway`.** The architecture document places a gateway in front of `ai-service` for auth, rate limits and quotas, but that component does not exist until Phase 12. The `Ingress` in Phase 4 routes straight to the `ai-service` Service.
- **No Secret.** `POLARIS_BACKEND=mock` needs no credential. `POLARIS_OPENAI_API_KEY` is added as a Secret, referenced with `optional: true`, when Phase 11 wires a real model server — inventing an empty or placeholder Secret now would document a shape without a use for it.

Alternatives: Kustomize (an extra concept for one namespace; Phase 5 goes straight to Helm, which the final deliverable list already names); Helm now (the multi-environment values that justify it do not exist until Phase 5); `hostNetwork`/`NodePort` instead of Ingress (skips Traefik, which is what production would use); no `NetworkPolicy` until Phase 15 (cheap to add now, and k3s enforces it without extra installation, so leaving it out would not save any real setup cost).

Consequences: the Deployment's image tag is substituted by `scripts/deploy/app.sh`, not hand-edited, so the placeholder `__AI_SERVICE_IMAGE__` in `deployment.yaml` is never a valid reference by itself. Applying `networkpolicy.yaml` is a separate, later step in the same script specifically so a NetworkPolicy problem does not look like a Deployment problem.

Revisit when: Phase 5 replaces these files with a Helm chart and adds `polaris-staging`/`polaris-prod`; Phase 9/11 replace the resource estimate with measurements; Phase 12 adds `ai-gateway` in front of the Service; Phase 15 reviews `NetworkPolicy` scope alongside admission control.

### ADR-23: One Helm chart for three environments (`helm/ai-platform/`)

Status: accepted. Chart written; the raw templates were checked with a custom Go-template-subset renderer in the sandbox (no cluster, and no real `helm` binary — see "Context") and semantically diffed against Phase 4's already-target-machine-verified manifests, with a match on every field except the intentional Helm bookkeeping labels and the image reference (which is parameterised by design). `helm lint`/`helm template`/`helm upgrade --install` with the real Helm 4.3.0 binary ran on the target machine on 2026-09-22: `helm lint` passed for all three values files; `polaris-staging` (2/2 pods) and `polaris-prod` (3/3 pods) installed cleanly on the first try; `polaris-dev` needed one manual fix — see "Consequences" — and then also installed cleanly. All three passed their NetworkPolicy readiness check and their smoke test.

Context: Phase 4 (ADR-22) deliberately applied only `polaris-dev` from plain YAML, on purpose leaving "three environments from one set of resources" for this phase (`docs/architecture.md` 4.3, ADR-11; roadmap "Phase 5 done when: one chart deploys dev/staging/prod-like via values files with no YAML duplication"). Unlike every earlier phase, this one could not be even partially verified in the sandbox with the real tool: the sandbox's network egress is allowlisted to package registries and Anthropic's own hosts, and `get.helm.sh` (and the GitHub release asset host it redirects to) is not on that list, so the `helm` binary itself could not be installed here — unlike `kubectl`/`k3d`, there was no way to even syntax-check with the real tool before handing this to the target machine, which already has Helm 4.3.0 installed from Phase 1's `make tools-install`.

Decision:

- **One chart, `helm/ai-platform/`** (not `helm/ai-service/`): named for the platform, not today's one component, because `docs/architecture.md` Part D already reserves this path for the whole platform's chart and Phase 12's `ai-gateway` is expected to join it as a second component rather than be a reason to rename the chart later.
- **`values.yaml` holds every field that is identical across environments** (security context, probes, resources, NetworkPolicy shape, ConfigMap keys); **`values-dev.yaml`/`values-staging.yaml`/`values-prod.yaml` set only what actually differs**: `namespace`, `environment`, `ingress.host`, and — for `prod` only — `replicaCount: 3` and `podDisruptionBudget.minAvailable: 2`. Resource requests/limits stay identical in all three: nobody has load-tested this service (ADR-22), so only legitimate operational knobs (replica count, disruption budget) vary by environment, not invented capacity numbers.
- **Selector labels vs. bookkeeping labels are two separate template helpers** (`ai-platform.selectorLabels` = `app.kubernetes.io/name` only; `ai-platform.labels` = that plus `helm.sh/chart`, `app.kubernetes.io/managed-by`, `environment`). Every `spec.selector`/`podSelector` uses only the first, because a Deployment's selector is immutable after creation and because it is exactly the selector Phase 4's raw manifests already used — a chart install targets the same pods a `kubectl apply` would have.
- **The Namespace template carries `"helm.sh/resource-policy": keep`**, so `helm uninstall` never deletes it — the same behaviour Phase 4's `app.sh delete` already has (it removes `ai-service`'s resources, never the namespace).
- **`image.repository`/`image.tag` replace the `__AI_SERVICE_IMAGE__` sed substitution.** `scripts/deploy/helm.sh` computes the same `<version>-<git sha>` tag as Phase 3/4 (`app_version()`/`app_revision()`, deliberately duplicated again rather than shared, same reasoning as ADR-22) and passes it with `--set`; the template's `required` guard on both fields fails the render — not a silent `latest` or an empty string — if either is missing (ADR-19 still holds).
- **`deploy/k8s/ai-service/` (Phase 4) is kept, unmodified, as a reference — not deleted, not moved to `deploy/manifests/`.** `docs/architecture.md` Part D's target layout eventually renames that directory; doing so now was judged not worth the risk to files that are already verified and referenced from `scripts/deploy/app.sh`, `docs/adr/README.md` ADR-22, `docs/troubleshooting.md` and the Phase 4 guide. The rename is deferred, not abandoned — see "Revisit when".
- **Migrating `polaris-dev` from Phase 4 to Phase 5 is `make deploy-delete` (removes the raw-YAML-managed resources, keeps the namespace) followed by `make helm-apply-dev`**, not an in-place Helm "adoption" of existing resources. Adoption (annotating pre-existing objects with `meta.helm.sh/release-name` etc. so `helm install` accepts them) is a real Helm feature, but it adds failure modes for a one-time, already-scripted `deploy-delete` to solve instead.

Alternatives: Kustomize overlays instead of Helm values (rejected in ADR-22 already, for the same reason — the final-deliverables list names Helm); one values file with `--set` flags per environment instead of `values-<env>.yaml` files (less reviewable, no single source of truth for what "prod" means); adopting Phase 4's live `polaris-dev` resources into the Helm release in place (more moving parts than deleting and reapplying, for no real benefit at this scale); renaming `deploy/k8s/ai-service/` to `deploy/manifests/` now to match the final target layout (deferred — no functional benefit, and it would touch already-verified files and their cross-references for a purely cosmetic reason).

Consequences: from Phase 5 onward, `deploy/k8s/ai-service/` is documentation, not a live deploy path — `scripts/deploy/app.sh` still works exactly as Phase 4 left it (nothing here changes it), but `docs/deployment.md` now points at `scripts/deploy/helm.sh` as the way to actually deploy. Three releases (`ai-platform-dev`/`-staging`/`-prod`) can exist in the same cluster at once, sharing one Traefik ingress port, routed by Host header — `ai.localhost` / `ai-staging.localhost` / `ai-prod.localhost`, all confirmed on the target machine on 2026-09-22.

**Two gaps this decision did not anticipate, found on the target machine (2026-09-22):**

1. `make deploy-delete` (the chosen migration step) removes Phase 4's `ai-service` workload resources but was never meant to — and does not — touch the `polaris-dev` namespace itself. The Helm chart's own `templates/namespace.yaml` manages that Namespace object, though, and Helm refuses to take ownership of a pre-existing object (the namespace, created by Phase 4's raw `kubectl apply`) that lacks its ownership labels/annotations. `staging` and `prod` never hit this, since those namespaces never existed before Phase 5. The fix used was Helm's own documented adoption pattern, applied once by hand to the one object affected: `kubectl label namespace polaris-dev app.kubernetes.io/managed-by=Helm --overwrite`, then `kubectl annotate namespace polaris-dev meta.helm.sh/release-name=ai-platform-dev meta.helm.sh/release-namespace=polaris-dev --overwrite`.

2. `make deploy-delete` is a one-time migration step (run once, before the very first `make helm-apply-dev` in a namespace), but nothing stops it from being run again afterward — and if it is, it silently deletes the Helm-managed objects too, since `scripts/deploy/app.sh delete` deletes by name/kind, blind to which controller currently owns them. This happened once on the target machine (an accidental re-run after `polaris-dev` was already Helm-managed): `helm status` kept reporting `deployed` at the old `REVISION` — the release record is a separate Secret object that `app.sh delete` never touches — while `kubectl get` in `polaris-dev` reported no resources at all. Recovered with a plain `make helm-apply-dev` (no uninstall or re-adoption needed; `helm upgrade --install` recreated the missing objects from the existing release record), which bumped the release to `REVISION: 2`.

Neither was part of the original migration decision above and both are recorded here rather than silently folded into it, because a future phase migrating a different pre-existing raw-manifest namespace into Helm — or anyone re-running old commands from shell history near a Helm-managed namespace — will hit the same things. See `docs/troubleshooting.md`, Phase 5, for the exact commands.

Revisit when: Phase 8 (Argo CD calls `helm upgrade --install` instead of the target machine running `make helm-apply-*` by hand); Phase 9/11 replace the resource estimate with real measurements, at which point it may become worth letting resources differ by environment too; Phase 12 adds `ai-gateway` as a second component of this same chart; Phase 15 evaluates chart signing/provenance; whenever `deploy/k8s/ai-service/` is finally renamed to `deploy/manifests/` to match `docs/architecture.md` Part D. Also worth revisiting: whether `scripts/deploy/app.sh delete` (Phase 4) should pre-label the namespace with Helm's ownership metadata itself, so a future migration to Helm never needs the manual fix above — not done now, since Phase 4's script predates Phase 5 and changing it retroactively was judged not worth touching an already-verified file for a problem with a two-command, well-documented fix.

## Template for a new record

```
### ADR-NN: <decision>
Status: proposed | accepted | superseded by ADR-MM
Context: what forces the decision
Decision: what was chosen
Alternatives: what else was considered and why not
Consequences: what becomes easier, what becomes harder
Revisit when: the condition that reopens the decision
```
