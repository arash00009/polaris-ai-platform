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
