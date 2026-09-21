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
