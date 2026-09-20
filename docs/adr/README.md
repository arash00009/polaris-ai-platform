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
