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
| ADR-24 | **CI pipeline** (`.github/workflows/ci.yml`): every step calls the same `make` targets used locally; an ephemeral k3d cluster is created **inside the GitHub-hosted runner** for deploy validation (not a self-hosted runner or a tunnel to a developer machine); GHCR is reached only from a dedicated `publish` job, gated to pushes on `main`, that reuses the image `build-scan-deploy` already verified instead of rebuilding it | Matches ADR-12's "two verification loops"; a self-hosted runner or a tunnel into a laptop cluster would be a real attack surface for a public repository | Phase 8 (a gitops-repo commit follows a successful publish); Phase 15 (image signing joins the publish job) |
| ADR-25 | **Post-deploy verification** (`scripts/verify/post-deploy.sh`, `make verify-<env>`): a host-side script — not a Kubernetes Job — checks rollout status, health, readyz, a real (non-empty) AI answer and structured-log presence against a running release, and always runs every check and reports all of them instead of stopping at the first failure; pod resource metrics (`kubectl top pod`, k3s's bundled metrics-server) are checked but only ever advisory (`record_warn`, never `record_fail`), since there is no Prometheus or threshold-based analysis until Phase 9/10/18 | Closes the second of ADR-12's two verification loops ("in the local cluster"), complementing loop 1 (Phase 6's ephemeral-cluster CI smoke); a Kubernetes Job would be the honest production equivalent but needs a purpose-built image and RBAC this phase does not need in order to be genuinely verifiable end to end | Phase 9/10 (Prometheus makes a real, threshold-based metrics check possible); Phase 18 (Argo Rollouts' `AnalysisTemplate`s take over the promote/rollback decision this script can only report on) |
| ADR-26 | **GitOps with Argo CD**: a genuinely separate `polaris-gitops` repository (ADR-08 realized), multi-source Helm `Application`s that contribute only the image tag on top of `polaris-ai-platform`'s own chart and values, per-environment sync policy (`dev`/`staging` automated with self-heal, `prod` manual-sync-only) as the concrete promotion model, and a full namespace-recreate migration for the three existing Helm-managed releases | Realizes ADR-02/ADR-08's plan; "manual approval" for `prod` needed something this project could actually build without a real CD-approval system | Phase 18 (Argo Rollouts takes over `syncPolicy` with canary/blue-green analysis gated on Prometheus, once Phase 9/10 exist) |
| ADR-27 | **Observability rollout scope and defaults**: `serviceMonitor.enabled`/`POLARIS_OTEL_ENABLED` default to `false` everywhere in `helm/ai-platform` except `values-dev.yaml`, to avoid a `ServiceMonitor` CRD-ordering failure; Prometheus's `serviceMonitorSelectorNilUsesHelmValues: false` and Loki's `auth_enabled: false` are deliberate single-cluster/single-tenant simplifications; `nodeExporter` stays off while `kubeStateMetrics` stays on (pod-restart data needs it); `LOKI_CHART_VERSION`/`TEMPO_CHART_VERSION` are deliberately left unpinned | A CRD applied by the same Helm release that also creates a resource of that CRD's kind can fail on first install, ordering-dependent; a shared/multi-tenant cluster would need each simplification revisited individually, not as a bundle | Phase 10 (OTel attribute curation may need `kubeStateMetrics`/`nodeExporter` revisited); the observability stack is installed in `staging`/`prod`; a real `helm list -n observability` pins the Loki/Tempo chart versions |
| ADR-28 | **OpenTelemetry attribute curation**: `_FilteringSpanExporter` (wrapping the real OTLP span exporter, not a `SpanProcessor`) rebuilds every finished span with only `docs/architecture.md` section 6's allow-listed attributes; a `logging.Filter` reuses `logging_setup.LOG_FIELDS` — one allow-list, not two — to also curate what reaches the OTel-exported copy of a log line, not only stdout; `trace_id`/`span_id` are stamped onto stdout log lines too (`TraceContextFilter`), not only the OTel-exported copy, so `kubectl logs` alone finds the matching trace; `model_version`/`prompt_version` stay in the allow-list but are never set — no source of truth exists yet for either | A `SpanProcessor`'s `on_end`/`_on_ending` hooks both run after `Span.end()` has already frozen the span's attributes in the pinned SDK (opentelemetry-sdk==1.44) — confirmed by trying the more obvious processor-based approach first and watching it raise `TypeError` on every attempted deletion; an exporter-level wrapper, rebuilding a `ReadableSpan` with trimmed attributes, was confirmed to work with a standalone script before being adopted here | Phase 11 (`model_version` becomes real once `OpenAICompatBackend` is actually used); a prompt-template system gives `prompt_version` a source of truth; Phase 12 (the gateway makes cross-service trace propagation possible — this ADR deliberately does not attempt it, since there is only one service to propagate *across* so far) |
| ADR-30 | **`ai-gateway`**: a new, separately deployable FastAPI service (not a shared library with `ai_service`) in the same Helm chart/release, gated by `gateway.enabled` (default `false`, only `values-dev.yaml` turns it on); auth derives tenant from the API key (`hmac.compare_digest`) and a mismatching body `tenant_id` is rejected with 403; per-tenant rate limit (token bucket) and daily quota are in-memory/per-pod, explicitly named LOCAL/DEMONSTRATION; its own dedicated `app.kubernetes.io/name: ai-gateway` Helm selector/label helpers, never built on `ai-service`'s; its first-ever real Kubernetes `Secret` (the API-key→tenant map) is applied directly via `helm upgrade --install`, bypassing GitOps, so a cleartext key is never committed to `polaris-gitops` | Closes Phase 10's own deferred cross-service trace-propagation gap and ADR-18's "Phase 12 derives the tenant" promise; a second Python package was simpler to reason about and deploy independently than threading auth/rate-limit/quota logic into `ai_service` itself, which has no business owning another tenant's credentials | Phase 14 (multi-tenancy may need the rate-limit/quota numbers to be per-tenant *configured*, not one flat default for every tenant); Phase 15 (Sealed Secrets takes over `GATEWAY_API_KEYS_JSON`); the per-pod rate limiter becomes a real problem once `gateway.replicaCount` > 1 (Redis-backed shared limiter, named not built) |

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

**A third gap, this one found by Phase 7 (2026-09-22), not by this phase's own testing:** `templates/deployment.yaml`'s container used `envFrom: - configMapRef: {name: ai-service-config}` with no checksum/hash annotation anywhere on the pod template. This chart passed every check available to it at the time — `helm lint`, a real install on the target machine, NetworkPolicy readiness, a smoke test through Traefik — because none of those exercise a ConfigMap-*value* change after the first install, only the first install itself. Kubernetes only creates a new ReplicaSet when a Deployment's own `PodTemplateSpec` hash changes, and referencing a ConfigMap by name is not part of that hash; a `helm upgrade --set config.<key>=<value>` genuinely updates the ConfigMap object (a new release revision, `helm status` reports success) but the already-running pods never restart and never see the new value. Phase 7's `scripts/verify/post-deploy.sh`, run for the first time against a real deliberate config change, is what exposed this — see ADR-25's own record and `docs/troubleshooting.md`, Phase 7, for the full evidence (identical pod names/ReplicaSet hash before and after) and the fix (a `checksum/config` annotation on the pod template, hashed from `configmap.yaml`'s rendered content), which is now confirmed on the target machine: the same deliberate override, re-run against the fixed chart, produced a genuine caught `FAIL` with a real new (and correctly never-ready) pod. Recorded here because the defect was in this phase's chart, not in Phase 7's verification logic, which behaved correctly given what was actually running.

Revisit when: Phase 8 (Argo CD calls `helm upgrade --install` instead of the target machine running `make helm-apply-*` by hand); Phase 9/11 replace the resource estimate with real measurements, at which point it may become worth letting resources differ by environment too; Phase 12 adds `ai-gateway` as a second component of this same chart; Phase 15 evaluates chart signing/provenance; whenever `deploy/k8s/ai-service/` is finally renamed to `deploy/manifests/` to match `docs/architecture.md` Part D. Also worth revisiting: whether `scripts/deploy/app.sh delete` (Phase 4) should pre-label the namespace with Helm's ownership metadata itself, so a future migration to Helm never needs the manual fix above — not done now, since Phase 4's script predates Phase 5 and changing it retroactively was judged not worth touching an already-verified file for a problem with a two-command, well-documented fix.

### ADR-24: CI pipeline (`.github/workflows/ci.yml`)

Status: accepted, and confirmed by a real, fully green GitHub Actions run. The parts that do not need Docker or a Kubernetes cluster (shell lint, static tests, secret scanning, dependency audit, workflow-file lint) were installed and run for real in the sandbox this project is developed in first, with genuine results — see "Consequences". The parts that do need Docker or a cluster (image build/check/scan/SBOM, the ephemeral k3d deploy, the GHCR publish) could not run in the sandbox (see "Context"); their first real run was on the target machine (Phase 3/4/5, already done) and, separately, this workflow's own first execution on GitHub Actions — a new category beyond earlier phases' "sandbox vs. target machine" split, since a GitHub-hosted runner is a third environment neither of those two is. That first execution took three pushes on 2026-09-22 to get right (see "Consequences" for the real results and the two bugs it found), and the third — commit `48cb3a1`, run #4 — passed all six jobs, including `build-scan-deploy` (2m 1s) and `publish`.

Context: ADR-12 already decided the shape — an ephemeral k3d cluster created inside CI's own runner for deploy validation, rather than a self-hosted runner or a tunnel into a developer's laptop cluster, because a public repository's Actions runners cannot be trusted with that kind of access to a machine outside GitHub's infrastructure. Phase 6 is where that decision becomes an actual workflow file, and where the rest of `docs/architecture.md`'s Section 8 ("CI/CD flow") and Section 10 ("Security flow") have to become real scripts: lint, test, secret scan, dependency audit, build, scan, SBOM, tag, publish, ephemeral-cluster deploy validation.

The sandbox this project is built in cannot reach `get.helm.sh` or `dl.k8s.io` (Phase 5's ADR-23 gap) and its `docker` CLI is present but the daemon is not reachable — so, unlike Phase 5, this was not a binary the sandbox simply lacked; the whole *class* of thing (a working Docker daemon, a place to run containers) is unavailable here, for any phase. What *is* reachable from the sandbox, checked on 2026-09-22: PyPI (used for `pip-audit`/`yamllint`), and specific GitHub release-asset download URLs by exact tag (used for `gitleaks`/`actionlint`) — though not the GitHub REST API itself (`api.github.com` answers 403 here: "sessions are bound to their configured repositories"), so a version could not be looked up as "latest" the way `versions.env`'s comment for Trivy could when Phase 3 was built; each pin below was found by probing specific release tags directly until the last one that resolved.

Decision:

- **Every step in the workflow calls a `make` target that also exists for local use** (`make lint`, `make test`, `make app-check`, `make ci-secrets-scan`, `make ci-deps-audit`, `make ci-workflow-lint`, `make tools-install`, `make cluster-up`, `make image-build`, `make image-check`, `make image-scan`, `make image-sbom`, `make image-push`, `make helm-lint`, `make helm-apply-dev`, `make helm-smoke-dev`, `make cluster-down`, `make image-publish`) — `tests/bootstrap/test_static.sh` (check 41) fails if a heavy workflow step stops calling one of these. Nothing in `.github/workflows/ci.yml` is logic that only runs in CI and was never run or reviewable locally; a developer can run the same commands before pushing and see the same result Actions will.
- **`scripts/bootstrap/install-tools.sh` gained `gitleaks` and `actionlint`** alongside k3d/kubectl/helm — same checksum-verified-download pattern, same `versions.env` pins (`GITLEAKS_VERSION=v8.30.0`, `ACTIONLINT_VERSION=v1.7.12`), same `--only <tool>` flag, so the CI workflow's "install gitleaks" step and a developer's `make tools-install` are the same code path, not two.
- **`scripts/ci/secrets-scan.sh`, `scripts/ci/deps-audit.sh`, `scripts/ci/workflow-lint.sh`** are new, small wrapper scripts (gitleaks; pip-audit against `app/ai_service/requirements.txt` only — the runtime dependencies that actually ship, not `requirements-dev.txt`; yamllint + actionlint against `.github/workflows/`), following the existing `scripts/lib/common.sh` conventions. `deps-audit.sh` and `workflow-lint.sh` create a throwaway `.venv-ci/` (gitignored) for `pip-audit`/`yamllint`, pinned exactly like `app/ai_service/requirements*.txt`, rather than installing into the system Python.
- **`scripts/build/image.sh` gained a `publish` subcommand.** It retags the image `cmd_build` already produced (`docker tag`, no rebuild) to `ghcr.io/<owner>/<repo, lowercased>/ai-service` and pushes both the immutable and version tags. `<owner>/<repo>` comes from `$GITHUB_REPOSITORY` (set automatically inside Actions) or, outside Actions, from the git `origin` remote. It does not perform the `docker login` itself — in CI that is `docker/login-action`-equivalent (a plain `echo "$GITHUB_TOKEN" | docker login ghcr.io ...` step, since one more third-party Action was judged not worth it for a single login command); locally, a personal access token with `write:packages`. `cmd_push` (the existing, Phase 3 target — the local, unauthenticated k3d registry used by every `deploy-apply`/`helm-apply-*`) is unchanged; GHCR needed a new subcommand rather than a parameterised `REGISTRY_HOST` because GHCR needs HTTPS and prior authentication, and `cmd_push`'s registry-reachability check assumes neither.
- **Six jobs, four of them parallel.** `lint-and-test`, `secrets-scan`, `deps-audit` and `workflow-lint` need neither Docker nor each other and run concurrently; `build-scan-deploy` (`needs: [lint-and-test, secrets-scan, deps-audit, workflow-lint]`) only starts once all four pass, so the expensive job (creating a cluster, pulling a base image, downloading Trivy's vulnerability database) never runs against a change that was already going to fail a cheap check; `publish` (`needs: [build-scan-deploy]`, gated `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`) is last.
- **`build-scan-deploy` deploys only to `polaris-dev`,** not all three environments, on every push — `docs/architecture.md`'s roadmap calls for "ephemeral-cluster deploy validation", proving the chart deploys and the API works, not a full three-environment run on every commit. `staging`/`prod` get the same chart and the same templates that `dev` just proved; that is what "one chart" (ADR-23) is for.
- **`publish` re-loads the exact image `build-scan-deploy` already built, checked and scanned** (`docker save`/`docker save`'s tar uploaded as a workflow artifact, `docker load` in the `publish` job) instead of building a second time from the same commit. What reaches GHCR is byte-for-byte what passed `image-check` and `image-scan`, not a second, unverified build.
- **`doctor.sh`'s host checks (WSL2, RAM, systemd) are deliberately not part of the workflow.** `doctor.sh` answers "can *this machine* run the platform", which is a question about a developer's WSL2 laptop, not about a GitHub-hosted runner; running it in CI would just fail on WSL2-specific checks that do not apply.

Alternatives: a self-hosted runner registered on the developer's own machine, or a reverse tunnel (ngrok/Tailscale/Cloudflare Tunnel) from a GitHub-hosted runner into a laptop cluster — both rejected already in ADR-12, for the same reason (a public repository's Actions workflows are effectively untrusted input; either option hands that untrusted input a path onto a real machine). Publishing straight from the `build-scan-deploy` job instead of a separate `publish` job (simpler; rejected because it removes the "publish only follows a fully green run, on main only" gate, and would run `docker login`/have `packages: write` in a job that also runs on every pull request from a fork). Rebuilding the image a second time in `publish` instead of reusing the artifact (simpler workflow file; rejected because a second build of the same commit could theoretically produce a different image if a floating base-image tag moved in between, silently invalidating everything `image-check`/`image-scan` just verified about the first build).

Consequences: real, in the sandbox, on 2026-09-22 — `gitleaks v8.30.0` and `actionlint v1.7.12`'s Linux tarballs were downloaded from GitHub release assets and their sha256 checksums matched the project's own published checksums files before either binary was run; `pip-audit 2.10.1` and `yamllint 1.38.0` were installed from PyPI. `make ci-secrets-scan` found no leaks in the repository; `make ci-deps-audit` found no known vulnerabilities in `app/ai_service/requirements.txt`; `make ci-workflow-lint` (yamllint + actionlint, the latter running shellcheck against every `run:` block) found no issues in `.github/workflows/ci.yml` — but only after actionlint's embedded shellcheck genuinely caught a real bug during development here (SC2046, unquoted word-splitting in the image-save step), fixed before it ever reached GitHub. `make lint` and `make test` (127 static checks, up from 88 at the end of Phase 5) both passed in the sandbox and, separately, on the target machine.

Real, on GitHub Actions, on 2026-09-22 — the sandbox result above turned out to be necessary but not sufficient. The first real push (commit `f8512c7`) failed `lint-and-test`'s shellcheck step immediately, with a diagnostic that made no sense at first glance: `scripts/build/*.sh: openBinaryFile: does not exist`, as if the entire `scripts/build/` directory were missing from the checkout. It was: `.gitignore`'s unanchored `build/` pattern had matched `scripts/build/` at any depth (equivalent to `**/build/`) and silently kept `scripts/build/image.sh` out of every commit since Phase 3 — a file this project has relied on since Phase 3, verified as working every time only because local runs always read it straight off disk regardless of git tracking status. It took a genuinely independent checkout, which this project never had before GitHub Actions gave it one, to expose that. Anchoring the pattern (`/build/`, and `/dist/`/`/artifacts/`/`/.venv-ci/` for the same latent reason) and committing `scripts/build/image.sh` for the first time fixed it — and immediately surfaced a second, smaller bug it had been hiding: `tests/bootstrap/test_static.sh`'s own check for "`.gitignore` excludes `.venv-ci/`" used an exact whole-line string match, which broke the moment that line gained its new anchoring slash. Fixed by relaxing the match. Both are recorded in full in `docs/troubleshooting.md` (Phase 6). The third push, commit `48cb3a1` (run #4), passed all six jobs: `lint-and-test`, `secrets-scan`, `deps-audit` and `workflow-lint` in parallel, then `build-scan-deploy` (2m 1s — created the ephemeral k3d cluster, built the image, ran the hardened-container check, Trivy scan and SBOM generation, deployed via Helm, smoke-tested through Traefik) and finally `publish` (GHCR push, gated to `main`). This is the first time in the project's history that the image build, the ephemeral k3d deploy and the GHCR publish have run anywhere but a developer's own machine, and the first time this project's central lesson about local verification (see ADR-16, ADR-22, ADR-23 for earlier, smaller versions of the same theme) has shown up as a real, previously-invisible bug rather than a documented risk.

Revisit when: Phase 8 (a successful `publish` triggers a commit to the separate `polaris-gitops` repository instead of being the last step); Phase 15 (Cosign keyless signing joins the `publish` job; Sealed Secrets). A useful habit going forward, given what this phase found: after any change to `.gitignore`, check `git status --short` (and, for anything already suspected of being silently excluded, `git check-ignore -v <path>`) before assuming a file is tracked.

### ADR-25: Post-deploy verification (`scripts/verify/post-deploy.sh`)

Status: accepted, and fully confirmed on the target machine (2026-09-22) — including a real gap this phase's own testing found in Phase 5's chart, and its fix. A healthy `polaris-dev`/`-staging`/`-prod` all passed all six checks with genuine metrics. The first deliberate `POLARIS_MOCK_READY=false` failure-injection test did not produce a failure, though: all six checks kept passing, because (see "Consequences") the config change never actually reached any running pod — a real gap in Phase 5's chart (ADR-23), not in this script, which this script's testing is what exposed. The fix (a `checksum/config` annotation on `deployment.yaml`'s pod template) was written, its sha256 mechanism hand-verified in the sandbox first, then applied and re-tested for real: the same deliberate override now produces a genuine `FAIL rollout: ...` with a real, never-ready new pod, and reverting (after rebuilding the image for the fix's own commit) produces a clean `PASS` again with yet another distinct ReplicaSet. See `docs/troubleshooting.md`, Phase 7, for the full before/after evidence.

Context: ADR-12 decided there would be two verification loops. ADR-24 (Phase 6) built the first — an ephemeral k3d cluster inside a GitHub Actions runner, proving "the chart deploys and the API works" before a merge. The second loop, in the roadmap's own words, checks "health, API, rollout, metrics, logs, AI answer" against what is *actually running* in a cluster that persists — not a throwaway one created and destroyed inside a single CI job. That distinction matters: CI's ephemeral cluster only ever sees one deploy, so it cannot answer "is this environment healthy right now, days after the last deploy" — a question every environment covered by `make helm-apply-dev/-staging/-prod` (Phase 5) can actually be asked at any time. Phase 9/10 (Prometheus, Loki, Tempo, OpenTelemetry) and Phase 8 (Argo CD) have not been built yet, so the full end-state described in `docs/architecture.md`'s CI/CD flow diagram — Argo Rollouts querying Prometheus during a canary and deciding promote-or-rollback — is not possible yet. Building toward it honestly means implementing only the parts that do not depend on infrastructure this project has not built: rollout status, HTTP health/readiness, a real AI answer, and structured-log presence are all fully checkable today with tools already installed (`kubectl`, `curl`, `jq`); pod-level resource metrics are too, because `deploy/k3d/cluster.yaml`'s comment already notes k3s ships `metrics-server` by default and this project's cluster config does not disable it — but *judging* those metrics against a threshold is not, because nothing yet defines what "too slow" or "too many errors" means for this service in a way a script could check.

Decision:

- **A host-side script, not a Kubernetes Job**, unlike the literal "verification Job" wording in `docs/architecture.md`'s vocabulary table. A real Job would be the more production-faithful shape (see "Alternatives"), but every other phase's verification code in this project is a host script that calls `kubectl`/`curl` against the cluster, verified end to end on the target machine — the same pattern `scripts/deploy/app.sh`, `scripts/deploy/helm.sh` and even Phase 1's `scripts/bootstrap/smoke-test.sh` already use. Following it keeps Phase 7 genuinely verifiable the same way every earlier phase was, instead of adding an unverified Kubernetes Job manifest and a purpose-built container image on top of everything else in this phase.
- **Six checks, all always run, all reported together** (`RESULTS` array; `record_pass`/`record_fail`/`record_warn`), not fail-fast like `scripts/deploy/helm.sh`'s `cmd_smoke`. A smoke test answering "did the last deploy work" can reasonably stop at the first problem. A post-deploy *verification* job answering "is this environment healthy" should not — a real bad deploy is more useful to debug from a full report ("readyz is failing AND logs are empty") than from just the first symptom noticed.
- **The AI-answer check goes further than Phase 5's smoke test.** `helm-smoke-<env>` only checks that `/v1/chat`'s response has the right fields (`response`, `model`, `request_id`, `latency_ms`) — the API contract (ADR-18). This script additionally asserts `response.response` is non-empty, because the roadmap explicitly names "AI answer" as something Phase 7 should check, not just "the endpoint responded".
- **Metrics are advisory, never a failure.** `check_metrics` only ever calls `record_warn`, and `tests/bootstrap/test_static.sh` (check 46) enforces that at the code level, not just by convention. `kubectl top pod` genuinely queries k3s's real, built-in metrics-server — this is not a stub — but *presence* of a number is all that is checked; there is no "p95 latency > 500ms is a bad deploy" logic here, because that logic belongs to Argo Rollouts' `AnalysisTemplate`s once Prometheus exists to query (Phase 9/10, then Phase 18).
- **Logs check reuses Phase 3's JSON-structure bar** (ADR-20: every log line parses as JSON), now applied to `kubectl logs` output from a live cluster instead of `docker logs` from a single container (Phase 3's `image-check`) — the same underlying guarantee (ADR-20's field allow-list, no prompt leakage), checked in a new place.
- **A deliberate-failure test is part of Phase 7's own testing, not just the happy path.** The chart's `config.POLARIS_MOCK_READY` (`values.yaml`, wired through Phase 2's `ModelBackend` mock) can be overridden with `--set config.POLARIS_MOCK_READY=false` to force `/readyz` to genuinely fail without touching any code — the guide's Testing section uses this to prove `post-deploy.sh` actually detects and reports a bad deploy, then reverts it and proves a healthy deploy passes clean. A verification job that has only ever been run against a healthy deploy has not actually been tested.

Alternatives: a real Kubernetes `Job` (or `CronJob`, for periodic re-verification) running the same checks from inside the cluster, using the cluster's own DNS instead of the host's Traefik ingress port. This is the more honest production equivalent — many real CD tools implement exactly this — and is documented as such (Phase 7 guide, "Production equivalent"), but building and verifying a purpose-built container image and the RBAC a Job would need to call `kubectl rollout status` about its own Deployment was judged not worth the added, harder-to-verify surface area for what this phase needs to prove. Wiring this script into Phase 6's CI workflow instead of keeping it a separate, local-only command: rejected, because ADR-12's two loops are deliberately different in scope (loop 1: cheap smoke test, ephemeral, pre-merge; loop 2: this script, broader, against a cluster that persists) — collapsing them would blur a distinction the roadmap draws on purpose.

Consequences: `scripts/verify/post-deploy.sh` (140 static checks now pass, up from 127 at the end of Phase 6) is genuinely shellchecked and reviewed, and its logic — rollout/health/readyz/AI-answer/logs checks that always run and report together, metrics that can only warn — is enforced by `tests/bootstrap/test_static.sh` itself, not just described here.

Its first real run, on the target machine on 2026-09-22, mostly went as designed: `make helm-apply-dev` plus `make verify-dev` reported all six checks `PASS` against a healthy release, with real `kubectl top pod` metrics, and `verify-staging`/`verify-prod` did the same for their own releases. The deliberate-failure test did not: after `helm upgrade --set config.POLARIS_MOCK_READY=false --namespace polaris-dev` (no `--wait`, on purpose, to inspect the in-progress state) reported a successful upgrade (REVISION incremented), `make verify-dev` run immediately after still reported all six checks `PASS` — including `readyz`. The pod names and `kubectl top pod` output in that run were byte-for-byte identical to the healthy run before it (`ai-service-6f7c56f7c9-bvdwk`/`-svltx`), which is the tell: no new pod was ever created, so nothing about the running system had actually changed for the script to catch. This traced back to a genuine gap in Phase 5's chart, not this script — see the entry in ADR-23's Consequences and `docs/troubleshooting.md`, Phase 7, for the full diagnosis.

The fix (a `checksum/config` annotation on `deployment.yaml`'s pod template, computed from `configmap.yaml`'s rendered content, plus static check 50 enforcing its presence) was written, its core mechanism hand-verified in the sandbox first (since no working `helm` binary exists there — `get.helm.sh` unreachable, the same gap ADR-23's "Context" already documents), committed as `b3af03d`, and then confirmed for real on the target machine the same day. The same deliberate `--set config.POLARIS_MOCK_READY=false` override, run against the fixed chart, produced a genuine `FAIL rollout: Waiting for deployment "ai-service" rollout to finish: 1 out of 2 new replicas have been updated...`, with a real third pod (`ai-service-75858d46dd-m5wz4`, a new ReplicaSet the old chart would never have created) that never reached Ready. `healthz`/`readyz`/`ai-answer` stayed `PASS` throughout that run — not a bug, but the exact "old healthy pods keep serving traffic during a stuck rolling update" scenario the Phase 7 guide's own "read this first" note called out in advance, and precisely why the rollout check is a separate, independent signal rather than "ask the service if it's fine". Reverting required rebuilding and pushing the image for the fix's own commit first (`scripts/deploy/helm.sh` ties the image tag to the current git SHA, so a brand-new commit's image does not exist in the registry until built — a real, minor friction point now recorded in `docs/troubleshooting.md`, Phase 7); once done, `make helm-apply-dev` plus `make verify-dev` reported a clean `PASS` again, with a fourth, distinct ReplicaSet hash (`ai-service-56cc8988fd-*`), closing the loop.

Revisit when: Phase 9/10 (Prometheus makes a real metrics check with an actual threshold possible, replacing the advisory `kubectl top pod` check); Phase 18 (Argo Rollouts' `AnalysisTemplate`s take over the promote/rollback decision — at that point this script's checks are candidates for what an `AnalysisTemplate` queries, not a replacement for it).

### ADR-26: GitOps with Argo CD (`polaris-gitops`, `scripts/bootstrap/argocd.sh`)

Status: accepted, and fully verified on the target machine, 2026-09-23. Written and shellchecked in the sandbox first, then run for real end to end: `polaris-gitops` created and pushed to GitHub, `make argocd-install` (a real client-side-apply CRD-size bug found and fixed, see `docs/troubleshooting.md`), `make gitops-bootstrap`, `ai-platform-dev`/`-staging` reaching `Synced`/`Healthy` automatically with `make verify-dev`/`make verify-staging` both `PASS`, `ai-platform-prod` promoted through an explicit manual sync with `make verify-prod` `PASS` and `kubectl`'s own `status.operationState.phase` confirming `Succeeded`, and the self-heal demonstration observed live (`kubectl scale --replicas=1` reverted by Argo CD without any manual re-apply). Four real bugs were found and fixed along the way (the CRD annotation-size limit, a `bump-image-tag.sh` idempotency bug, a rollout timeout too low for this network's first image pull, and a static-check gap in `tests/bootstrap/test_static.sh` — all in `docs/troubleshooting.md`'s Phase 8 table); two things that looked like bugs turned out to be this design's guarantees working as intended once actually investigated (the git-dirty `-tag` suffix, and the async sync-operation timing race).

Context: `docs/architecture.md` (Phase 0) already decided the shape of this phase before it started — ADR-02 named Argo CD + Argo Rollouts over Flux + Flagger specifically to demonstrate something beyond existing Flux experience; ADR-08 planned a repository split at Phase 8 into `polaris-ai-platform` (application, chart, CI, docs) and `polaris-gitops` (deployment configuration only); ADR-10 named Sealed Secrets as the plan for real secrets, not yet needed; the GitOps flow diagram and principles table named "pull not push", "Git is the single source of truth", a promotion model (dev automatic, staging via PR, prod via PR with manual approval), and explicitly called for a self-heal demonstration "in Phase 8/19". This ADR records how those prior decisions were actually built, and the choices that were still open: how the two repositories' `Application`s reference each other's content, what "manual approval" means without a real CD-approval system, how the three already-Helm-managed releases (Phase 5/7) migrate to Argo CD management, and where this phase's scope deliberately stops.

Decision:

- **Argo CD installed from its pinned, checksum-verified official manifest** (`scripts/bootstrap/argocd.sh`, `versions.env`'s `ARGOCD_VERSION`/`ARGOCD_INSTALL_SHA256`), into its own `argocd` namespace — the same "pinned, verified, no sudo" bar Phase 1 set for k3d/kubectl/helm, adapted for a tool that is in-cluster resources rather than a local binary. Since Argo CD's release assets have no published checksums file the way k3d/kubectl/gitleaks/actionlint do, the manifest was downloaded once for the exact pinned tag and its sha256 committed, the same pattern `PYTHON_BASE_DIGEST`/`TRIVY_IMAGE_DIGEST` already use in this file.
- **A genuinely separate `polaris-gitops` repository** (ADR-08 realized), holding only: `bootstrap/root-app.yaml` (an app-of-apps root `Application` whose own source is this repository's `apps/` directory — the one manifest a human ever `kubectl apply`s by hand), `apps/{dev,staging,prod}-app.yaml`, and `environments/{dev,staging,prod}/image.yaml`. No application source, no Dockerfile, no CI.
- **Multi-source Helm `Application`s**, not a copy of the chart or its values. Source 1 is `polaris-ai-platform`'s `helm/ai-platform` chart, rendered with that environment's own `values-<env>.yaml` (unchanged, still owned by `polaris-ai-platform`). Source 2 is `polaris-gitops` itself, aliased `ref: values`, contributing exactly one extra values file: `environments/<env>/image.yaml`. This is the direct consequence of `helm/ai-platform/values.yaml` deliberately shipping no default `image.tag` (ADR-19) — Argo CD needed *some* source for that value, and duplicating the whole chart's values into `polaris-gitops` would have recreated the very duplication the repository split exists to avoid.
- **Per-environment sync policy as the concrete realization of the promotion table**: `dev` and `staging` use `syncPolicy.automated { prune: true, selfHeal: true }` (staging's review gate is the pull request into `polaris-gitops` main, not a second manual step on top of it); `prod` has **no automated sync policy at all**. A merge to `polaris-gitops` main updates prod's desired state immediately (Argo CD marks it `OutOfSync`), but nothing reaches the cluster until an explicit sync is triggered — the literal, working stand-in for "manual approval" this project can actually build without a CD-approval system it does not have.
- **Full namespace-recreate migration** for the three existing Helm-managed releases (`make helm-uninstall-<env>` — keeps the namespace, `helm.sh/resource-policy: keep`, ADR-23 — then `kubectl delete namespace polaris-<env>`), *before* Argo CD ever syncs that environment, rather than Argo CD's own resource-adoption flow (annotating/labelling existing resources so Argo CD recognizes them as its own without deleting them first). See "Alternatives" and the honesty caveat below.
- **`kubectl` only, never the `argocd` CLI**, for verification (`make argocd-status`, reading the `Application` CRD's `.status.sync.status`/`.status.health.status` directly) plus the already-built `make verify-dev/-staging/-prod` (Phase 7) for real application health. Port-forwarding to the web UI is documented as optional/exploratory only, never required for pass/fail verification.
- **Image-tag promotion stays a manual script** (`scripts/gitops/bump-image-tag.sh`, `make gitops-bump-<env>`), deliberately **not wired into `.github/workflows/ci.yml`** this phase (`tests/bootstrap/test_static.sh` check 58 enforces this boundary in code, not just in this paragraph). The script refuses to write a tag that is not already in the local registry (the same `need_pushed` guard `scripts/deploy/helm.sh` already has), so it cannot itself point an environment at an image that does not exist — but it is still a person running a command, not automation.
- **A self-heal demonstration is part of the guide**, per `docs/architecture.md`'s explicit callout: manually drift a `dev` resource (`kubectl -n polaris-dev scale deployment ai-service --replicas=1`) and observe `syncPolicy.automated.selfHeal: true` revert it on Argo CD's next reconciliation, without anyone re-applying anything.

Alternatives: Flux + Flagger instead of Argo CD — rejected in Phase 0 (ADR-02) specifically to add new evidence rather than repeat existing Flux experience; not revisited here. Argo CD's resource-adoption flow instead of the namespace-recreate migration above — the more production-faithful choice (a real migration with live traffic cannot simply delete a namespace), considered and rejected *for this phase's scope* because this is a disposable local environment with no traffic to protect, and the adoption dance itself (`kubectl label`/`annotate` per resource, matching Argo CD's tracking method) was already built and documented once, for a different migration, in ADR-23 — repeating it here would prove the same skill twice rather than a new one. Wiring `bump-image-tag.sh` into CI now instead of leaving it manual — rejected: the Phase 6 pipeline (ADR-24) is the one CI asset in this project that has actually run green on GitHub Actions for real, after real debugging; extending it to also push into a second repository, untested, under this phase's scope, was judged a real risk to something already working for a benefit (automation of one `make` command) that does not require it. Installing the `argocd` CLI for a friendlier verification/sync experience — rejected to avoid pinning and verifying a second heavy tool this phase when `kubectl` against the `Application` CRD already answers every pass/fail question this project needs.

Consequences: `polaris-ai-platform` gains `scripts/bootstrap/argocd.sh`, `scripts/gitops/bootstrap.sh`, `scripts/gitops/bump-image-tag.sh`, five new `Makefile` targets, and `ARGOCD_VERSION`/`ARGOCD_INSTALL_SHA256` in `versions.env`; `tests/bootstrap/test_static.sh` (166 static checks now pass, up from 140 at the end of Phase 7) enforces the rollout-wait lists match the pinned manifest's real contents, that every new `make` target routes to the right script, and that CI is not silently pulled into the manual image-promotion boundary this ADR draws. A genuinely separate `polaris-gitops` repository now exists, with its own `README.md` explaining its scope to a reader who opens it without this context. `helm/ai-platform` itself did not need to change at all — the same chart Phase 5/7 already verified is exactly what Argo CD renders, which is the point of keeping deployment orchestration and the thing being deployed decoupled.

Honesty caveat, stated plainly rather than left implicit: "prod requires manual approval" here means "prod requires a manual action" — nothing in this setup *enforces* that a human actually reviewed the diff before triggering that sync, the way a real pull-request-approval-gated deployment pipeline would. A person could run the sync command immediately after merging, unreviewed, and nothing here would stop them. This is an honest, working demonstration of the *sync-policy* half of the promotion model `docs/architecture.md` describes, not a claim that a review gate has been built — that would need either a CD system with its own approval step, or a CI job that checks for pull-request approval before allowing the sync command to run, neither of which exists in this project.

Revisit when: a later phase wires `bump-image-tag.sh`'s logic into CI (an "image promotion" job that pushes to `polaris-gitops` automatically after `build-scan-deploy` succeeds on `main`) — at that point this ADR's manual-promotion boundary should be updated alongside the code, not left describing a scope the code has outgrown; Phase 18 (Argo Rollouts replaces the plain Kubernetes rolling update `helm/ai-platform` already uses with canary/blue-green analysis, gated on Prometheus metrics once Phase 9/10 exist — at that point `syncPolicy` here likely needs to hand control to a `Rollout` resource instead of a plain `Deployment`); if this project's cluster is ever shared rather than single-tenant/local, Argo CD's default cluster-admin-capable RBAC (noted but not narrowed in this phase, see `docs/component-qa.md`) needs real scoping.

### ADR-27: Observability platform scope, rollout ordering and simplifications (kube-prometheus-stack, Loki, Tempo, OTel Collector, `ai_service` instrumentation)

Status: accepted; written and verified in the sandbox (application layer: 141 `ai_service` unit tests at 99.27 % coverage, ruff clean; platform layer: 200 static checks pass, including YAML validity for every new manifest and a byte-for-byte drift check between the dashboard JSON and its ConfigMap). **All four observability Helm releases confirmed on the target machine, 2026-09-24, across three real runs.** Run 1 got `kube-prometheus-stack` to `STATUS: deployed` on its third attempt and surfaced two real bugs (a hardcoded version string in an `ai_service` test, and a Loki `deploymentMode` chart-usage bug). Run 2, after those fixes, confirmed `kube-prometheus-stack`, Loki *and* Tempo all reaching `STATUS: deployed`, then hit a fourth real bug — a breaking chart-default change in the OTel Collector chart requiring `image.repository` to be set explicitly. Run 3, after that fix, confirmed the OTel Collector too: all four releases reached `STATUS: deployed` in a single run (all four bugs are in `docs/troubleshooting.md`'s Phase 9 section). Still unconfirmed: `ai-platform-dev`'s own rollout with `serviceMonitor`/OTLP turned on, and the Grafana dashboard showing real data.

Context: `docs/architecture.md`'s roadmap splits observability into two phases — Phase 9 ("Observability", done when Grafana shows metrics, logs, traces and the required dashboards) and Phase 10 (OpenTelemetry attribute curation, log↔trace correlation, cross-service trace propagation) — and ADR-06 already decided the shape: metrics by Prometheus scrape, traces and logs by OTLP via a Collector. This phase had to answer four things ADR-06 left open: how the FastAPI service itself gets instrumented without breaking Phase 2's existing test suite or its careful decision (ADR-20) never to log prompts; how four separate Helm charts (kube-prometheus-stack, Loki, Tempo, the OTel Collector) get installed and wired to each other without a values file with a key that turns out not to exist upstream; whether the existing `ai-platform` chart can safely turn on `ServiceMonitor` scraping in every environment at once; and how to pin chart versions for two charts that, discovered mid-phase, migrated to a new, fast-moving upstream repository.

Decision:

- **Metrics are always on, traces and logs are opt-in.** `Instrumentator().instrument(app).expose(app, "/metrics")` runs unconditionally in `setup_telemetry()` — cardinality-safe by construction (route templates and grouped 2xx/3xx/4xx/5xx status, never raw paths or codes, matching ADR-20's existing discipline against unbounded label values) and costs nothing when nobody scrapes it. OTLP traces/logs only start when `POLARIS_OTEL_ENABLED=true`, because they mean a real network call per batch to a collector that, in most of this project's environments, does not exist yet.
- **A private `CollectorRegistry()` per app instance, not `prometheus_client`'s global `REGISTRY`.** Found the hard way: with the global registry, every test's `create_app()` shared one registry, so a later test's assertions saw an earlier test's requests too, or collided outright. The same principle Phase 2 already applies to `ModelBackend` state — no shared global mutable state across app instances — extended to metrics.
- **The OTel `LoggingHandler` attaches to the `"ai_service"` logger, never the root logger.** Attaching it to root creates a real, reproducible loop: a failed OTLP export logs its own warning through Python's logging module, on a logger name the root handler would also capture, which the same handler then tries to export again. Bounded (the batch processor's queue drops the oldest entry under pressure) but wasteful and confusing to debug. Scoping to `"ai_service"` (whose child `"ai_service.access"` still propagates up into it, matching Phase 3's existing logger hierarchy) excludes third-party loggers (`httpx`, `uvicorn`, `opentelemetry.*`) from ever reaching the exporter.
- **An explicit, bounded `otel_exporter_timeout_s` (default 3.0s, capped at 10s)**, passed to both the trace and log OTLP exporters. The OTel SDK's own default export timeout is close to 10 seconds; measured for real against an unreachable collector, shutting down both providers took roughly 8 seconds combined — most of this project's `terminationGracePeriodSeconds` (15s total, 5s already spent on the existing `preStopSleepSeconds`, ADR-20). Re-measured at ~2.9s per provider with the 3s timeout in place.
- **Neither `opentelemetry.trace.set_tracer_provider()` nor `opentelemetry._logs.set_logger_provider()` is ever called.** Both are process-global, settable only once — verified for real that a second call is silently ignored with a logged warning, not an error. Since `create_app()` runs once per test (over a hundred times per test session) and, in principle, could run more than once in a real process too, a global would make every app after the first silently keep the first app's (by-then-closed) provider. `FastAPIInstrumentor.instrument_app(app, tracer_provider=...)` and `LoggingHandler(logger_provider=...)` both accept a provider directly, so the global was never needed.
- **The deprecated `opentelemetry.sdk._logs.LoggingHandler` is kept, deliberately not migrated to `opentelemetry-instrumentation-logging`'s `LoggingInstrumentor`.** Read that package's source before deciding: `LoggingInstrumentor` is itself a process-global `BaseInstrumentor`, reads the logger provider via the same global `get_logger_provider()` this ADR just avoided, and attaches to the root logger by default — reintroducing both problems above. A code comment in `telemetry.py` records this so a future phase does not "fix" the deprecation warning by reintroducing the bug it was fixed to avoid.
- **`serviceMonitor.enabled` and `config.POLARIS_OTEL_ENABLED` default to `false` in base `helm/ai-platform/values.yaml`, and only `values-dev.yaml` turns them on.** `ServiceMonitor` is a Custom Resource Definition owned by kube-prometheus-stack; if `ai-platform`'s chart renders one before that CRD exists in the cluster (wrong install order, or an environment where the observability stack was never installed), `helm upgrade`/Argo CD's sync fails outright with "no matches for kind ServiceMonitor". Rather than rely on install-order discipline being remembered correctly in three environments at once, the default is off everywhere, and this delivery proves the stack in `polaris-dev` only — the same "prove it in dev first" pattern Phase 5 already established for other risk.
- **`prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues: false`** (kube-prometheus-stack's own default is `true`), so Prometheus discovers *any* `ServiceMonitor` in the cluster, not only ones carrying a specific Helm release label. Simpler for a single-tenant local cluster; explicitly flagged here as not appropriate for a shared cluster, where an accidental `ServiceMonitor` from an unrelated release could get scraped.
- **Loki's `auth_enabled: false`.** Single-tenant simplification, same category of trade-off as the point above — the chart's own default is `true` (multi-tenant).
- **`kubeStateMetrics` stays at the chart's own default (`enabled: true`); `nodeExporter` is disabled.** Both were initially disabled for footprint, then `kubeStateMetrics` was specifically re-enabled once the dashboard design needed `kube_pod_container_status_restarts_total` — a metric only kube-state-metrics exposes, not cAdvisor/kubelet. `nodeExporter` (a heavier per-node DaemonSet, and not needed by anything this dashboard shows) stays off. A deliberate split, not a half-finished cleanup.
- **`LOKI_CHART_VERSION`/`TEMPO_CHART_VERSION` are left unpinned in `versions.env`,** unlike every other version in that file. Both charts moved from `grafana/helm-charts` to `grafana-community/helm-charts` during 2026 (Tempo 2026-01-30, Loki 2026-03-16 — both dates confirmed from that repository's own migration notices, checked 2026-09-23), and the new repository releases fast enough that three fetches of Loki's `Chart.yaml` minutes apart already disagreed on the exact version. Pinning a number here would very likely already be stale by the time anyone reads it. `scripts/bootstrap/observability.sh` installs both charts without `--version` and prints the actually-resolved version after every install, the same "empty is allowed, install still works but isn't reproducible until deliberately pinned" pattern `PYTHON_BASE_DIGEST` already established in Phase 3.

Alternatives: enabling `serviceMonitor`/OTel in every environment from the start — rejected outright once the CRD-ordering failure mode was understood; it would make `staging`/`prod` fail to deploy in any delivery where the observability stack is installed after the application chart, which is exactly the order this delivery leaves them in. Migrating to `LoggingInstrumentor` now to silence the deprecation warning — rejected after reading its source, for the reasons above; the warning is accepted as a known, understood trade-off rather than worked around blindly. Pinning Loki/Tempo to whatever version happened to resolve during this session — rejected as a form of the same "never fabricate a result" discipline this project applies to command output: a version number that was already observed to be wrong minutes later is not a fact worth writing down as if it were stable.

Consequences: `app/ai_service` gains `telemetry.py`, four new `Settings` fields (`environment`, `otel_enabled`, `otel_exporter_otlp_endpoint`, `otel_exporter_timeout_s`), five new runtime dependencies, and 11 new tests exercising the always-on/opt-in split, the logger-scoping fix, the bounded-shutdown fix, and the registry-isolation fix — each backed by a real, reproduced-then-fixed bug, not a hypothetical one. `helm/ai-platform` gains a `NetworkPolicy` ingress rule for the `observability` namespace, a gated `ServiceMonitor` template, and per-environment values that keep `staging`/`prod` untouched this phase. `deploy/platform/observability/` gains four chart-values files, a namespace manifest, a 7-panel Grafana dashboard and its ConfigMap, and `scripts/bootstrap/observability.sh` (`install`/`status`/`password`/`grafana`/`dashboard-configmap`/`uninstall`). `tests/bootstrap/test_static.sh` grows from 63 to 76 Phase-9-relevant checks (196 total), covering version-pin format, YAML validity, dashboard/ConfigMap drift, the CRD-ordering-safe defaults in all three environment values files, and that both `requirements.txt` and `pyproject.toml` agree on the five new packages.

Revisit when: `staging`/`prod` get their own observability rollout (at that point `serviceMonitorSelectorNilUsesHelmValues: false` and Loki's `auth_enabled: false` need re-evaluating for a less single-tenant setup, not just copy-pasted); a real `helm list -n observability` run on the target machine gives an actual Loki/Tempo version to pin; Phase 10 (OpenTelemetry attribute curation, log↔trace correlation, cross-service propagation — deliberately out of this phase's scope); Phase 18 (Argo Rollouts' `AnalysisTemplate`s query this Prometheus for real, threshold-based promote/rollback decisions, replacing ADR-25's advisory-only metrics check).

Addendum, 2026-09-24 (real target-machine run): the Loki chart's `deploymentMode: SingleBinary` — a documented but not functionally equivalent alias for `Monolithic` — is a reminder that "the chart's own values.yaml comment says X is the default/equivalent" is not the same guarantee as "verified by actually installing it"; the sandbox's chart-schema fetches (this ADR's own "Decision" section) confirm keys *exist*, not that every documented alias behaves identically in every validation path. `kube-prometheus-stack`'s default `OBS_ROLLOUT_TIMEOUT` needing the same 600s→900s correction Argo CD's install needed in Phase 8 (ADR-26) is the same lesson recurring for a second, different Helm chart on the same network — a useful data point that "give first-time image pulls on this network real headroom" is now a pattern, not a one-off.

Addendum 2, 2026-09-24 (second real target-machine run, same day): the OTel Collector chart's `image.repository` requirement is a third, independent instance of the same broader lesson — an upstream chart can introduce a breaking default change between the version this phase was written against and the version that actually resolves at install time, and no amount of sandbox-side "does this key exist in the chart's schema" checking catches a default that changed. Confirmed against the chart's own `UPGRADING.md` rather than guessed: as of `0.173.x`, `image.repository` is no longer defaulted to the Contrib distribution and must be set explicitly. `otel/opentelemetry-collector-k8s` was chosen (the chart maintainers' own recommendation) and cross-checked against its real component manifest to confirm every component this project's Collector config actually uses is included — not assumed from the distribution's name alone.

Addendum 3, 2026-09-24 (third real target-machine run, same day): after the `image.repository` fix, `make obs-install` completed cleanly — all four observability Helm releases (`kube-prometheus-stack`, Loki, Tempo, OTel Collector) reached `STATUS: deployed` in the same run for the first time. The install also surfaced three non-fatal `[DEPRECATION]` notices from the OTel Collector chart, auto-rewriting `otlphttp` exporter names to `otlp_http` per its own `UPGRADING.md` ("0.170.0 to 0.171.0") — not a bug, the chart's `rewriteDeprecatedComponentNames` default handles it, but `otel-collector-values.yaml` should be updated to the new name directly in a follow-up commit before the auto-rewrite is removed in a future chart release.

### ADR-28: OpenTelemetry attribute curation and log↔trace correlation (`telemetry.py`, `logging_setup.py`, `main.py`)

Status: accepted; written and verified in the sandbox, then confirmed on the target machine (2026-09-29) — 145 `ai_service` unit tests (up from 141), 98.74 % coverage, ruff clean, `make app-check`'s 95 % coverage gate passed with margin. Four new tests specifically exercise this ADR's decisions (span attribute curation, log attribute curation on the OTel path, log↔trace correlation, stdout trace-id stamping); every claim below about what an exported span or log record actually contains was confirmed by capturing it in a real (patched-exporter) test run, not read off documentation. Re-confirmed for real against a live Tempo/Loki: a `POST /v1/chat` request's root span, pulled directly from Tempo's own query API, carried exactly the eight allow-listed attributes and none of the excluded ones, and the matching `trace_id`/`span_id` were confirmed present directly in `kubectl logs` stdout output — full evidence in `docs/troubleshooting.md`'s Phase 10 section.

Context: `docs/architecture.md`'s roadmap names this phase "OpenTelemetry", done when "one request traced gateway/service/model with allow-listed attributes; logs↔traces correlated; cardinality documented". Phase 9 (ADR-27) deliberately left all three undone: the spans and logs it got flowing to Tempo/Loki carried whatever OpenTelemetry's own FastAPI/logging auto-instrumentation puts on them by default, with no curation against section 6's allow-list, and the one place log↔trace correlation already worked (via `LoggingHandler`'s own context propagation) was an unexamined side effect nobody had written a test for. A real trace pulled from Tempo during Phase 9's own target-machine testing (see `docs/troubleshooting.md`) showed exactly what "uncurated" means in practice: alongside safe fields like `http.status_code`, the span also carried `http.url`, `net.peer.ip`, `net.peer.port` and `http.user_agent` — none on the allow-list, and `net.peer.ip` specifically named on the "Never, unless explicitly justified" side of it. Cross-service trace propagation, the roadmap line's "gateway" part, is explicitly not attempted here: `ai_service` is still the only service in this project until Phase 12's gateway exists (a comment to this effect was already in `telemetry.py` before this phase started, and remains true).

Decision:

- **Span attributes are curated by a wrapping `SpanExporter` (`_FilteringSpanExporter`), not a `SpanProcessor`.** The first approach tried was the more obviously idiomatic one — a `SpanProcessor` whose `on_end()` deletes any attribute key not on the allow-list. It does not work on the pinned SDK: `Span.end()` sets `self._attributes._immutable = True` *before* calling either `_on_ending()` or `on_end()` on any registered processor, and `BoundedAttributes.__setitem__`/`__delitem__` both raise `TypeError` once that flag is set. This was found by writing and running a small standalone script against the real pinned `opentelemetry-sdk==1.44`, not by reading its source and assuming. `_FilteringSpanExporter` instead wraps the real `OTLPSpanExporter`; its `export()` receives the same already-ended, already-immutable spans, but rebuilds each one as a fresh `ReadableSpan` (a public, directly-constructible class — every field copied across except `attributes`, which gets the curated dict) before handing the list to the real exporter. Confirmed working with the same kind of standalone script before being adopted into `telemetry.py`.
- **`http.route` (the auto-instrumentation's name for the matched route template) is renamed to `endpoint`** during that same rebuild, to match `docs/architecture.md` section 6's literal wording. `http.status_code` is kept as-is; it is already spelled the way the allow-list spells it.
- **The business attributes nothing sets automatically — `tenant_id`, `request_id`, `model`, `latency_ms`, `prompt_tokens`, `completion_tokens` — are set explicitly** from `main.py`'s `/v1/chat` handler via `trace.get_current_span().set_attribute(...)`, added as a small `_set_span_attributes()` helper. Calling this unconditionally, regardless of `POLARIS_OTEL_ENABLED`, is safe and was verified directly: `opentelemetry.trace.get_current_span()` is part of `opentelemetry-api` (always installed, unlike the SDK pieces that are conditional on the setting), and its `set_attribute()` on the non-recording span returned when no real tracer is active is a confirmed no-op, not an error.
- **`_LogAttributeAllowlistFilter` reuses `logging_setup.LOG_FIELDS` — the exact same tuple Phase 9 already enforced for stdout — as a `logging.Filter` attached to the OTel `LoggingHandler`.** Before this phase, that handler read a log record's raw `extra` fields directly and had no knowledge of `LOG_FIELDS` at all: a field the stdout formatter already silently dropped (the safety net ADR-20 built specifically so a stray `extra={"prompt": ...}` never reaches a log line) would still have reached Loki over OTLP, undetected, since nothing ever exercised that path. One allow-list, enforced on both the stdout and the OTLP path, instead of two that could quietly drift apart. Confirmed with a test that deliberately logs a disallowed field directly (`logging.getLogger("ai_service").warning(..., extra={"prompt": ...})`, since no real code path in the app currently would) and asserts it never reaches the captured OTLP payload.
- **`code.file.path`/`code.function.name`/`code.line.number` are deliberately left uncurated.** `LoggingHandler._get_attributes()` adds these three after this phase's filter has already run, so they are not reachable through it at all, and — after checking — they are not application data either: standard OTel semantic-convention source-location metadata, not on the allow-list's "Never" side, and useful for finding which line produced a given log line. Named here as a deliberate scope boundary, not an oversight.
- **`trace_id`/`span_id` are stamped onto *stdout* log lines too (`TraceContextFilter` in `logging_setup.py`), not only the OTel-exported copy.** Correlation already existed from Phase 9 onward as a side effect of `LoggingHandler` reading the active OTel context — but only for the copy of a log line that reaches Loki. A developer running `kubectl logs` directly, without first going through Loki, had no way to find the matching trace. `TraceContextFilter`, attached to the existing stdout handler unconditionally in `configure_logging()`, reads `trace.get_current_span().get_span_context()` on every record and stamps both ids (formatted as lowercase hex, matching Tempo's own display format) only when that context `is_valid` — confirmed absent when OTel is disabled or no span is active, and confirmed present and matching the exported span's own trace id when one is.
- **`model_version` and `prompt_version` stay in `SPAN_ATTRIBUTE_ALLOWLIST` but are never set anywhere in this codebase.** Checked directly rather than assumed: `BackendResult` (`backends/base.py`) has no version field beyond the model name string itself, `MockBackend` has no versioning concept, and there is no prompt-template system yet for a prompt to have a version of. Fabricating a value for either would violate this project's core "never claim what was not verified" rule; leaving them unset means they simply do not appear on a span, which is the correct, honest behaviour for an allow-list entry with nothing to allow through yet.
- **`env` and `deployment_version`, the allow-list's other two names, are not curated as span attributes at all.** They already exist as `deployment.environment`/`service.version` `Resource` attributes (Phase 9), attached automatically to every span and log a provider exports. Resource attributes are set once per process, not once per request, which is exactly what `docs/architecture.md` section 9's cardinality rule means by "bounded" — there is nothing per-span to curate for either one, and treating them as span attributes too would only duplicate data already present at the resource level.

Alternatives: a `SpanProcessor`-based filter — tried first, does not work on this pinned SDK version, see above. Reformatting `OTLPSpanExporter`'s wire payload after the fact (intercepting the encoded protobuf) — rejected as needlessly low-level compared to filtering `ReadableSpan` objects, which the SDK already makes easy to reconstruct. A second, OTel-specific allow-list constant instead of reusing `logging_setup.LOG_FIELDS` — rejected: two allow-lists for the same underlying "what is safe to ship off this process" question is exactly the kind of drift this ADR exists to close. Fabricating plausible-looking `model_version`/`prompt_version` values (e.g. from `ai_service`'s own package `__version__`) — rejected outright as dishonest labeling: `__version__` is the service's version, not the model's or the prompt's, and presenting it as either would be a false attribute, not a curated one.

Consequences: `telemetry.py` gains `SPAN_ATTRIBUTE_ALLOWLIST`, `_FilteringSpanExporter`, `_LogAttributeAllowlistFilter`; `logging_setup.py` gains `TraceContextFilter` and two new `LOG_FIELDS` entries (`trace_id`, `span_id`); `main.py` gains a `_set_span_attributes()` helper and three call sites in the `/v1/chat` handler. No new runtime dependencies — everything here is built from `opentelemetry-api`/`opentelemetry-sdk`, already pinned since Phase 9. Test count: 141 → 145; coverage: 99.27 % → 98.74 % (still well above the 95 % gate — the small drop is two untested `if result.prompt_tokens is not None` branches in `main.py` that `MockBackend` never actually leaves `None`, not new untested logic). `docs/observability.md` and `docs/component-qa.md` are updated with this phase's section; `docs/architecture.md` section 6's allow-list itself is unchanged — this phase enforces it, it does not redefine it.

Revisit when: Phase 11 gives `model_version` a real source of truth once `OpenAICompatBackend` is actually used instead of the mock; a prompt-template system (not yet scheduled) gives `prompt_version` one; Phase 12 adds `ai-gateway` as a second service, at which point cross-service trace propagation (W3C `traceparent` across the gateway→`ai_service` hop) becomes the next real piece of this roadmap line, not before; if a future `opentelemetry-sdk` upgrade changes `BoundedAttributes`' immutability behaviour, re-check whether the exporter-level workaround is still needed or a processor-based one becomes viable again.

### ADR-29: Ollama as the model server, a PersistentVolumeClaim for pulled models, `baseline` (not `restricted`) Pod Security for `model-serving`, and a stricter `check_ready()`

Status: accepted; **confirmed on the target machine, 2026-09-29/30**. `app/ai_service`'s suite grew from 145 to 151 tests (98.76 % coverage, ruff clean) in the sandbox; every Kubernetes-facing piece (namespace, PVC, Deployment, Service, NetworkPolicy, `scripts/bootstrap/model-serving.sh`) was then installed for real, the model pulled for real, and a real `/v1/chat` request answered end to end, with its trace confirmed in Tempo and its logs in Loki by `trace_id`/`request_id`. Two real bugs were found and fixed during this confirmation, both re-verified live in the cluster afterward, not just committed: the k3d agent nodes cannot resolve Docker Hub directly (a DNS failure, not the tag-spelling risk this ADR originally named as unverified — fixed with a new `OLLAMA_IMAGE_REGISTRY` fallback to the local k3d registry), and a cold Ollama model load measured ~50.5s for real, prompting `POLARIS_BACKEND_TIMEOUT_S=90` and `OLLAMA_KEEP_ALIVE=-1` (a warm follow-up request then completed in ~3.4s). See `docs/troubleshooting.md`'s Phase 11 section for the full real evidence, and the Decision list below for the two confirmation-driven additions.

Context: ADR-05 (Phase 0) already chose Ollama over vLLM/Triton/NIM for the reasons restated in `docs/model-serving.md` section 4 (CPU-friendly, simple, an OpenAI-compatible API this project already had a tested client for). `docs/architecture.md` section 18's "Done when" for Phase 11: "Ollama serves a small model; service uses `OpenAICompatBackend`; serving trade-offs documented." `OpenAICompatBackend` itself has existed, fully implemented and unit-tested against a fake transport, since Phase 2 — its own docstring said plainly "it has NOT been run against a real model server yet; that happens in Phase 11." This ADR is that phase's actual decisions.

Decision:

- **Ollama runs as a plain Kubernetes manifest (`deploy/platform/model-serving/`), not a Helm chart.** There is no official Ollama Helm chart, and a single-instance server with one Deployment/Service/PVC/NetworkPolicy is exactly the case Phase 4 (ADR-23's predecessor reasoning) already established this project writes as raw YAML rather than reaching for Helm to avoid — the same judgment call, applied to a new workload instead of `ai-service` itself.
- **One replica, no `PodDisruptionBudget`.** `docs/architecture.md` section 4.3 is explicit this is a single shared instance across environments (a RAM-constraint trade-off on a local machine — a real platform would run model serving per-environment or per-tenant). A `minAvailable: 1` budget on a one-replica workload would only block every voluntary disruption outright rather than smooth one, so none is declared — a real trade-off, named rather than copied blindly from `ai-service`'s own Deployment, which does have one because it runs multiple replicas.
- **A `PersistentVolumeClaim` for pulled models — a deliberate, named exception to ADR-11's "ephemeral by design" posture.** Tempo/Loki run with no persistence because a trace or log line's value is transient by nature and cheap to regenerate; a several-hundred-MB model download is the opposite — expensive to reproduce, with exactly one correct value. `scripts/bootstrap/model-serving.sh pull-model` runs once; a pod restart re-attaches the same PVC and starts serving immediately rather than re-pulling.
- **The `model-serving` namespace enforces Pod Security `baseline`, not `restricted`** — identical reasoning to `deploy/platform/observability/namespace.yaml` (Phase 9, its own ADR-27 addendum): "restricted" was only put on `polaris-dev/-staging/-prod` after Phase 3 *verified*, on the target machine, that `ai-service`'s own image runs non-root, capability-dropped, read-only-root-filesystem under it (`make image-check`). Nothing has done the equivalent check against the upstream `ollama/ollama` image. The Deployment still requests non-root UID 1000, dropped capabilities and no privilege escalation as best-effort hardening (`readOnlyRootFilesystem` deliberately left `false` — Ollama's full set of runtime write paths beyond the model directory was not inventoried, and guessing wrong there fails the container outright). Enforcing "restricted" and being wrong would turn a diagnosable `CrashLoopBackOff` into an opaque admission rejection on a first real run — the worse failure mode. Tightening this once confirmed is a named follow-up, not silently accepted as permanent.
- **`OpenAICompatBackend.check_ready()` now verifies the configured model is actually present in the backend's `GET /models` response, not just that the endpoint answers 200.** The previous behaviour (confirmed by re-reading its own existing test, `test_check_ready_succeeds_when_the_models_endpoint_answers`, which asserted success against an *empty* model list) meant a mistyped `POLARIS_OPENAI_MODEL`, or a model that was configured but never actually pulled, would pass readiness and only surface as a 502 on the first real chat request. This is now testable because a real model server's response shape exists to define the check against: the OpenAI API's own `{"data": [{"id": "..."}, ...]}` shape, which Ollama implements. A response that does not parse into that shape raises the same "malformed" `BackendError` `generate()` already raises for a malformed chat-completion response, rather than silently passing.
- **The model: `llama3.2:1b-instruct-q4_K_M` (Meta Llama 3.2, 1B parameters, "instruct" variant, `q4_K_M` quantization, 808 MB).** Verified for real (`WebFetch` against `ollama.com/library/llama3.2/tags`, 2026-09-29) rather than assumed: eleven 1B quantizations are listed (581 MB `q2_K` through 2.5 GB `fp16`); `q4_K_M` is a size/quality midpoint, not benchmarked against the others — a named simplification. "Instruct" (not "text") because `/v1/chat` is a chat/instruct workload. A fully-qualified tag is pinned on purpose — the bare `llama3.2:1b` silently maps to whichever quantization Ollama's library treats as that tag's default, which is exactly the kind of floating reference this project's version-pinning discipline (`PYTHON_BASE_TAG`, `TRIVY_VERSION`, ...) already refuses everywhere else.
- **`OLLAMA_IMAGE_TAG=0.34.4`, pinned from a real GitHub releases page fetch** (`github.com/ollama/ollama/releases`, 2026-09-29: latest release `v0.34.4`, published 2026-09-23, no security advisories noted) **but the Docker Hub tag spelling itself (no "v" prefix) is inferred from that project's historical tag-listing pattern, not directly confirmed** — this sandbox cannot reach `hub.docker.com` (proxy-blocked, same as `ollama.com` directly) any more than it can reach a Docker daemon. Named explicitly as the one pin in this phase resolved with less certainty than `PYTHON_BASE_DIGEST`/`TRIVY_IMAGE_DIGEST`'s full digest verification. **Confirmed correct on the target machine** — the tag pulled successfully once the real blocker (DNS, next bullet) was worked around, so no correction was needed.
- **`OLLAMA_IMAGE_REGISTRY` (new, `versions.env`), a confirmed fallback to the local k3d registry (`registry.localhost:5000`) for the Ollama image.** The Docker Hub tag-spelling risk named above turned out not to be the real blocker: `kubectl describe pod` showed a DNS-resolution failure (`lookup auth.docker.io: no such host`) from the k3d agent nodes, confirmed on the target machine, 2026-09-29/30. Empty by default (the documented Docker Hub path, unmodified for a network that can reach it); set to the local registry only as this specific network's confirmed fallback — `scripts/bootstrap/model-serving.sh`'s `ollama_image()` prefixes it onto the image reference when set.
- **`OLLAMA_KEEP_ALIVE=-1` on the Deployment, and `POLARIS_BACKEND_TIMEOUT_S=90` in `values-dev.yaml` (dev-only), both confirmed by real measurement.** A cold Ollama model load measured 50,454 ms (~50.5s) for real — past the previous 30s timeout default, and a real risk on any `/v1/chat` request made after Ollama's own 5-minute idle-unload, not only on first deploy. `OLLAMA_KEEP_ALIVE=-1` keeps a pulled model resident indefinitely once loaded, so that cost is paid once per pod lifetime; `POLARIS_BACKEND_TIMEOUT_S=90` gives real margin over the measured cold number for whichever request does pay it. A warm follow-up request after both fixes completed in 3,443.9 ms (~3.4s), confirming this is a one-time load cost, not the steady-state latency.

Alternatives: vLLM (GPU-oriented, its CPU backend is materially less mature/documented — matches ADR-05's original reasoning, reconfirmed rather than revisited), Triton/NIM (need GPUs this machine does not have), a Helm chart for Ollama (an unofficial community chart exists, `otwld/ollama-helm`; rejected for the same "prefer a plain manifest for one instance" reasoning Phase 4 used for `ai-service` itself before Phase 5's Helm chart existed — adding a third-party chart dependency for one Deployment/Service/PVC is more moving parts than it saves here). Enforcing `restricted` Pod Security immediately and fixing whatever breaks — rejected: this project's own established pattern (Phase 9's observability namespace) is "verify first, tighten after," not "guess and let admission control find out."

Consequences: `openai_compat.py` gains a stricter `check_ready()`; six tests in `test_openai_compat_backend.py` changed or were added; five new files under `deploy/platform/model-serving/`; a new `scripts/bootstrap/model-serving.sh` and four new `make model-serving-*` targets; `versions.env` gains `OLLAMA_IMAGE_TAG`/`OLLAMA_MODEL`; `values-dev.yaml` gains three real `config` keys switching `polaris-dev` to the real backend; a new `docs/model-serving.md`. Test count: 145 → 151; coverage: 98.74 % → 98.76 %. No new runtime dependency in `ai_service` itself — `check_ready()`'s change is pure standard-library JSON parsing, already imported transitively via `httpx`'s own `response.json()`. Confirmed on the target machine, this ADR's own decisions above grew by two more: `versions.env` gains `OLLAMA_IMAGE_REGISTRY`; `deploy/platform/model-serving/deployment.yaml` gains `OLLAMA_KEEP_ALIVE`; `values-dev.yaml` gains `POLARIS_BACKEND_TIMEOUT_S=90`.

Revisit when: `polaris-staging`/`polaris-prod` are wired up to Ollama (would need either a second shared instance or per-environment capacity — not attempted this phase); Phase 12 potentially adds a second, gateway-facing consumer of this same Ollama instance; Phase 14 (multi-tenancy) revisits whether one shared instance across environments/tenants still holds up, or whether per-tenant quotas need per-tenant model-serving capacity; the measured ~50.5s cold-start number changes materially (a different model, different hardware) enough to revisit the 90s timeout margin.

### ADR-30: `ai-gateway` — a separate FastAPI service, in-memory per-tenant rate limit/quota, and the project's first real Kubernetes Secret

Status: accepted; **confirmed on the target machine, 2026-10-05/07.** Auth (401), tenant-mismatch
rejection (403), per-tenant rate limiting (429 with `Retry-After`, burst=20 exactly), a genuinely
successful proxied chat (200), request-id propagation, and one real cross-service Tempo trace with
correct parent/child span linkage were all confirmed against the real cluster. Two more real bugs
were found only by actually running this phase against a real cluster (a Helm `--set-string`
JSON-corruption bug, and a GitOps image-promotion script that had never been taught about the
gateway — see the two new Decision bullets below and `docs/troubleshooting.md`'s Phase 12 section
for the full detail), on top of the one sandbox bug this ADR already recorded. One genuine,
still-open limitation was also confirmed, not just theorized: `ignoreDifferences` on the Argo CD
`Application` does not actually stop `selfHeal` from reverting the gateway's real Secret back to
the chart's placeholder, tested twice with the live object confirmed correctly configured both
times (see the new Decision bullet on this below).

Context: `docs/architecture.md` section 4.1 names a dedicated **Traffic** layer (`ai-gateway`),
separate from the **Application** layer (`ai-service`), responsible for auth, per-tenant rate
limit/quota, request IDs, routing and error shaping. ADR-18 already named the gap this closes:
*"Phase 2 trusts `tenant_id` from the request body... from Phase 12/14 the gateway derives the
tenant from the API key, and a mismatching body `tenant_id` is rejected with 403."* Phase 10's own
`telemetry.py` module docstring deferred cross-service trace propagation here explicitly, since
`ai_service` was still the only service in the project. `docs/architecture.md` section 18's exact
"Done when" wording: *"Gateway with auth, per-tenant rate limit, request IDs, error handling
(streaming if practical)."*

Decision:

- **A second, independently deployable Python package (`app/gateway`), never a shared library
  with `app/ai_service`.** No Python import crosses between the two anywhere in this repo, by
  design (`docs/architecture.md` Part D) — a handful of config fields (`log_level`, `log_format`,
  `environment`, `otel_*`) are intentionally duplicated rather than shared, so a change to one
  service's config can never silently alter the other's. This mirrors `scripts/deploy/helm.sh`'s
  own stated reasoning for its own internal duplication.
- **Tenant identity is derived from the API key (`hmac.compare_digest`, constant-time), never
  trusted from the request body.** A body `tenant_id` that disagrees with the resolved tenant is
  rejected with 403 `tenant_mismatch`; a body that is missing, malformed, or has no `tenant_id`
  field at all is never rejected at the gateway — full body validation stays `ai-service`'s job,
  unchanged since Phase 2. This directly closes ADR-18's named gap.
- **Per-tenant rate limit (token bucket) and daily quota (fixed UTC calendar-day window) are
  in-memory, per-pod — explicitly labelled LOCAL/DEMONSTRATION in `ratelimit.py`'s own module
  docstring, not a hidden limitation.** `gateway.replicaCount` is deliberately `1` in this
  delivery specifically so this limitation stays visible rather than silently multiplied across
  replicas. The **production equivalent** is a Redis-backed shared limiter (e.g. a Lua-scripted
  token bucket) — named, not built; nothing here claims otherwise.
- **`ai-gateway` is a second Deployment/Service/ConfigMap/Secret/NetworkPolicy/ServiceMonitor in
  the *same* Helm chart/release as `ai-service`**, gated by `gateway.enabled` (default `false`;
  only `values-dev.yaml` sets it `true`) — the same "prove it in one environment first" pattern
  ADR-27 (`POLARIS_OTEL_ENABLED`) and ADR-29 (`POLARIS_BACKEND=openai_compat`) already established,
  rather than a second chart or a second release to manage.
- **`ai-gateway` gets its own, dedicated `app.kubernetes.io/name: ai-gateway` selector/label Helm
  helpers (`ai-platform.gatewayName`/`gatewaySelectorLabels`/`gatewayLabels`), never built on top
  of `ai-platform.name`/`selectorLabels`.** `ai-service`'s own Deployment selector
  (`app.kubernetes.io/name: ai-service`, from `values.yaml`'s `nameOverride`) is immutable on every
  already-applied release since Phase 4/5; a gateway label set that is a superset of it would make
  `helm upgrade` fail outright or make two Deployments fight over the same pods. The two name
  values cannot actually collide today, but a dedicated helper keeps that guarantee explicit and
  reviewable here rather than implicit in a `values.yaml` string nobody is required to keep
  distinct.
- **The API-key→tenant map (`GATEWAY_API_KEYS_JSON`) is this project's first real Kubernetes
  `Secret`.** Applied via a direct `helm upgrade --install` for dev only, deliberately **bypassing
  GitOps (Argo CD)** so a cleartext key is never committed to the separate `polaris-gitops`
  repository — the same reasoning Phase 11 used for not GitOps-managing `model-serving`.
  **Not** wired into Sealed Secrets: that is Phase 15's own scope, named here as a gap rather than
  faked.
- **Cross-service OTel trace propagation via `opentelemetry-instrumentation-httpx`'s
  `instrument_client(client)`/`uninstrument_client(client)`, not the global `instrument()`/
  `uninstrument()` form.** The global form patches `httpx._transports.default.{HTTPTransport,
  AsyncHTTPTransport}` at the class level, which `httpx.MockTransport` (used by every fake upstream
  in this phase's own test suite) never goes through — confirmed by reading the installed
  library's source after the global form's own test failed outright. The per-client form is not
  just a test-compatibility fix: it instruments only the one `httpx.AsyncClient` the gateway itself
  constructs, directly addressing the "process-global instrumentation" concern
  `ai_service/requirements.txt`'s own comment gives for why this instrumentor was left out of
  `ai_service` entirely.
- **`x-api-key` is stripped before forwarding to `ai-service`.** The gateway's own credential —
  the thing that proves tenant identity — must never reach the upstream service, which has no
  business seeing it.
- **`--set-file`, not `--set-string`, for `gateway.apiKeysJson`, confirmed necessary by a real
  bug.** Helm's `--set`/`--set-string` strvals mini-language parses its argument as its own small
  grammar; a raw JSON blob's unescaped `{`, `}`, `"`, `:` are structural to that grammar, not
  passed through literally — confirmed directly by decoding the live Secret and finding
  `["sk-...": "demo"]` instead of `{"sk-...": "demo"}`, and by the gateway's own pydantic
  validator rejecting the corrupted value with a real `ValidationError` on every request.
  `scripts/deploy/helm.sh`'s `gateway_api_keys_json_for()` now returns a file path (with a
  `mktemp`-based `"{}"` fallback) instead of file content, and the call site uses `--set-file`,
  which passes a file's bytes through untouched.
- **`scripts/gitops/bump-image-tag.sh` gained gateway-awareness, confirmed necessary by a real
  bug.** Argo CD's own render of `ai-platform-dev` failed outright
  (`gateway.image.tag is required`) because this script, written for Phase 8 before the gateway
  existed, only ever wrote `ai-service`'s own tag into `environments/<env>/image.yaml`. It now
  also writes a `gateway: {image: {...}}` block, gated on the same `gateway_enabled_for()` check
  `scripts/deploy/helm.sh` already uses, so an environment with the gateway off is unaffected.
- **`ignoreDifferences` on the Argo CD `Application`, confirmed NOT sufficient to protect the
  gateway's Secret from `selfHeal`.** `apps/dev-app.yaml` carries a `jsonPointers: [/data,
  /stringData]` entry for `ai-gateway-api-keys`, intended to let the chart's `"{}"` placeholder
  and the real, directly-applied Secret coexist. Tested twice, independently, on the real
  cluster: the entry is genuinely present on the live `Application` object's `spec`, `status`,
  and its `last-applied-configuration` annotation both times, and `selfHeal` still reverted the
  Secret's real content to `"{}"` regardless. This is now accepted as a real, confirmed
  limitation of this mechanism against this resource/field combination, not a configuration
  mistake to keep chasing — the durable fix remains the one this ADR already named below (Sealed
  Secrets/External Secrets Operator/Vault, Phase 15), and a temporary `syncPolicy.automated`
  pause (re-applying the real Secret, then always restoring automated sync afterward) is the
  workaround used for testing, never a permanent state.
- **Daily quota (`quota_per_day: 2000`) was deliberately not driven to real exhaustion against
  the cluster.** It shares the identical `_error_response(429, ...)` code path that per-tenant
  rate limiting already proved end-to-end on the real cluster, gated only by a different
  counter/threshold — firing 2,000 requests at an already resource-constrained target machine for
  that marginal confirmation was judged not worth it. Confirmed by code review and the sandbox's
  own unit tests only; a deliberate scope decision, named here rather than silently skipped.

Alternatives: an API gateway product (Envoy Gateway, Kong) instead of a hand-written FastAPI
service — `docs/architecture.md` section 18 explicitly scopes an Envoy Gateway evaluation as
optional/"if practical" for this phase, not required for its "Done when" bar, and a hand-written
gateway makes every one of the decisions above a reviewable, interview-explainable piece of code
rather than a product's configuration surface. Importing `ai_service`'s existing `Settings`/
schemas directly instead of duplicating a handful of fields — rejected, since it would make the
two services' configs couple silently at the Python level, the exact risk the duplication avoids.
Trusting the body `tenant_id` and only logging a mismatch — rejected: ADR-18 already named this as
unsafe, and a logged-but-allowed mismatch is not actually enforcement.

Consequences: a new `app/gateway` package (7 source modules, 7 test modules, 43 tests, 95.98 %
coverage, `ruff check`/`ruff format --check` clean); six new Helm templates
(`gateway-deployment/-service/-configmap/-secret/-networkpolicy/-servicemonitor.yaml`) plus
`_helpers.tpl`/`ingress.yaml`/`networkpolicy.yaml` changes; a new `scripts/build/gateway-image.sh`
and a full `gateway-*`/`gateway-image-*` `Makefile` target block; `scripts/deploy/helm.sh` gains
gateway-awareness in `lint`/`template`/`apply`/`logs`/`smoke` (and, confirmed necessary on the
target machine, `--set-file` instead of `--set-string` for the Secret's JSON value);
`scripts/gitops/bump-image-tag.sh` gains the same gateway-awareness for image-tag promotion,
also confirmed necessary by a real `ComparisonError` on the target machine; a new, gitignored-by-
pattern `deploy/platform/gateway/api-keys.*.local.json` (with a committed `.example.json`
template); a new `docs/gateway.md`. **Status: confirmed on the target machine, 2026-10-05/07** —
built, pushed, deployed through GitOps (`scripts/gitops/bump-image-tag.sh --push`, not the direct
`helm upgrade --install` this ADR originally assumed, since `polaris-dev` has been GitOps-managed
since Phase 8), and exercised end to end against a real `ai-service` and a real Ollama backend.
See `docs/gateway.md` section 7 and `docs/troubleshooting.md`'s Phase 12 section for the complete,
honest accounting of what was found.

Revisit when: Phase 14 (multi-tenancy) needs per-tenant-*configured* rate-limit/quota numbers
instead of one flat default for every tenant; `gateway.replicaCount` is ever raised above `1` (the
in-memory limiter stops being merely demonstrative and starts being actively wrong); Phase 15
(a real secret manager takes over `GATEWAY_API_KEYS_JSON` — confirmed necessary, not just
theorized, by the `ignoreDifferences` limitation above); streaming is added to `/v1/chat` (this
gateway's proxy would need to support SSE, not attempted this phase); the daily quota path is
ever driven to real exhaustion against a live cluster (deliberately not done this phase).

### ADR-31: Tenant-attribution counters in `ai_service`/`ai-gateway`, OpenCost for shared-resource cost, a local illustrative rate card

Status: accepted; **confirmed on the target machine, 2026-10-08.** `make finops-install` ran for
real on Darya (OpenCost `2/2 Running`, resolved to `opencost-2.5.32`, now pinned). Both gaps named
below were checked for real, not assumed: the Prometheus Service name was confirmed correct as-is;
the ServiceMonitor question needed and got a real fix, now confirmed live (real
`node_cpu_hourly_cost`/`container_cpu_allocation` series flowing — see the updated gap bullet
below). The dashboard's cost panels rendering real non-zero numbers in Grafana itself is still
the one remaining confirmation step.

Context: `docs/architecture.md` section 11 ("FinOps flow") and section 18's roadmap line for this
phase ("Tenant → requests → resources → *estimated* cost dashboard; OpenCost evaluated") specify
two cost paths that must both reach a per-tenant number: model-serving cost attributed by each
tenant's share of inference-seconds, and gateway/service cost attributed by each tenant's share
of requests — both multiplied by a **local, configurable rate card**, with every resulting panel
or exported number labelled "ESTIMATE — local, not billing data." Nothing in this project
computed a per-tenant request, token or inference-time count before this phase: Phase 9's own
`prometheus-fastapi-instrumentator` metrics are real but generic (route template and grouped
status only, never `tenant_id`) — confirmed by grepping the installed codebase for a counter
with any of those names before writing one, not assumed missing.

Decision:

- **Three new `Counter`s in `ai_service/telemetry.py` (`FinOpsMetrics`: `ai_requests_total`,
  `ai_tokens_total`, `ai_inference_seconds_total`) and one in `gateway/telemetry.py`
  (`ai_gateway_requests_total`) — the exact names `docs/architecture.md` section 11's own
  Mermaid diagram already specified before any of this code existed, not invented here.**
  Confirmed directly against `prometheus_client`'s real behaviour (a throwaway script in the
  sandbox): creating a `Counter` named `ai_requests` is what exposes it as `ai_requests_total` on
  `/metrics` — the trailing `_total` is the library's own convention, not something to spell out
  in the constructor, matching how `http_requests_total` already appears on the same endpoint.
  `tenant_id`/`model` are both already allow-listed as bounded metric labels (`docs/
  architecture.md` section 9, "a handful"); the small, fixed `outcome`/`kind` enums added here
  (3 and 2 values respectively for `ai_service`, 7 for the gateway) stay inside that same bound.
- **Registered on the SAME per-app `CollectorRegistry` the Instrumentator already uses in both
  services, never a second or the process-global default one.** This is the exact Phase 9
  regression this project already learned the hard way (a shared global registry silently
  serves only the first app instance created in a process — every test in this suite builds a
  new one); both new `test_finops_metrics.py` files assert the new counters and the generic
  `http_requests_total` metric appear together in the SAME `/metrics` response as a direct
  regression guard, not just that `.labels().inc()` was called correctly.
- **Counted on every outcome, failure included — never only on success.** `ai_service` labels a
  `backend_timeout`/`backend_error` request with `model="unknown"` (no `GenerateResult` ever
  existed to label with correctly) rather than guessing the configured model name, which would
  misattribute a failed call to a model that may not even be the one that failed. The gateway
  labels its own `unauthorized` outcome with `tenant_id="unknown"` for the same reason (no tenant
  was ever resolved) and, for `tenant_mismatch`, deliberately counts under the *API-key-resolved*
  tenant, never the attacker-claimed body `tenant_id` — counting the claimed value would let
  anyone pollute another tenant's cost series just by naming it in a request body.
- **The gateway's own counter is a genuinely separate signal from `ai_service`'s, not a
  duplicate.** `ai_service` never sees a request the gateway itself rejected (401/403/429), so
  `ai_gateway_requests_total` is the only place a per-tenant *request-share* number for the
  gateway/service's own pod cost can come from; `ai_service`'s three counters are the only place
  per-tenant *token* and *inference-second* detail exist at all, since the gateway has no way to
  know either. The dashboard (below) deliberately reads from both rather than picking one.
- **OpenCost (CNCF, free), not Kubecost**, confirmed against `docs/architecture.md` section 5's
  comparison table (Kubecost's free tier needs account registration and is limited) — installed
  via its own Helm chart into a new, dedicated `finops` namespace (`deploy/platform/finops/`),
  reading cAdvisor/kube-state-metrics data from the Phase 9 Prometheus already running (`opencost.
  prometheus.internal.*`), never a second monitoring stack. `OPENCOST_CHART_VERSION` is left
  deliberately **empty** in `versions.env`, the same "resolve for real, then pin" two-step
  already used for `LOKI_CHART_VERSION`/`TEMPO_CHART_VERSION` (Phase 9) — OpenCost's chart repo
  (`opencost.github.io/opencost-helm-chart`) is a `*.github.io` repo-index page, the same
  category of page this sandbox cannot reach that made Loki/Tempo's versions unpinnable here too.
- **A local, illustrative rate card (`opencost-values.yaml`'s `opencost.customPricing.costModel`:
  $0.03/vCPU-hr, $0.004/GB-hr, $0.0001/GB-hr storage), `customPricing.provider: custom` —
  confirmed as the documented, correct mechanism for an on-prem cluster with no cloud billing
  API to call instead** (OpenCost's own on-prem configuration docs, fetched and read for real,
  not recalled from training data). These numbers are explicitly NOT real electricity or cloud
  prices; every dashboard panel built from them carries "(ESTIMATE)" in its own title, and the
  dashboard's own `description` field and a dedicated top text panel both repeat the same
  warning, satisfying section 11's "every panel/exported number" labelling requirement two ways.
- **Tenant attribution lives entirely in Grafana PromQL (`finops-dashboard.json`), not in new
  application code or a recording rule.** Model-serving cost: `(tenant's rate(ai_inference_
  seconds_total) / total rate(ai_inference_seconds_total)) * (OpenCost's own container_cpu_
  allocation/container_memory_allocation_bytes for the model-serving namespace * the rate
  card's node_cpu_hourly_cost/node_ram_hourly_cost)`. Gateway/service cost: the identical shape,
  substituting `ai_gateway_requests_total{outcome="proxied"}` for the share and the
  `polaris-dev` namespace for the OpenCost side. `outcome="proxied"` deliberately includes every
  status code `ai_service` returned, 2xx or not — a request that reached and was answered by
  `ai_service` genuinely cost the gateway/service pods compute time regardless of the answer.
- **A notional per-1000-token showback price is documented as a formula (`docs/finops.md`), not
  built as a dashboard panel.** `docs/architecture.md` section 11 calls this "optional"; stacking
  a third division on top of two already-unverified cost numbers (see the two gaps below) was
  judged more likely to produce a confident-looking but meaningless figure than a useful one
  before either cost base is confirmed for real. Named here as a deliberate scope decision, not
  a silent gap.
- **Two things named as open, unconfirmed gaps in the sandbox delivery — both checked for real on
  the target machine, 2026-10-08**, exactly the discipline this project already applies to
  `OLLAMA_IMAGE_REGISTRY` (Phase 11) and the gateway's `ignoreDifferences` limitation (ADR-30):
  (1) `opencost-values.yaml`'s `prometheus.internal.serviceName: kube-prometheus-stack-prometheus`
  was inferred from the standard Helm `fullnameOverride` convention — `kubectl -n observability
  get svc` on the real cluster confirmed exactly that Service and port; the inference held, no
  fix needed. (2) whether Prometheus scrapes OpenCost's own cost-allocation metrics back out —
  the sandbox's best guess, from OpenCost's own docs alone, was that a *separate* chart
  (`prometheus-community/prometheus-opencost-exporter`) would be needed. `helm show values
  opencost-charts/opencost` on the real target machine proved that guess wrong: the installed
  chart has its own toggle, `opencost.metrics.serviceMonitor.enabled` (default `false`, and
  genuinely not scraped beforehand — confirmed empirically via `kubectl -n observability exec
  deploy/kube-prometheus-stack-prometheus -- wget -qO- localhost:9090/api/v1/targets | grep -i
  opencost` returning nothing). `opencost-values.yaml` now sets this to `true`; no second chart
  needed, matching the same `serviceMonitorSelector: {}` cluster-wide discovery (ADR-27) every
  other ServiceMonitor in this project already relies on. After the re-deploy, Prometheus
  Operator needed roughly a minute to reconcile the new `ServiceMonitor` before it showed up as a
  healthy target — an immediate re-check still came back empty and was not the final answer.
  Once it propagated, `serviceMonitor/finops/opencost/0` showed `up`, and real series confirmed
  flowing: `node_cpu_hourly_cost` returned `0.03` (the rate card's own `CPU` value) and
  `count(container_cpu_allocation)` returned `42`. Gap closed for good.

Alternatives: Kubecost — rejected, same reasoning as `docs/architecture.md` section 5 already
gives (free-tier registration/limits). A new, separate `finops`-only Prometheus just for
OpenCost's own exported metrics — rejected: the whole point of Phase 9's `serviceMonitorSelector:
{}` simplification (ADR-27) is that any namespace's ServiceMonitor is already discovered
cluster-wide, so a second Prometheus would only duplicate kube-state-metrics/cAdvisor scraping
for no benefit. A `Histogram` instead of `Counter` for `ai_inference_seconds_total` — rejected:
the FinOps dashboard only ever needs a rate or a ratio over a window, which a running total
already supports, and `http_request_duration_seconds` (already a Histogram, from Phase 9) is
already this project's answer to "what does an individual request's latency distribution look
like" — a second one for the same underlying number would be redundant, not complementary.

Consequences: `ai_service`'s test suite grew from 151 to 159 tests (99.21 % coverage, `ruff
check`/`ruff format --check` clean); `ai-gateway`'s grew from 43 to 51 (96.07 % coverage, same
lint/format clean) — both still above the project's 95 % coverage gate, both `make app-check`/
`make gateway-check` confirmed. A new `deploy/platform/finops/` (namespace, OpenCost values, a
seven-panel dashboard JSON + generated ConfigMap), `scripts/bootstrap/finops.sh` (install/status/
ui/dashboard-configmap/uninstall, mirroring `observability.sh`'s shape), a `finops-*` `Makefile`
target block, and a new `docs/finops.md`. **Status: confirmed on the target machine, 2026-10-08**
— `make finops-install` succeeded for real, both named gaps were checked rather than assumed, and
the `serviceMonitor.enabled` fix is confirmed live (real cost-allocation series flowing in
Prometheus). The dashboard's cost panels rendering real non-zero numbers in Grafana itself is the
one remaining confirmation step.

Revisit when: the dashboard's cost panels are opened in Grafana and confirmed non-zero against
real traffic; Phase 14 (multi-tenancy) needs these same counters sliced by more than a flat
`tenant_id` (e.g. a tenant tier or plan); the rate card needs to reflect a real cloud quote
instead of an illustrative one; a notional showback price is actually built once the cost base it
would divide by is confirmed for real.

### ADR-32: Per-tenant *configured* rate limit/quota (`TenantLimits`), three real tenant tiers, logical not hard multi-tenancy

Status: accepted; **confirmed on the target machine, 2026-10-13** (`app/gateway`'s suite grew from
51 to 64 tests, coverage 96.51 % — up from 96.07 %, still above the project's 95 % gate, `ruff
check`/`ruff format --check` clean, confirmed with `make gateway-check`). `make tenants-smoke`
against Darya produced its first real result: `acme (42) > demo (23) > globex (9)` survived
requests before each tenant's own configured burst (40/20/5) tripped a real `429` — exactly the
ordering `GATEWAY_TENANT_LIMITS_JSON` configures. Three genuine, target-machine-only bugs were
found and fixed along the way (none in this ADR's own `ratelimit.py`/`config.py` code) — full
detail in `docs/multitenancy.md` §5 and `docs/troubleshooting.md`'s Phase 14 section.

Context: ADR-30's own "Revisit when" column named this exact gap the moment Phase 12 shipped:
*"Phase 14 (multi-tenancy) needs per-tenant-configured rate-limit/quota numbers instead of one
flat default for every tenant."* `docs/architecture.md` section 18's "Done when" for this phase:
*"Three tenants with quotas, limits, attributed telemetry and cost."* Attributed telemetry and
cost are **already done** — ADR-31's `tenant_id`-labelled counters and the FinOps dashboard
already slice by tenant, and nothing about resolving a flat vs. per-tenant limit changes what a
request is labelled with. The only genuine gap left was the "quotas, limits" half: every tenant
calling through `ai-gateway` got the identical `GATEWAY_RATE_LIMIT_*`/`GATEWAY_QUOTA_*` numbers
regardless of who they were, which satisfies "three tenants" but not "three tenants *with*
quotas, limits" in any way that actually distinguishes them. `docs/architecture.md` line 674 also
pins this phase's ceiling explicitly: *"Multi-tenant concepts — Demonstrated — Logical tenancy,
not hard isolation."* No Kubernetes-level namespace-per-tenant, `ResourceQuota`, or
`NetworkPolicy` change was in scope, and none was made.

Decision:

- **A single `TenantLimits` abstraction (`gateway/ratelimit.py`), constructed once in `main.py`'s
  lifespan and shared by both `TokenBucketLimiter` and `DailyQuota`**, rather than each resolving
  tenant overrides independently. `TenantLimits.from_settings()` parses the new
  `GATEWAY_TENANT_LIMITS_JSON` once at startup; `rate_per_minute()`/`burst()`/`quota_per_day()`
  each fall back to the existing flat `GATEWAY_RATE_LIMIT_*`/`GATEWAY_QUOTA_*` defaults when a
  tenant has no entry. `TokenBucketLimiter` resolves a tenant's capacity/rate once, at bucket
  creation (a bucket's capacity cannot sensibly change mid-flight); `DailyQuota` resolves a
  tenant's limit fresh on every call (so a config change takes effect for a tenant without
  waiting for its calendar day to roll over).
- **A new, strict `field_validator` on `GATEWAY_TENANT_LIMITS_JSON`, applying ADR-23's own
  lesson: a config value that silently "looks configured" but isn't is worse than a loud
  rejection.** It rejects, not ignores: a tenant_id that fails `ai_service/schemas.py`'s own
  `TENANT_ID_PATTERN`; an override that is not a JSON object; any key other than
  `rate_limit_per_minute`/`rate_limit_burst`/`quota_per_day`; and any value that is not an
  integer within the same bounds (`ge=1`) the flat settings fields already enforce. A misspelled
  key or an out-of-range number now fails the gateway's own startup validation instead of being
  silently dropped and the tenant quietly getting the flat default forever.
- **Three real tenants, not three interchangeable `tenant_id` strings**, provisioned via
  `deploy/platform/gateway/api-keys.dev.example.json` (now three placeholder entries, up from
  one) and `values-dev.yaml`'s `GATEWAY_TENANT_LIMITS_JSON`: `demo` (the standard tier — carries
  no entry at all, so it keeps getting exactly the same flat default it always has, which is also
  what `helm-smoke`'s own existing contract check calls — zero behaviour change for it), `acme`
  (premium: 2× the standard rate/burst, 2.5× the daily quota), `globex` (trial: 1/6 the standard
  rate/burst, 1/10 the daily quota).
- **Plain `ConfigMap`, not the `Secret` `apiKeysJson` already uses.** Tier numbers are not
  credentials; `GATEWAY_TENANT_LIMITS_JSON` goes straight into `gateway.config` in both
  `values.yaml` ("{}" — every tenant gets the flat defaults, this phase's starting point) and
  `values-dev.yaml` (the real three-tier JSON, as a YAML folded block scalar `>-` so one long
  JSON string can be wrapped across source lines without breaking its validity — confirmed by
  parsing the exact folded text with `yaml.safe_load` then `json.loads` in the sandbox before
  committing it). This mirrors ADR-30's own reasoning for why `apiKeysJson` alone needed a Secret
  and `--set-file`: the distinguishing fact is "is this a credential," not "is this per-tenant."
- **A new verification script, `scripts/verify/tenant-tiers.sh`**, duplicating `helm.sh`'s own
  host/port/key resolution rather than sourcing it (ADR-22's own reasoning: a later change to one
  already-verified script must never alter another's behaviour by accident). It hammers each of
  the three tenants' `/v1/chat` through the real ingress until each one 429s, counts survivals,
  and asserts the ordering `acme > demo > globex` — the one thing this phase adds that
  `helm-smoke` does not already cover (health, auth, the chat contract). Wired in as `make
  tenants-smoke`.
- **No Kafka, no `ResourceQuota`, no per-tenant namespace.** `docs/architecture.md`'s own
  requirement-coverage matrix names a Kafka-backed usage/audit event stream as this phase's
  *production* equivalent (row: "Kafka — Documented — 14 — Usage/audit event stream in
  production") — documented in `docs/multitenancy.md`, not built, the same "name it, don't fake
  it" treatment ADR-30 already gave a Redis-backed shared limiter and Sealed Secrets. A
  Kubernetes `ResourceQuota` per tenant was not built either: this project has no
  namespace-per-tenant to attach one to, and manufacturing one would misrepresent "logical
  tenancy" as "hard isolation," the exact distinction line 674 draws.

Alternatives: a per-tenant Kubernetes namespace with its own `ResourceQuota`/`NetworkPolicy` —
rejected outright by `docs/architecture.md` line 674's own scoping, and it would multiply this
project's namespace count for a demonstration need the gateway-level change already satisfies.
Letting `GATEWAY_TENANT_LIMITS_JSON` silently ignore an unknown key or an out-of-range value
instead of rejecting it at startup — rejected per ADR-23's own lesson, repeated here rather than
re-learned. A Redis-backed shared limiter, so the in-memory limitation ADR-30 already named could
finally be closed — rejected for this phase specifically: `gateway.replicaCount` is still `1`
(ADR-30's own condition for revisiting this has not fired), so the per-pod limitation this phase
inherits is unchanged, not newly introduced, and adding a new stateful dependency to close a gap
that is not yet actually biting would be solving a problem this phase does not have.

Consequences: `app/gateway`'s suite grew from 51 to 64 tests (96.51 % coverage, up from 96.07 %,
`ruff check`/`ruff format --check` clean) — new tests for the validator (9 cases: well-formed,
object-not-list, invalid `tenant_id`, non-object override, unknown key, both out-of-bounds
directions, non-integer including `bool`, a well-formed partial override), for `TenantLimits`
itself and both limiter classes picking up its overrides, and one full HTTP end-to-end test
proving a configured override changes actual `/v1/chat` behaviour, not just a resolver function's
return value. `helm/ai-platform/values.yaml`/`values-dev.yaml` gained `GATEWAY_TENANT_LIMITS_JSON`
in `gateway.config`; `deploy/platform/gateway/api-keys.dev.example.json` grew from one placeholder
key to three. A new `scripts/verify/tenant-tiers.sh` (shellchecked clean, `make lint`) and a new
`tenants-smoke` `Makefile` target. New `docs/multitenancy.md`. **Status: confirmed on the target
machine, 2026-10-13** — `make tenants-smoke` passed with a real, trustworthy result
(`acme (42) > demo (23) > globex (9)`) after fixing three real target-machine bugs along the way:
`api-keys.dev.local.json` had never actually been edited from its placeholder content (crash-
looped the gateway); `scripts/verify/post-deploy.sh`'s `check_ai_answer()` never sent the
`x-api-key` header the gateway has required since Phase 12, unrelated to this phase's own code;
and `tenant-tiers.sh`'s own `survival_count()` hardcoded a `--max-time 10` that predated Phase
11's real (slow) model, making every survived request look like a timeout. All three are detailed
in `docs/troubleshooting.md`'s Phase 14 section, which also records a real, non-bug environmental
finding: running `verify-dev` immediately after `tenants-smoke` can trip `verify-dev`'s own
`504` while Ollama drains the burst test's backlog.

Revisit when: `gateway.replicaCount` is ever raised above `1` (ADR-30's own in-memory-limiter
condition — ADR-32 inherits it unchanged, does not newly introduce it); a real audit/usage event
stream is needed (Kafka, named here and in `docs/multitenancy.md` as the production equivalent,
not built); hard isolation (a namespace, `ResourceQuota`, or `NetworkPolicy` per tenant) is ever
actually required rather than demonstrated logically.

### ADR-33: Sealed Secrets for `GATEWAY_API_KEYS_JSON`, replacing the bypass-GitOps direct `helm upgrade`

Status: accepted; written and static-tested in the sandbox, 2026-10-13 — **confirmed working end
to end on the target machine, 2026-10-15.** The controller installed cleanly (after fixing a real
repo-URL break, Bitnami's GitHub org rename from `bitnami-labs` to `bitnami` — see
`docs/troubleshooting.md`), `make gateway-seal ENV=dev` produced real ciphertext, `helm-apply-dev`
reached `REVISION: 17`/`STATUS: deployed`, the `SealedSecret` reports `Synced: True`, and the live
`ai-gateway-api-keys` Secret decodes to the real demo/acme/globex keys — materialised by the
controller from committed ciphertext, not the old manual `kubectl apply` bypass this ADR
retires. The actual payoff is confirmed, not assumed: both `polaris-root` and `ai-platform-dev`'s
`syncPolicy.automated` are back at `{"prune":true,"selfHeal":true}` and have stayed there through
everything above — the exact setting that used to revert this Secret to the chart's `"{}"`
placeholder within minutes (ADR-30's own confirmed gap) no longer breaks anything. `make
tenants-smoke`'s `demo` tier survived 21 real, authenticated requests before its configured
`429` — proof the gateway is authenticating through the Sealed-Secrets-sourced key, not just that
the Secret object exists. Three real bugs were found and fixed along the way (the repo-URL break,
a YAML duplicate-top-level-key landmine caught before any apply, a Helm/Argo resource-adoption
annotation gap, and a genuine Helm-delete/controller-reconcile race — see `docs/troubleshooting.md`'s
Phase 15 section for the full account of each). What was done in the sandbox before any of that:
every new Helm values key was hand-verified against the chart's own real
`templates/*.yaml` and `values.yaml` (fetched from `raw.githubusercontent.com`, the one
`*.github.io`-style host this sandbox's egress proxy accepts is `raw.githubusercontent.com`
itself, not `bitnami-labs.github.io` — confirmed by a direct, failing `curl`), `kubeseal`'s own
release tarball was downloaded and sha256-verified directly (not from a nonexistent checksums.txt
— see `versions.env`'s own comment), and `tests/bootstrap/test_static.sh` plus `shellcheck`
(`make lint`) both pass with the new files included.

Context: ADR-30 named this gap the moment Phase 12 shipped (*"Not wired into Sealed Secrets: that
is Phase 15's own scope, named here as a gap rather than faked"*) and later confirmed, against the
real cluster, exactly why the gap mattered: an Argo CD `ignoreDifferences` entry on
`ai-gateway-api-keys`'s `/data`/`/stringData` fields does **not** stop `selfHeal` from reverting
the directly-applied, real Secret back to the chart's `"{}"` placeholder — tested twice,
independently, both times with the live `Application` object confirmed correctly configured.
`docs/architecture.md`'s own Phase 15 "Done when" line names "secret management" as one of this
phase's four required pieces.

Decision:

- **The sealed-secrets controller (Bitnami's chart), not External Secrets Operator or Vault** —
  `docs/architecture.md` section 17 already named Sealed Secrets as this project's intended choice
  for exactly this gap (*"the durable fix remains... Sealed Secrets/External Secrets Operator/
  Vault, Phase 15"*, ADR-30's own "Revisit when"), and it needs no external secret-store backend
  at all — the one property this project's "no paid cloud, no extra backend" constraint actually
  needs. ESO/Vault are documented as the production-equivalent alternative (see the new Consequence
  below), not built.
- **A new `sealedSecrets.enabled` chart-wide toggle, off everywhere until a real target-machine run
  proves it** — same "prove it in one environment first" pattern `gateway.enabled`/
  `serviceMonitor.enabled`/`POLARIS_OTEL_ENABLED` already established. `templates/
  gateway-secret.yaml`'s plain Secret keeps rendering whenever it is off (the Phase 12 path,
  unchanged default/fallback); a new `templates/gateway-sealedsecret.yaml` renders instead once it
  is on. The two are mutually exclusive by construction (`and gateway.enabled (not
  sealedSecrets.enabled)` vs. `and gateway.enabled sealedSecrets.enabled`), never both at once for
  the same release.
- **`gateway.apiKeysSealed` holds a SealedSecret's ciphertext directly in the values file,
  committed as-is** — safe specifically because it is ciphertext, the entire point of Sealed
  Secrets, the same "label-shaped like a secret, but not one once sealed" distinction ADR-30 drew
  for `GATEWAY_TENANT_LIMITS_JSON` the other direction (a plain `ConfigMap` because tier numbers
  are not credentials). This is what actually closes the `ignoreDifferences`/`selfHeal` gap: once
  the *committed* state is itself safe, `selfHeal` reverting to it is correct behaviour, not
  something to work around.
- **A new standalone script, `scripts/deploy/seal-gateway-secret.sh`, not a new `helm.sh`
  subcommand** — ADR-22's own reasoning: this script shares almost nothing with `helm.sh`'s lint/
  template/apply/status/logs/smoke/uninstall verbs beyond also reading the same local JSON file,
  and a later change to one must never alter the other's already-verified behaviour by accident.
  It builds the plain Secret via `kubectl create secret generic --from-file --dry-run=client`
  (never a hand-typed/shell-interpolated JSON blob — the exact risk class that corrupted
  `gateway.apiKeysJson` for real via `--set-string` in ADR-30), pipes it through a real `kubeseal`,
  and extracts the one ciphertext line with `awk`, not a new PyYAML dependency nothing else in this
  project needs.
- **`scripts/deploy/helm.sh`'s `cmd_apply` gained a `sealed_secrets_enabled_for()` check
  (duplicated from `gateway_enabled_for()`'s own awk-block-scan shape, per ADR-22) that skips the
  `--set-file gateway.apiKeysJson=...` call entirely once sealed secrets is on for that
  environment** — not merely redundant at that point, but a needless read of a real tenant/key map
  off disk for a value nothing renders any more.
- **Least-privilege RBAC for the controller itself (`rbac.clusterRole: false`, `rbac.
  namespacedRoles: true`, `additionalNamespaces: [polaris-dev, polaris-staging, polaris-prod]`),
  not the chart's own default** — confirmed by reading `templates/cluster-role.yaml`/`role.yaml`
  directly: the chart's unmodified default grants a cluster-scoped `ClusterRole` with
  create/update/delete on `secrets` in *every* namespace, and `additionalNamespaces` alone (without
  also setting `rbac.namespacedRoles`/`rbac.clusterRole`) changes nothing about that — it only adds
  `get` on specific `Namespace` objects for the controller's own `--additional-namespaces` flag.
  Both settings together are what actually swaps the cluster-wide grant for one namespaced `Role`
  per listed namespace.
- **A new `sealed-secrets` namespace, Pod Security `baseline` not `restricted`** — same
  "the chart's own defaults look restricted-compliant (confirmed by reading `values.yaml`:
  `runAsNonRoot`, `readOnlyRootFilesystem`, `capabilities.drop: [ALL]`), but that is a claim about
  what is *requested*, not a target-machine confirmation that this specific upstream image
  actually starts under it" reasoning `observability`'s and `model-serving`'s own `namespace.yaml`
  already use.

Alternatives: External Secrets Operator or Vault — both need an external secret-store backend
(a cloud secret manager, or self-hosting Vault) this project's "no paid cloud, no extra
stateful backend beyond what each phase already needs" constraint does not want; documented as the
production-equivalent mapping (`docs/architecture.md` section 14 already lists this), not built.
Leaving `GATEWAY_API_KEYS_JSON` as a plain Secret and instead trying to actually fix the
`ignoreDifferences` mechanism — rejected: ADR-30 already confirmed, twice, against the live
cluster, that the entry is correctly configured and `selfHeal` still reverts it; this is a
confirmed limitation of the mechanism itself, not a configuration mistake left to keep chasing.
Writing the SealedSecret directly with `kubectl apply` outside Helm entirely — rejected: it would
put this project's "one chart, values per environment" pattern aside for exactly the one resource
this phase is trying to make *more* GitOps-normal, not less.

Consequences: three new files (`helm/ai-platform/templates/gateway-sealedsecret.yaml`, `deploy/
platform/sealed-secrets/namespace.yaml`, `deploy/platform/sealed-secrets/sealed-secrets-values.
yaml`), a new `scripts/bootstrap/sealed-secrets.sh` (install/status/fetch-cert/uninstall, same
shape as `observability.sh`) and `scripts/deploy/seal-gateway-secret.sh` (both shellchecked
clean), five new `Makefile` targets, and a new `rbac.*`/`additionalNamespaces` block confirmed
against the chart's real templates rather than assumed. `versions.env` gains
`SEALED_SECRETS_CHART_VERSION` (deliberately left unpinned, same "resolve for real, then pin"
two-step as `LOKI_CHART_VERSION`/`OPENCOST_CHART_VERSION` before it) and a sandbox-computed (not
published-checksums-file-derived) `KUBESEAL_SHA256_AMD64`/`KUBESEAL_SHA256_ARM64`.
`scripts/bootstrap/install-tools.sh` and `scripts/lib/common.sh`'s `tool_version()` both gained
`kubeseal` support. `helm/ai-platform/templates/gateway-secret.yaml` and `scripts/deploy/
helm.sh`'s `cmd_apply` both gained a guard against double-rendering/double-reading once sealed
secrets is on. `SEALED_SECRETS_CHART_VERSION` in `versions.env`, left deliberately unpinned above,
is now pinned at `2.20.0` (appVersion `0.40.0`), read straight off the real target-machine `helm
list` output. **Status: confirmed working end to end on the target machine, 2026-10-15** — `make
sealed-secrets-install`, `make gateway-seal ENV=dev`, pasting the real ciphertext into
`values-dev.yaml`, and a real `helm-apply-dev`/Argo CD sync all done for real, with the gateway
authenticating correctly through a SealedSecret-sourced key under `selfHeal` fully re-enabled (see
Status above and `docs/troubleshooting.md`'s Phase 15 section for the four real bugs found and
fixed along the way).

Revisit when: `gateway.enabled` is ever turned on for staging/prod (the same
`additionalNamespaces`/`sealedSecrets.enabled` steps need repeating for that environment, not
automatic); a second real Secret is ever needed anywhere in this project (the same pattern, not a
new one, would apply); the `sealed-secrets` namespace is ever tightened from Pod Security
`baseline` to `restricted` (named as a deferred gap, not yet attempted).

### ADR-34: Egress NetworkPolicy default-deny for `ai-service`/`ai-gateway`, dev-only until confirmed

Status: accepted; written and static-tested in the sandbox, 2026-10-13 — **partially confirmed on
the target machine, 2026-10-15.** `helm-apply-dev`'s rollout succeeded with egress default-deny
live (`REVISION: 17`, `STATUS: deployed`) and `cmd_apply`'s own built-in "pods stayed Ready after
the NetworkPolicy was applied" check passed, and `make tenants-smoke`'s `demo` tier survived 21
real requests through `ai-service`'s configured backend over that same egress path. What is
**not yet done**: a dedicated verification pass of this ADR's own four allow-rules individually
(DNS, model-serving, the OTel Collector, and, for `ai-gateway`, `ai-service` itself) — the checks
above exercise the policy as a whole under normal operation, not each rule on its own, so a
narrowly-missed rule that happens not to be exercised by `verify-dev`/`tenants-smoke` today could
still be silently absent. See `docs/troubleshooting.md`'s Phase 15 section.

Context: `helm/ai-platform/templates/networkpolicy.yaml`'s own Phase 5/9 comments were explicit
that `policyTypes` only ever listed `"Ingress"` — egress was unrestricted from Phase 5 through
Phase 14, `values.yaml`'s own comment naming this directly (*"The Deployment's egress is already
unrestricted... so nothing extra is needed for the app to push traces/logs out"*).
`docs/architecture.md`'s Phase 15 "Done when" line names "network policies" as one of this phase's
four required pieces, alongside secret management (ADR-33), signing and an admission policy (both
still pending, this phase's remaining scope).

Decision:

- **Extend the existing default-deny objects to also cover `Egress`, rather than adding a second,
  parallel default-deny object** — Kubernetes NetworkPolicies selecting the same pods are additive
  (the same way this file's own ingress objects already combine a bare default-deny with however
  many separate allow-* objects), so putting `Egress` into `ai-service-default-deny`'s
  `policyTypes` (with no `egress:` list) switches that pod selector to deny-all-egress-by-default,
  and a new `ai-service-allow-egress` object is what adds exceptions back — never the default-deny
  object itself. `ai-gateway`'s own pods are already covered by that same object (`podSelector: {}`
  matches every pod in the namespace), so `gateway-networkpolicy.yaml` only needed its own
  `ai-gateway-allow-egress` object, not a second default-deny.
- **Four independently-named allow rules, never one combined "allow everything these two services
  need" rule** — DNS (every workload needs it, unconditionally), `model-serving` (only actually
  used when `POLARIS_BACKEND=openai_compat`), the OTel Collector (only actually used when
  `POLARIS_OTEL_ENABLED`/`GATEWAY_OTEL_ENABLED=true`), and (`ai-gateway` only) `ai-service` itself.
  An allow-rule for a destination the mock backend or OTel-disabled config never actually calls is
  a harmless no-op, not a widened attack surface — nothing on that code path ever originates the
  connection — and keeping each rule separate means a future new egress need is a reviewable
  one-line addition, not a silent widening of something already there.
- **Off by default (`networkPolicy.egress.enabled: false`), on only in `values-dev.yaml`** — the
  same "prove it in one environment first" pattern every other toggle in this chart already uses.
  Not because a real risk was found for staging/prod specifically (both run the mock backend with
  OTel off today, so neither actually needs any egress beyond DNS yet) — "no real workload needs it
  today" is a different claim from "confirmed not to break anything," and this project does not
  collapse the two.
- **`model-serving`'s own NetworkPolicy (`deploy/platform/model-serving/networkpolicy.yaml`) was
  deliberately left untouched, ingress-only** — unlike `ai-service`/`ai-gateway`, Ollama's egress
  needs span model/image *pull* time (DNS plus HTTPS to a registry, already worked around once for
  a real, confirmed DNS failure — `OLLAMA_IMAGE_REGISTRY`, `docs/troubleshooting.md` Phase 11), not
  a small, fully-enumerable allow-list the way `ai-service`'s three destinations are. Hardening that
  without first confirming exactly what pull-time egress actually requires on this cluster risked
  breaking a working, already-verified phase for a gap this ADR can name honestly instead: deferred,
  not silently done.

Alternatives: a single shared `NetworkPolicy` covering both `ai-service` and `ai-gateway`'s egress
— rejected, since `_helpers.tpl`'s own `gatewaySelectorLabels`/`selectorLabels` split (ADR-30) exists
specifically so the two Deployments' pod selectors are never combined into one object; a shared
egress policy would quietly undo that. A `NetworkPolicy` default-deny for `model-serving`'s egress
too, in this same pass — rejected for now, see the Decision bullet above; named as this ADR's own
explicit gap, not forgotten. Enabling egress hardening everywhere (including staging/prod) in one
commit, since neither actually needs any egress today — rejected: "unused today" is not this
project's bar for "confirmed safe," and every other toggle in this chart has earned a real
target-machine run in dev before going wider.

Consequences: a new `networkPolicy.egress` block in `values.yaml` (off by default) and
`values-dev.yaml` (on), a new `ai-service-allow-egress` object in `templates/networkpolicy.yaml`
and a new `ai-gateway-allow-egress` object in `templates/gateway-networkpolicy.yaml`, both gated on
the same flag. `values-dev.yaml`'s own comment on `POLARIS_BACKEND=openai_compat`'s model-serving
DNS name was updated to stop claiming egress is unconditionally unrestricted, since it no longer
is. **Status: confirmed, target machine, 2026-10-15, at the "did not break anything" level** — a
real `helm-apply-dev` (`REVISION: 17`) with egress now default-deny, `cmd_apply`'s own Ready-pods
check, and `make tenants-smoke` all passed; `make verify-dev`'s `ai-answer` check hit the
already-documented Ollama-latency `504` (a timeout, not evidence of a blocked egress rule).
**Not yet done**, and not to be confused with the above: a dedicated pass confirming each of the
four allow-rules individually, rather than only the policy's net effect under normal load.

Revisit when: a dedicated per-rule verification pass is run (the gap this ADR's own Status now
names, not a hypothetical); `model-serving`'s own egress needs are ever actually enumerated and
hardened (this ADR's own named, deferred gap); `networkPolicy.egress.enabled` is ever turned on for
staging/prod (confirm first, the same discipline this ADR itself followed for dev).

### ADR-35: Cosign keyless image signing (GitHub Actions OIDC) for the `publish` job

Status: accepted; written and shellchecked in the sandbox, 2026-10-15 — **not yet confirmed, and
the confirmation step is structurally different from every previous ADR in this project.** Every
prior "target machine" verification has meant running a command on Darya; this one needs a real
GitHub Actions run of the updated `ci.yml` on a GitHub-hosted runner, because keyless signing
needs the Actions runtime's own OIDC token issuance, which nothing local can produce. See
`docs/security/image-signing.md` §6 for the exact real sequence this implies.

Context: `docs/security/image-scan.md` has said plainly since Phase 6 that "the image is not
signature-verified or signed (cosign, Phase 15)," and `docs/architecture.md`'s own CI/CD flow
diagram and Security Controls Matrix have named Cosign keyless signing as this phase's remaining
scope since before Phase 15 session 1 started. A Trivy scan is a point-in-time statement about
known vulnerabilities in what was built; it says nothing about whether the thing a cluster later
pulls is actually the thing that was scanned, built by this project's own CI, and not tampered
with or substituted in between. Signing closes that second, separate claim.

Decision:

- **Keyless (Fulcio/Rekor, via GitHub Actions OIDC), not a stored signing key pair** — the
  alternative (`cosign generate-key-pair`, the private key held as a GitHub Actions secret)
  reintroduces exactly the class of problem this whole phase exists to close: a long-lived secret
  that must be generated, stored, rotated, and can leak. Keyless signing's trust anchor is "a
  real run of this exact repository's `ci.yml`, on `main`," verified against Sigstore's own
  public Fulcio/Rekor infrastructure — no key this project has to manage at all. `cosign sign
  --yes <digest>` is the entire signing step; `--yes` only skips an interactive confirmation
  prompt that would otherwise hang a non-interactive CI job, it does not weaken what gets
  checked.
- **Sign the exact digest `cmd_publish` just pushed, never a mutable tag** — `scripts/build/
  image.sh`'s `cmd_publish` now parses the digest out of `docker push`'s own stdout (a
  `<tag>: digest: sha256:... size: ...` line every push produces) and prints it on a dedicated,
  grep-able `GHCR_IMAGE_DIGEST=` line, rather than trusting `docker inspect --format '{{index
  .RepoDigests 0}}'`, which depends on the local daemon's bookkeeping actually being populated —
  an assumption not worth making when the whole point is a digest Cosign can trust. A tag
  (`:0.4.0-<sha>`) can be retargeted after signing; a digest cannot.
- **`id-token: write` added to the `publish` job's own `permissions` block, and nowhere else** —
  the one new permission this phase needs; only this job runs on a push to `main` and only it
  ever needs to prove this workflow's own identity to Fulcio. `build-scan-deploy` and the fast
  jobs above it are untouched.
- **`cosign` installed via this project's own `install-tools.sh --only cosign`, not the
  `sigstore/cosign-installer` marketplace action** — cosign's release DOES publish a real,
  checksums.txt-backed release (confirmed by downloading it directly, 2026-10-15, unlike
  kubeseal's own exception), so the standard k3d/gitleaks/actionlint pattern applies cleanly,
  keeping one, already-audited tool-install path for every pinned binary in this project rather
  than adding a second one, from a different supply chain, for just this tool.

Alternatives: a stored key pair — rejected, see Decision above. Signing inside `build-scan-deploy`
instead of `publish` — rejected: that job runs on every push and PR, has no GHCR credentials and
no `id-token: write`, and (per ADR-24) is deliberately scoped to "build, scan, SBOM, ephemeral-
cluster deploy," not publishing or signing anything. Using GitHub's own `actions/attest-build-
provenance` instead of Cosign directly — not evaluated in depth; Cosign was already this
project's own named choice in `docs/architecture.md` before this session started, and introducing
a second signing mechanism to compare against it was judged not worth the scope increase.

Consequences: `scripts/build/image.sh`'s `cmd_publish` gained digest-capture/printing (a real
behavior change to an already-shipped, already-used script — re-run `make lint`/`make test`
after this change, not assumed safe because "it only adds a print statement"). `versions.env`
gained `COSIGN_VERSION`/`COSIGN_SHA256_AMD64`/`COSIGN_SHA256_ARM64` (checksums read from a real
downloaded `cosign_checksums.txt`, not computed or guessed). `install-tools.sh`/`common.sh`
gained `cosign` support. `.github/workflows/ci.yml`'s `publish` job gained `id-token: write` and
two new steps. A new `scripts/verify/cosign-verify.sh` (`make cosign-verify`) lets Darya confirm
a signature independently of any CI log. **Status: not yet confirmed** — see this ADR's own
Status line above for exactly why that confirmation is sequenced differently here than for any
earlier phase.

Revisit when: the real GitHub Actions run above surfaces a bug (expected, per this project's own
established pattern); the gateway image (`ai-gateway`) is ever added to the CI publish pipeline
(it is not today — only `ai-service` is ever built-scanned-published by `ci.yml`; signing it
would follow the identical pattern, not a new one); a stored-key fallback is ever needed for a
registry or environment that cannot reach Fulcio/Rekor's public endpoints.

### ADR-36: Kyverno `ClusterPolicy` verifies Cosign signatures for `ai-service` images

Status: accepted. `kyverno-install`/`kyverno-status` confirmed on the target machine, 2026-10-15
— all four controllers (`admission`/`background`/`cleanup`/`reports`) `1/1 Running`, `RESTARTS: 0`
over a 101-minute window; `KYVERNO_CHART_VERSION` pinned to `3.9.1` from that run's own `helm
list`. See `docs/troubleshooting.md`'s session 2 section for the real install-stability finding
(a first attempt crash-looped; the second succeeded cleanly and has stayed healthy since, cause
not fully isolated — recorded honestly as "most likely a transient install-time burst", not
overclaimed). `apply-policy`/`verify-demo` are still **not** confirmed: `verify-demo` needs a
real signed digest from ADR-35's own real-signature confirmation (push → real CI run → `cosign-
verify`), which has not happened yet; `apply-policy` just hasn't been re-attempted since the
clean reinstall.

Context: a signature nobody ever checks is a claim, not an enforced guarantee. `docs/
architecture.md`'s Phase 15 "Done when" line names "admission policy" as the fourth and last of
this phase's required pieces, alongside secret management (ADR-33), network policy (ADR-34) and
signing (ADR-35). Kyverno was already this project's own named choice (`docs/architecture.md`
§579: "Kyverno policies are readable YAML").

Decision:

- **A `ClusterPolicy` with a `verifyImages` rule, keyless, scoped narrowly to `ghcr.io/<owner>/
  <repo>/ai-service` only** — never a broader glob (e.g. `*/ai-service*` or every image in
  `polaris-dev`). `polaris-dev`/`-staging`/`-prod` pull every image from `registry.localhost:
  5000/...`, the k3d cluster's own local registry, never from GHCR (true since Phase 5, unchanged
  by this session) — a broader glob would have the webhook try, and correctly fail, to verify a
  signature for images that were genuinely never signed, breaking the existing, working local
  dev pipeline on every single deploy. Scoping narrowly to the one path that is ever actually
  signed means the policy has a precise, honest claim: "nothing pulls `ghcr.io/<owner>/<repo>/
  ai-service` unsigned," not the broader, false claim "nothing unsigned runs in this cluster."
- **The policy is rendered from a `.tmpl` file and applied directly via `kubectl apply -f -` over
  stdin, never written to disk** — `scripts/bootstrap/kyverno.sh`'s `apply-policy` substitutes
  this repo's real, lowercased `owner/repo` (resolved the same way `scripts/build/image.sh`'s own
  `ghcr_owner_repo()` is, deliberately duplicated per ADR-22) into `deploy/platform/kyverno/
  policies/verify-ai-service-images.yaml.tmpl`. Phase 15 session 1's own real bug — a hand-pasted
  ciphertext value and a duplicate-top-level-YAML-key mistake in `values-dev.yaml`, both caught
  before they shipped — is exactly the class of error this avoids structurally: a resolved value
  that could go stale or get mistyped if pasted by hand simply never exists as a file to paste
  into.
- **`subject` (an exact match), not `subjectRegExp`** — a worked keyless example found during
  this session's research used a regex (`subjectRegExp: "https://github\\.com/company/.+"`), but
  this project knows its own exact repository identity at apply time, and an exact match is
  strictly tighter than a regex covering the same string for no added benefit.
- **`failureAction: Enforce`, not `Audit`** — an audit-mode policy only reports, it does not
  block, which would make `verify-demo`'s own negative case (proving a genuinely unsigned/
  nonexistent image is actually rejected, not merely logged) impossible to demonstrate.
- **`background: false`** — `verifyImages` needs the live admission request's own image-pull
  context; a background reconciliation pass has nothing to check against, the same reasoning a
  worked example found during this session's research used.
- **A dedicated `verify-demo` command, not just "apply the policy and trust it"** — two throwaway
  `Pod`s in `default`, cleaned up unconditionally: a positive case (the real signed digest ADR-35
  produced — must be admitted) and a negative case (the same real repo path, at a digest one hex
  character away from the real one — guaranteed to be a real-looking, never-pushed, never-signed
  reference, without needing to already know any actual prior unsigned tag's name — must be
  rejected by the webhook itself, not merely fail later with `ImagePullBackOff`).

Alternatives: the newer `ImageValidatingPolicy` CRD some recent Kyverno versions offer alongside
the long-standing `ClusterPolicy`/`verifyImages` mechanism — not used; this session's research
did not turn up a complete, trustworthy worked example for it the way it did for the
`ClusterPolicy` approach, and the latter remains fully supported at the pinned chart's
`appVersion` (confirmed via `docs/architecture.md`'s own research this session, 2026-10-15).
Scoping the policy to every image in `polaris-dev` instead of just `ghcr.io/.../ai-service` —
rejected, see Decision above: it would make a false claim this project cannot back up today, not
a stronger true one. OPA/Gatekeeper instead of Kyverno — not evaluated; Kyverno was already this
project's own named choice before this session started.

Consequences: a new `kyverno` namespace (`deploy/platform/kyverno/namespace.yaml`, Pod Security
`baseline`, same reasoning as every other platform namespace in this project), `kyverno-values.
yaml` (four controllers, `replicas: 1` each for a single-node dev cluster, every other key at the
chart's own confirmed-real default), the policy template above, a new `scripts/bootstrap/
kyverno.sh` (install/status/apply-policy/verify-demo/uninstall, same shape as `sealed-secrets.
sh`), five new `Makefile` targets, and `versions.env` gained `KYVERNO_HELM_REPO`/
`KYVERNO_CHART_VERSION` (the latter deliberately left unpinned, same two-step as
`SEALED_SECRETS_CHART_VERSION`/`OPENCOST_CHART_VERSION` before it — resolve for real on the
target machine, pin in a deliberate follow-up commit). **Status: not yet confirmed** — and, per
`docs/security/admission-policy.md` §3, even a full target-machine confirmation of install +
`verify-demo` would still only prove the mechanism works against a direct GHCR reference, not
that it covers anything `polaris-dev` itself actually runs — named as this ADR's own real,
current scope limit, not glossed over.

Revisit when: the target-machine run surfaces a real bug (expected, per this project's own
established pattern); `KYVERNO_CHART_VERSION` is pinned once a real install resolves it (the
same follow-up commit pattern `SEALED_SECRETS_CHART_VERSION` already went through); and, the
larger one — `polaris-dev`'s own deployment is ever changed to pull the real, signed GHCR image
instead of a local-registry retag, which is what would actually let this policy enforce against
a real, running workload rather than only a demonstration `Pod`. That is a materially bigger
change to this project's "build and iterate with zero network dependency" deploy model than
anything else in Phase 15, and is deliberately not attempted inside this already-large session.

### ADR-37: AI governance — a Git-based manifest, not MLflow; model/prompt/deployment/config
version on every response, log, span and the Prometheus info metric

Status: accepted, **confirmed on the target machine (Darya), 2026-10-29**. Unit-tested in the
sandbox first (183 tests, `ai_service`'s coverage gate of 95% exceeded at 99.32%, `ruff check`/
`ruff format --check` clean), then confirmed for real: after a real image rebuild/push and a
GitOps tag bump (a config-only ConfigMap change rolls out automatically via the existing
`checksum/config` annotation, but the governance code itself needed a new image — see
`docs/troubleshooting.md`'s Phase 16 section for the exact sequence and two real gotchas hit
along the way), `GET /v1/meta` and `GET /metrics`'s `ai_service_governance_info` both showed
real, non-"unset" values on a live Pod (`deployment_version=0.4.0-4531878b9203`,
`config_version=0.3.0`, matching the exact deployed image tag and `Chart.yaml` version). This
closes the one gap left open when this ADR was first written.

Context: `docs/architecture.md`'s Phase 0 roadmap names Phase 16's "Done when" line explicitly —
"Every response and signal carries model/prompt/deployment/config version; registry manifest;
MLflow decision recorded" — and section A4 names the fork this ADR has to resolve: "**MLflow**
(SQLite backend) as a real model/run registry instead of a Git-based manifest." Section 6's data-
flow table had already, in Phase 0, gone further than just naming the fork: it specified the
governance record's own delivery shape ("Manifest in Git + a `/v1/meta` endpoint + a Prometheus
info metric") and its trace/log attribute allow-list already reserved `model_version`/
`prompt_version` as span attributes and `env`/`deployment_version` as Resource attributes —
`ai_service/telemetry.py`'s `SPAN_ATTRIBUTE_ALLOWLIST` carried both names with a comment
("never set yet") since Phase 10, three phases before this one. This ADR is substantially an
implementation of an already-written specification, not a new design from scratch — a real
instance of "a plan written early can still be right once its moment arrives," worth naming
because it is not how every phase in this project has gone (Phase 8's gitops extraction and
Phase 15's Kyverno `type: SigstoreBundle` fix both deviated from their own earlier plans for
good, documented reasons; this one did not need to).

Decision:

- **A Git-based manifest (`ai_service/governance/manifest.json`), not MLflow.** This project's
  own established bias against adding infrastructure without a concrete, proven need —
  OpenCost over Kubecost (ADR-31), Sealed Secrets over Vault (ADR-33), a custom gateway over
  Envoy/Kong/LiteLLM (`docs/architecture.md` section 17) — applies here exactly as it did there.
  MLflow means a second persistent service (its own tracking server plus a SQLite/Postgres
  backend, a new namespace, a new Helm release to operate and keep healthy) for a project that
  has exactly one model per backend and one prompt template. A few git-tracked files already
  give everything a model/prompt registry needs to prove at this scale: a single declared
  source of truth, versioned by git history itself, diffable in a pull request, and comparable
  against what actually answered a request. `docs/architecture.md` A4 already named MLflow as
  something to adopt "only after Tier 2 works" and explicitly as "instead of a Git-based
  manifest" — the fork this phase was always going to have to resolve, not a new tradeoff
  invented here.
- **JSON, not YAML, for the manifest file itself.** PyYAML is not a dependency of `ai_service`
  anywhere else (confirmed: `grep -i yaml requirements.txt requirements-dev.txt` found nothing),
  and the stdlib `json` module does the exact same job for one small, machine-read file without
  adding a new pinned dependency and a new package for Trivy's SBOM/CVE scan to carry forever —
  the same "every dependency needs a purpose" discipline already applied to keeping `pip`
  itself out of the runtime image (`Dockerfile`) and refusing to compile anything from source
  (`--only-binary=:all:`).
- **The manifest and its one prompt-template file ship inside the `ai_service` Python package
  (`app/ai_service/src/ai_service/governance/`), not a top-level `governance/` directory** —
  `docs/architecture.md`'s Part B file tree sketch (written in Phase 0, before this constraint
  was concretely known) shows a top-level `governance/`, but `app/ai_service/Dockerfile`'s build
  context is scoped to `app/ai_service` (its own comment: "Build context is this directory"),
  so a repository-root directory would never reach the built image at all — the manifest would
  exist in git but not in the thing that actually runs. Packaging it as `[tool.setuptools.
  package-data]` and loading it with `importlib.resources` at startup means `pip install .` (the
  Dockerfile's own build step, unchanged) ships it automatically; confirmed for real in the
  sandbox against both an editable install and a real, non-editable wheel install into a fresh
  virtual environment (the latter is what the Dockerfile actually does) — the manifest and
  prompt file land in `site-packages/ai_service/governance/` either way, not assumed to work
  from the package-data declaration alone.
- **The declared model version is compared, on every request, against what the backend itself
  self-reports answering with (`BackendResult.model`)** — `main.py`'s `chat()` handler logs a
  `WARNING`-level "governance drift detected" line (never raises; a mismatch should not turn a
  successful answer into a failed request) whenever they differ. This is the actual point of
  having a model registry at all, not decoration: it is what lets a different quantization
  pulled, a model swapped, or a prompt edited without the manifest being updated to match, be
  *visible*, the exact verb `docs/architecture.md`'s own project thesis uses for what this
  platform's job is.
- **A real "system" role message, not text concatenated into the user turn.** The governance
  manifest's versioned prompt template is only a real, meaningful "prompt version" if it
  actually changes what the model is told — `ModelBackend.generate()` gained an optional
  `system_prompt: str | None = None` parameter (`base.py`), used by `OpenAICompatBackend` as a
  genuine leading `{"role": "system", ...}` chat message (the OpenAI chat-completions shape
  Ollama/vLLM also speak already has a dedicated role for exactly this) and accepted-but-
  deliberately-unused by `MockBackend` (its answers are a deterministic lookup over the user
  prompt alone, documented in its own module docstring — forcing it to pretend otherwise would
  be dishonest, not thorough).
- **`model_version`/`prompt_version` are per-span attributes (Phase 10's reservation, now
  filled); `deployment_version` is a Resource attribute, not a span one; `config_version` is in
  neither.** `telemetry.py`'s own Phase 10 comment already drew this line before this phase
  existed: "`env`/`deployment_version`... are not span attributes at all... Resource attributes
  set once" — unlike `model_version`/`prompt_version`, which genuinely could change request to
  request if a future phase ever made them dynamic, `deployment_version` is a per-process fact.
  `config_version` is new to this phase and was deliberately kept out of `docs/architecture.md`
  section 6's own allow-list (fixed in Phase 0, before `config_version` existed as a separate
  concept from `deployment_version`) rather than added to a list a different phase already
  closed: a Helm chart's schema version changes far less often than a deployment does, so
  tracing it per-request would add a label that is almost always identical to the last one,
  for no benefit the response body/`/v1/meta` field does not already give.
- **`POLARIS_CONFIG_VERSION` reuses `Chart.yaml`'s own `version` field** (its own comment:
  "bump on any template/values-shape change") **rather than computing a second, independently-
  maintained config-schema number.** A second number that could drift from the first is exactly
  the class of bug this project's own discipline exists to avoid (Phase 15 session 1's hand-
  pasted-ciphertext/duplicate-YAML-key bugs, both named in `docs/troubleshooting.md`). Wiring
  this up surfaced an honest, pre-existing gap: `Chart.yaml`'s version had not actually been
  bumped for Phases 12-15's own real shape changes (gateway templates, FinOps counters, tenant-
  limits JSON, Sealed Secrets/egress NetworkPolicy additions) — found only while writing this
  ADR, named in `Chart.yaml`'s own comment rather than silently corrected, and not reconstructed
  retroactively (there is no reliable way to assign the right historical value to each of those
  four phases after the fact); the version bump this phase makes (`0.2.0` → `0.3.0`) is honestly
  only "config shape as of Phase 16," resuming the discipline from here rather than claiming to
  repair the gap in the past.
- **`POLARIS_DEPLOYMENT_VERSION` is `.Values.image.tag`, never `Chart.yaml`'s own `appVersion`**
  — `Chart.yaml`'s own comment already warns `appVersion` "can drift from [the real image tag]
  and does not drive it; do not read it as the deployed version," so this ADR does not.
- **Both new `POLARIS_*` keys are added directly inside `templates/configmap.yaml`'s `data:`
  block, not routed through the flat `values.yaml` `config:` map** every other `POLARIS_*`
  setting uses. Both are derived from chart/release context (`.Values.image.tag`, `.Chart.
  Version`), not a static per-environment value a person would tune in `values-<env>.yaml`, so
  there is nothing for that map to hold for either one — and no circularity problem a self-
  referencing checksum of the ConfigMap's own rendered content would otherwise create.

Alternatives: MLflow — rejected for now, see Decision above; this ADR's own "Revisit when" names
the condition that would reopen it. A second, project-specific OTel Resource namespace prefix
(e.g. `polaris.deployment_version` instead of the bare `deployment_version` this ADR uses) —
not used, because `docs/architecture.md` section 6's allow-list already fixed the literal,
undotted name in Phase 0, and matching it exactly was judged more valuable than conforming to
OTel's own semantic-convention dotting style for a single project-specific key. Computing
`config_version` as a hash of the rendered ConfigMap (the mechanism `deployment.yaml`'s existing
`checksum/config` annotation already uses for forcing rollouts) — not used: the ConfigMap would
need to hash its own still-being-rendered content, which Helm's templating cannot do, and
reusing `Chart.yaml`'s own version field was already available with no such problem.

Consequences: `ai_service/governance/` (a new subpackage: `__init__.py`'s loader/validation,
`manifest.json`, `prompts/v1-system.txt`), a new `[tool.setuptools.package-data]` entry in
`pyproject.toml`, two new `Settings` fields (`deployment_version`/`config_version`, both
defaulting to the sentinel `"unset"` outside Helm), `ModelBackend.generate()`'s signature gaining
`system_prompt` (and every implementation/fake updated to match), four new `ChatResponse` fields
and a new `MetaResponse`/`GET /v1/meta` endpoint, two new `LOG_FIELDS`/`SPAN_ATTRIBUTE_ALLOWLIST`
entries actually being set for the first time since Phase 10 reserved them, a new
`ai_service_governance_info` Prometheus Gauge, two new `templates/configmap.yaml` keys, and
`Chart.yaml`'s version bump (with its own honestly-named gap, see Decision above). 42 new/
changed tests (`test_governance.py` is new; `test_chat_api.py`, `test_mock_backend.py`,
`test_openai_compat_backend.py`, `test_telemetry.py`, `test_finops_metrics.py`, `tests/fakes.py`
all touched) keep the service's own coverage gate at 99.32%, well above the 95% floor.

Revisit when: a second model or a second prompt template is ever genuinely in play at once (A/B
testing a prompt, comparing two quantizations side by side) — the point at which a Git-based
manifest's "one declared entry per backend" shape stops being enough and MLflow's actual run-
tracking/comparison features would earn their operational cost; or Phase 17 (AI evaluation)
needs to join evaluation scores to a specific prompt/model version, which may be the real forcing
function this project's own roadmap already anticipates MLflow for. Also revisit once the
target-machine confirmation above actually happens — the same "real cluster is the only real
proof" discipline every earlier Kubernetes-facing phase in this project has followed.

### ADR-38: AI evaluation — a custom harness + golden dataset, not Langfuse; a Prometheus
Pushgateway to carry batch eval scores, tagged with Phase 16's declared model/prompt version

Status: accepted, confirmed on the target machine (Darya), 2026-10-29. `make pushgateway-install`
really deployed `prometheus-pushgateway-3.10.0`; a real `make eval-run` against the Ollama-backed
`polaris-dev` deployment scored `mean_score: 0.0625` (an honest, non-perfect number, exactly as
expected for a real model against a keyword-exact check); `polaris_eval_score` showed up in
Prometheus with the pushed `job="polaris_eval"` label intact, confirming `honorLabels: true`
actually does what §Decision claims. See `docs/ai-evaluation.md` §5-§6 for the full real output.

Context: `docs/architecture.md`'s Phase 0 roadmap names Phase 17's "Done when" line explicitly —
"Golden dataset, evaluation scores tracked per prompt/model version, shown next to technical
dashboards" — and section A4 names Langfuse self-hosted as the one "optional advanced feature"
left open for this phase ("heavy: Postgres + ClickHouse + Redis"), with section 15's technology-
selection table independently naming the same fork again ("AI evaluation | Custom harness +
golden dataset (Langfuse optional)") and section 16's comparison table adding a third name,
Arize Phoenix, as "a lighter option to evaluate" once there is "enough RAM after Tier 2." Section
9's SLI table had already, in Phase 0, specified the exact metric this phase has to produce:
"AI quality (Phase 17) | mean evaluation score on the golden dataset | ≥ baseline − tolerance" —
and named it as a future input to Argo Rollouts analysis ("later eval score," section 8), which
this ADR deliberately does not wire up yet (see Consequences).

Decision:

- **A custom harness + a git-tracked golden dataset, not Langfuse, and Phoenix not evaluated
  either.** This project's own established bias against adding infrastructure without a
  concrete, proven need — OpenCost over Kubecost (ADR-31), Sealed Secrets over Vault (ADR-33), a
  Git-based manifest over MLflow (ADR-37) — applies here exactly as it did there. Langfuse
  self-hosted needs Postgres, ClickHouse, Redis and object storage (`docs/architecture.md`
  section 16's own line), which is disproportionate to what "Done when" actually asks for: a
  golden dataset and a tracked score, not full LLM-tracing/human-review tooling. Phoenix is
  named as lighter, but this project has exactly one golden dataset and no second team member to
  review traces with, so there is no concrete need driving its evaluation either — left
  genuinely untried rather than quietly ruled out, see Alternatives/Revisit when.
- **JSON for the golden dataset (`eval/golden_dataset.json`), matching `ai_service/governance/
  manifest.json`'s own precedent (ADR-37)** — one more small, git-tracked, machine-read
  declarative file, kept in the same format as every other one in this project rather than
  introducing YAML (and a new PyYAML dependency) for this one file alone.
- **Keyword-presence scoring, not semantic similarity or an LLM-as-judge.** Each dataset item
  carries `expected_keywords: list[str]`; a response's score is the fraction of those keywords
  present as a case-insensitive substring, and a run's overall score is the mean across items —
  deliberately the same wording as the SLI table's "mean evaluation score on the golden
  dataset." An embedding-similarity metric would add a new model dependency (another thing to
  download, version and justify); an LLM-as-judge would add a second model call per item whose
  own correctness nobody is evaluating — the "who checks the checker" problem, not a solved one
  at this project's scale. Keyword presence is the same style of check `test_mock_backend.py`
  has used since Phase 2 (`"smallest deployable unit" in result.text`), now run against real,
  non-deterministic model output instead of `MockBackend`'s fixed strings.
- **One golden dataset, run against either backend.** The dataset's prompts are drawn from
  `MockBackend`'s own existing known-topic lookup (Pods, Deployments, Services, namespaces) —
  reusing real, already-curated prompt/keyword pairs rather than inventing a second set — so a
  run against `MockBackend` is a deterministic regression check (expected to score at or near
  1.0 forever, a canary for the harness itself breaking) while a run against `OpenAICompatBackend`
  is the actually interesting, non-deterministic measurement.
- **A Prometheus Pushgateway, not a write-endpoint added to `ai_service`.** "Evaluation scores
  tracked per prompt/model version" means a value that persists between Prometheus scrapes even
  though the harness that produces it is not a continuously-running, scrapeable process — this
  is precisely the one case Prometheus's own documentation names the Pushgateway for ("exposing
  metrics from batch jobs"), not the general-purpose relay anti-pattern it is in every other
  case. The alternative — a new authenticated `POST` endpoint on `ai_service` that an external
  harness calls to update an in-process `Gauge` — was rejected: it would add a write surface to
  the serving path that Phase 12-15's own threat model (tenant auth, rate limiting, admission
  policy) never anticipated, mixing "report an offline evaluation result" into a service whose
  job is answering chat requests. The Pushgateway is a single, genuinely lightweight, stateless
  upstream chart (`prometheus-community/prometheus-pushgateway`, the same Helm repo
  `scripts/bootstrap/observability.sh` already adds for `kube-prometheus-stack` — no second repo
  name needed) — confirmed against its real `values.yaml`: no persistent volume by default
  (`persistentVolume.enabled: false`, an `emptyDir` instead — losing pushed metrics on a restart
  is an accepted, named trade-off for a toy batch workload, not a surprise), and a
  `serviceMonitor.honorLabels` default of `true`, which turns out to already be exactly the
  setting this project needs: without it, Prometheus would overwrite the pushed `job`/`instance`
  labels with its own scrape-target labels, silently destroying the one thing distinguishing one
  eval run's pushed series from another's.
- **The harness tags every pushed score with `model_version`/`prompt_version` read from the live
  service's own `GET /v1/meta`, not hardcoded or re-derived.** This is Phase 16's governance
  record doing the job ADR-37's own "Revisit when" line anticipated ("Phase 17 ... needs to join
  evaluation scores to a specific prompt/model version") — the harness never needs its own
  separate notion of which model/prompt is live, it asks the one source of truth that already
  exists.
- **Eval score as metric labels, not a per-run time series logged to Loki/Tempo.** `model_version`/
  `prompt_version`/`backend` are a handful of distinct values each, the same bounded-cardinality
  reasoning `docs/architecture.md` section 9's cardinality rule already applies to `tenant_id`/
  `model`/`prompt_version` as metric labels — safe here for the identical reason.

Alternatives: Langfuse and Arize Phoenix — see Decision above; neither is ruled out forever, see
Revisit when. An LLM-as-judge scorer (a second model call grading the first's answer) — not
used, see Decision above; could be added later as a second, clearly-labelled scoring method
alongside keyword presence, not a replacement for it, since a cheap deterministic score should
stay available even if a judge model is added. Writing eval results directly into the response
body or a dedicated `ai_service` endpoint the way Phase 16's `/v1/meta` does — not used, because
unlike governance (a static, per-deployment fact the service itself always knows), an eval score
is produced by an external process running a whole dataset over many requests, which does not
fit the "ask the service what it is" shape `/v1/meta` exists for.

Consequences: a new top-level `eval/` directory (not inside `app/ai_service`, since this is a
tool that calls the service, not part of the service itself) with its own `pyproject.toml`/
`requirements.txt`/`Makefile` targets, mirroring `app/ai_service`'s own conventions;
`eval/golden_dataset.json` and a pure, fully-unit-tested scoring function plus a thin CLI/IO
wrapper that calls a live service's `/v1/chat` and `/v1/meta` and pushes to the Pushgateway
(the same pure-function/IO-wrapper split ADR-37's `governance/__init__.py` used, for the same
testability reason); a new `deploy/platform/pushgateway/` namespace/values/ServiceMonitor, a
`scripts/bootstrap/pushgateway.sh` following `scripts/bootstrap/finops.sh`'s own shape, and new
`versions.env` pins; a new Grafana panel reading the pushed `polaris_eval_score` metric. This
phase deliberately does **not** wire the eval score into Argo Rollouts' `AnalysisTemplate` as a
canary gate — `docs/architecture.md` section 8 names that as a later input ("later eval score"),
and this project's progressive-delivery work (Phase 18) has not started yet; doing so here would
be building ahead of its own roadmap the same way Phase 16 was warned against inventing
MLflow-shaped features before Phase 17 proved they were needed.

Revisit when: a second golden-dataset-like need appears that actually requires human review,
trace-level debugging of a bad answer, or comparing many prompt variants side by side at once —
the point where Langfuse's or Phoenix's own tracing UI would start earning its RAM cost over a
JSON file and a Grafana panel; or when Phase 18 (progressive delivery) is ready to gate a canary
on eval score, which is the real forcing function for turning this phase's batch-pushed metric
into something an `AnalysisTemplate` can query live. Also revisit once the target-machine
confirmation happens — the same "real cluster is the only real proof" discipline every earlier
Kubernetes-facing phase in this project has followed.

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
