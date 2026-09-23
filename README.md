# Polaris AI Platform

A locally runnable, production-inspired platform for **delivering, serving, routing and observing AI services** — built as a hands-on engineering portfolio project.

> **Honest scope.** This is a single-developer, local platform designed to mirror production *concepts* (GitOps, progressive delivery, OpenTelemetry, model serving, tenant-aware routing, cost attribution, supply-chain security). It has not been operated at production scale or on GPUs. Every component is labelled **Implemented**, **Demonstrated** or **Documented** so nothing is overclaimed. See [docs/architecture.md](docs/architecture.md).

## Thesis

An AI workload is an ordinary distributed service with three extra properties: its output quality is non-deterministic, its cost scales with tokens, and its runtime (the model server) is heavy and stateful. The platform's job is to make those three properties *visible, controllable and safe to change*.

## Status

| Phase | Area | Status |
|------:|------|--------|
| 0 | Architecture and roadmap | Done — [docs/architecture.md](docs/architecture.md) |
| 1 | Local development platform (WSL2, Docker, k3d, local registry) | In progress — cluster and smoke test verified on the target machine; final re-run of `make doctor`, `make test` and `make smoke` after the latest fixes pending |
| 2 | AI service (FastAPI, swappable model backend) | Done — verified on the target machine (2026-09-21): 87 unit tests at 99 % coverage, and the running service answered 200, 422, 404, 502 and 504 as designed. The real model backend is only tested against a fake transport until Phase 11 |
| 3 | Containerization, Trivy, SBOM | Done (verified 2026-09-21) — 125 unit tests and 41 static checks pass; the 134 MB non-root image was built, checked (9/9), pushed to the local registry, scanned (0 CRITICAL, 44 HIGH, none with a fix, all recorded in `docs/security/image-scan.md`) and an SBOM was generated. Not done: image signing, review of MEDIUM/LOW findings |
| 4 | Kubernetes manifests (Deployment, Service, Ingress, PDB, NetworkPolicy) | Done (verified 2026-09-22) — 64 static checks pass; image `0.3.0-c446b6b88521` built, pushed and deployed to `polaris-dev`, 2/2 pods reached `Ready`, the default-deny `NetworkPolicy` did not disrupt readiness (one data point, not a general guarantee — see ADR-22), and the smoke test passed `/healthz`, `/readyz` and `/v1/chat` through Traefik. Not done: Helm/multi-environment (Phase 5), load-test-measured resource requests |
| 5 | Helm chart, multi-environment values | Done (verified 2026-09-22) — `helm/ai-platform/` renders `polaris-dev`/`-staging`/`-prod` from one chart; 88 static checks pass; `helm lint` passed for all three environments; `helm upgrade --install` succeeded for all three (`dev` 2/2, `staging` 2/2, `prod` 3/3 pods), NetworkPolicy held in all three, and `helm-smoke-*` passed `/healthz`, `/readyz` and `/v1/chat` for each. Three real gaps surfaced, all fixed: two during this phase's own verification, both in `polaris-dev` only — its pre-existing namespace (from Phase 4) had to be manually adopted into the Helm release once (`kubectl label`/`annotate`, ADR-23), and `make deploy-delete` must never be re-run once a namespace is Helm-managed, since it silently deletes the Helm-owned resources while `helm status` still reports the release as deployed (ADR-23, `docs/troubleshooting.md`) — and a third found later, by Phase 7's own testing: `deployment.yaml` had no `checksum/config` annotation, so a ConfigMap-only value change never triggered a rollout (fixed; see Phase 7's row and ADR-23/ADR-25). Not done: three environments in a real load-tested sense — resource requests/limits are still Phase 3's estimate |
| 6 | CI pipeline (GitHub Actions) | Done (verified 2026-09-22) — `.github/workflows/ci.yml` ran end to end on GitHub Actions for real, all six jobs green: lint/test, secret scan (gitleaks), dependency audit (pip-audit), workflow lint (yamllint + actionlint), image build/check/scan/SBOM + ephemeral-k3d deploy validation (2m 1s), and GHCR publish. 127 static checks pass. Getting there took three pushes: the first real Actions run exposed a previously invisible bug — `scripts/build/image.sh` had never actually been committed since Phase 3, because an unanchored `.gitignore` pattern (`build/`, matching at any depth) silently excluded `scripts/build/`; fixing that surfaced a second, smaller regression in one of this project's own static tests. Both are fixed and documented in `docs/troubleshooting.md` and ADR-24 — a real lesson that local-only verification cannot catch a file that was never committed, only an independent checkout can. Not done: image signing (Phase 15) |
| 7 | Continuous verification | Done (verified 2026-09-22) — `scripts/verify/post-deploy.sh` (`make verify-dev/-staging/-prod`): rollout status, health, readyz, a real non-empty AI answer and structured-log presence, all always checked and reported together (not fail-fast); pod resource metrics via k3s's bundled metrics-server are checked but only ever advisory. 140 static checks pass. The healthy path is verified for real against `dev`/`staging`/`prod`, all six checks passing with genuine metrics. The deliberate `POLARIS_MOCK_READY=false` failure-injection test found a real gap on its first run instead of just exercising the one it was written for: Phase 5's chart had no `checksum/config` annotation, so a ConfigMap-only value change never triggered a rollout — the injected change never reached a running pod (confirmed via identical pod names/ReplicaSet hash before and after), so nothing was actually unhealthy for the script to catch. Fixed (a `checksum/config` annotation, `helm/ai-platform/templates/deployment.yaml`) and re-confirmed for real: the same override against the fixed chart produced a genuine `FAIL rollout: ...` with a real, never-ready pod, and reverting produced a clean `PASS` again with yet another new pod — see `docs/troubleshooting.md` and ADR-25 for the full before/after evidence. Not done: a Kubernetes-Job production equivalent (documented, not built — ADR-25); real threshold-based analysis (needs Phase 9/10's Prometheus) |
| 8 | GitOps with Argo CD (separate configuration repository) | Written (not yet run for real) — `scripts/bootstrap/argocd.sh` installs the pinned, checksum-verified Argo CD `v3.5.2` (manifest downloaded and its sha256 verified for real in the sandbox, twice, in two separate sessions); a genuinely separate `polaris-gitops` repository holds an app-of-apps root plus one multi-source Helm `Application` per environment; `dev`/`staging` sync automatically (with self-heal), `prod` requires an explicit manual sync — the working stand-in for the roadmap's "manual approval" step, with the honest caveat (ADR-26) that nothing enforces the sync was actually reviewed. 166 static checks pass. Not done: any of this run against a live cluster — `make argocd-install`, `make gitops-bootstrap`, and the self-heal demonstration are the target-machine steps next; image-tag promotion into CI (deliberately left manual this phase, ADR-26) |
| 9–10 | Observability: Prometheus, Loki, Tempo, Grafana, OpenTelemetry | Planned |
| 11–14 | Model serving, gateway, FinOps, multi-tenancy | Planned |
| 15–17 | Security hardening, AI governance, AI evaluation | Planned |
| 18–20 | Progressive delivery, failure engineering, final demonstration | Planned |

This table is updated at the end of every phase.

## Quickstart (Windows + WSL2 Ubuntu 24.04)

Full instructions, including the one-time Windows and Docker setup, are in [docs/deployment.md](docs/deployment.md). Once Docker Engine is installed inside WSL2:

```bash
git clone <this repository> ~/polaris/polaris-ai-platform
cd ~/polaris/polaris-ai-platform

make tools-install   # pinned k3d, kubectl, helm -> ~/.local/bin (checksum-verified, no sudo)
make doctor          # verify RAM, CPU, disk, Docker, tool versions, config consistency
make test            # static tests (no Docker needed)
make cluster-up      # 1 control-plane + 2 agents (Kubernetes 1.34, ADR-16), Traefik, local registry
make smoke           # registry -> cluster -> ingress -> host, end to end

make app-install     # Phase 2: AI service virtualenv with pinned dependencies
make app-check       # lint + unit tests
make app-run         # http://127.0.0.1:8000, POST /v1/chat, GET /healthz, GET /readyz

make image-build     # Phase 3: container image, tagged <version>-<git sha>
make image-check     # start it and verify user, probes, contract, JSON logs, shutdown
make image-scan      # Trivy scan; make image-sbom writes the SBOM

make image-push      # push the image to the local registry (needed before deploy-apply)
make deploy-apply    # Phase 4: Deployment, Service, Ingress, PDB, NetworkPolicy in polaris-dev
make deploy-smoke    # /healthz, /readyz and /v1/chat through Traefik

make helm-lint         # Phase 5: helm lint the chart against dev/staging/prod values
make helm-apply-dev    # helm upgrade --install into polaris-dev (repeat with -staging/-prod)
make helm-smoke-dev    # /healthz, /readyz and /v1/chat through Traefik, for that release

make ci-verify          # Phase 6: everything CI checks before it needs Docker or a cluster
make ci-secrets-scan    # gitleaks — no committed secrets
make ci-deps-audit      # pip-audit — app/ai_service/requirements.txt has no known vulnerabilities
make ci-workflow-lint   # yamllint + actionlint against .github/workflows/
make image-publish      # retag the built image and push it to GHCR (needs: docker login ghcr.io)

make verify-dev         # Phase 7: rollout, health, readyz, a real AI answer, logs, metrics for the dev release

make argocd-install      # Phase 8: install the pinned Argo CD release into the argocd namespace
make gitops-bootstrap    # apply polaris-gitops' app-of-apps root Application (needs a polaris-gitops checkout, see below)
make argocd-status       # every Application's sync/health status, and the control plane's pods
make gitops-bump-dev     # write the currently built image tag into polaris-gitops' environments/dev/image.yaml
```

`.github/workflows/ci.yml` runs these same `make` targets automatically on every push and pull request — see [docs/adr/README.md](docs/adr/README.md) (ADR-24).

`make help` lists every target.

## Two repositories (from Phase 8)

Phase 8 (ADR-08, ADR-26) splits deployment configuration out of this repository into a second one, [`polaris-gitops`](https://github.com/arash00009/polaris-gitops), which Argo CD reconciles from directly. This repository still holds the application, its chart, its CI, and its docs — nothing here changed shape because of the split. `make gitops-bootstrap` and `make gitops-bump-<env>` above expect `polaris-gitops` cloned next to this repository (`GITOPS_DIR`, default: a sibling directory); see that repository's own `README.md` for its structure and the promotion model.

## Repository layout

```
.
├── Makefile                 # entry point for every local task
├── versions.env             # pinned tool versions (single source of truth)
├── .github/
│   └── workflows/ci.yml     # Phase 6: lint, test, secret scan, dependency audit, build, scan, SBOM, ephemeral-cluster deploy, GHCR publish
├── .yamllint.yml            # Phase 6: relaxed yamllint config for .github/workflows/
├── app/
│   └── ai_service/          # FastAPI service, ModelBackend interface, unit tests, Dockerfile
├── deploy/
│   ├── k3d/cluster.yaml     # local cluster definition (k3s image pinned here)
│   ├── k8s-smoke/           # throwaway workload used by `make smoke`
│   └── k8s/ai-service/      # Phase 4 manifests (kept as a reference, ADR-23): namespace, config, Deployment, Service, Ingress, PDB, NetworkPolicy
├── helm/
│   └── ai-platform/         # Phase 5 chart: Chart.yaml, values.yaml, values-{dev,staging,prod}.yaml, templates/
├── scripts/
│   ├── lib/common.sh        # shared shell helpers
│   ├── bootstrap/           # install-tools (k3d, kubectl, helm, gitleaks, actionlint), doctor, cluster, smoke-test
│   ├── build/image.sh       # image build, check, push, scan, SBOM (Phase 3) and publish to GHCR (Phase 6)
│   ├── deploy/app.sh        # apply, status, logs, smoke and delete for ai-service (Phase 4, raw manifests)
│   ├── deploy/helm.sh       # lint, template, apply, status, logs, smoke, uninstall — per environment (Phase 5)
│   ├── ci/                  # secrets-scan.sh, deps-audit.sh, workflow-lint.sh (Phase 6)
│   ├── verify/post-deploy.sh # rollout, health, readyz, AI answer, logs, metrics — per environment (Phase 7)
│   ├── bootstrap/argocd.sh  # install/status/password/uninstall for the Argo CD control plane (Phase 8)
│   └── gitops/              # bootstrap.sh (apply polaris-gitops' root Application), bump-image-tag.sh (Phase 8)
├── tests/bootstrap/         # static tests for the scripts and configuration
└── docs/
    ├── architecture.md      # design, diagrams, technology choices, roadmap
    ├── deployment.md        # how to reproduce the local environment
    ├── troubleshooting.md   # real errors and fixes, added as they are encountered
    ├── component-qa.md      # the six employer questions for every component
    ├── security/image-scan.md  # image scan results and accepted findings
    └── adr/README.md        # architecture decision records
```

## Implemented / Demonstrated / Documented

| Level | Meaning |
|-------|---------|
| **Implemented** | Runs locally and is tested |
| **Demonstrated** | Works in a reduced local form and is labelled as such |
| **Documented** | Production equivalent explained, not built here (for example GPU serving, Kafka, Harbor) |

The full matrix, mapped to the role requirements, is in [docs/architecture.md](docs/architecture.md#part-c--requirement-coverage-matrix).
