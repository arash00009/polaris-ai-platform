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
| 3 | Containerization, Trivy, SBOM | Planned |
| 4–5 | Kubernetes manifests, Helm chart, multi-environment values | Planned |
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
make app-run         # http://127.0.0.1:8000, POST /v1/chat
```

`make help` lists every target.

## Repository layout

```
.
├── Makefile                 # entry point for every local task
├── versions.env             # pinned tool versions (single source of truth)
├── app/
│   └── ai_service/          # FastAPI service, ModelBackend interface, unit tests
├── deploy/
│   ├── k3d/cluster.yaml     # local cluster definition (k3s image pinned here)
│   └── k8s-smoke/           # throwaway workload used by `make smoke`
├── scripts/
│   ├── lib/common.sh        # shared shell helpers
│   └── bootstrap/           # install-tools, doctor, cluster, smoke-test
├── tests/bootstrap/         # static tests for the scripts and configuration
└── docs/
    ├── architecture.md      # design, diagrams, technology choices, roadmap
    ├── deployment.md        # how to reproduce the local environment
    ├── troubleshooting.md   # real errors and fixes, added as they are encountered
    ├── component-qa.md      # the six employer questions for every component
    └── adr/README.md        # architecture decision records
```

More directories (`helm/`, `.github/workflows/`, …) appear as their phases are built.

## Implemented / Demonstrated / Documented

| Level | Meaning |
|-------|---------|
| **Implemented** | Runs locally and is tested |
| **Demonstrated** | Works in a reduced local form and is labelled as such |
| **Documented** | Production equivalent explained, not built here (for example GPU serving, Kafka, Harbor) |

The full matrix, mapped to the role requirements, is in [docs/architecture.md](docs/architecture.md#part-c--requirement-coverage-matrix).
