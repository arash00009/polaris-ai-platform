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
| 5 | Helm chart, multi-environment values | Done (verified 2026-09-22) — `helm/ai-platform/` renders `polaris-dev`/`-staging`/`-prod` from one chart; 88 static checks pass; `helm lint` passed for all three environments; `helm upgrade --install` succeeded for all three (`dev` 2/2, `staging` 2/2, `prod` 3/3 pods), NetworkPolicy held in all three, and `helm-smoke-*` passed `/healthz`, `/readyz` and `/v1/chat` for each. One real gap surfaced and was fixed: `polaris-dev`'s pre-existing namespace (from Phase 4) had to be manually adopted into the Helm release once (`kubectl label`/`annotate`, ADR-23) since Helm won't take over an object it didn't create. Not done: three environments in a real load-tested sense — resource requests/limits are still Phase 3's estimate |
| 6–7 | CI pipeline (GitHub Actions) and continuous verification | Planned |
| 8 | GitOps with Argo CD (separate configuration repository) | Planned |
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
```

`make help` lists every target.

## Repository layout

```
.
├── Makefile                 # entry point for every local task
├── versions.env             # pinned tool versions (single source of truth)
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
│   ├── bootstrap/           # install-tools, doctor, cluster, smoke-test
│   ├── build/image.sh       # image build, check, push, scan and SBOM (Phase 3)
│   ├── deploy/app.sh        # apply, status, logs, smoke and delete for ai-service (Phase 4, raw manifests)
│   └── deploy/helm.sh       # lint, template, apply, status, logs, smoke, uninstall — per environment (Phase 5)
├── tests/bootstrap/         # static tests for the scripts and configuration
└── docs/
    ├── architecture.md      # design, diagrams, technology choices, roadmap
    ├── deployment.md        # how to reproduce the local environment
    ├── troubleshooting.md   # real errors and fixes, added as they are encountered
    ├── component-qa.md      # the six employer questions for every component
    ├── security/image-scan.md  # image scan results and accepted findings
    └── adr/README.md        # architecture decision records
```

More directories (`.github/workflows/`, …) appear as their phases are built.

## Implemented / Demonstrated / Documented

| Level | Meaning |
|-------|---------|
| **Implemented** | Runs locally and is tested |
| **Demonstrated** | Works in a reduced local form and is labelled as such |
| **Documented** | Production equivalent explained, not built here (for example GPU serving, Kafka, Harbor) |

The full matrix, mapped to the role requirements, is in [docs/architecture.md](docs/architecture.md#part-c--requirement-coverage-matrix).
