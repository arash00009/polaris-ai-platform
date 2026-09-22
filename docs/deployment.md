# Deployment: reproducing the local environment

This document lets another engineer reproduce the local platform from a clean Windows machine. It covers **Phase 1** (the local development platform). Later phases add their own sections.

**Verified state:** the scripts and configuration are statically tested (`make test`, `shellcheck`). Cluster creation and the smoke test were run on a real machine (Windows 11, WSL2 Ubuntu 24.04, Docker Engine 29.x, k3s v1.34.10); the problems found on the way are recorded in `docs/troubleshooting.md`.

## 1. Requirements

| Requirement | Minimum | Recommended | Why |
|-------------|---------|-------------|-----|
| Windows | 11 (or 10 with WSL2) | 11 | WSL2 with systemd support |
| RAM (Windows total) | 8 GB | 16 GB+ | k3d + observability + model server (see profiles below) |
| CPU (logical cores) | 4 | 8 | Kubernetes control plane plus workloads |
| Free disk | 30 GB | 60 GB | Container images and volumes |
| Virtualization | Enabled in firmware | — | Required by WSL2 |
| GPU | Not required | — | CPU-only design |

**Why WSL2:** the whole toolchain (Docker, k3s, Kubernetes tooling, Trivy) is Linux-native. WSL2 provides a real Linux kernel, so containers and Kubernetes behave as they do in production, without a heavyweight VM.

## 2. Windows host settings (PowerShell)

Inspect the host:

```powershell
wsl --version
wsl -l -v
(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, VirtualizationFirmwareEnabled
Get-PSDrive C | Select-Object @{n='Free_GB'; e={[math]::Round($_.Free / 1GB, 1)}}
```

By default WSL2 may use up to 50 % of Windows RAM. Set explicit limits in `%UserProfile%\.wslconfig` so Windows stays responsive and the platform has enough memory:

| Windows RAM | `memory=` | `processors=` | `swap=` |
|-------------|-----------|---------------|---------|
| 8 GB | 5GB | total logical cores − 2 (minimum 4) | 4GB |
| 16 GB | 11GB | total logical cores − 2 | 4GB |
| 32 GB | 20GB | total logical cores − 2 | 8GB |

```ini
[wsl2]
memory=11GB
processors=6
swap=4GB
```

Apply with `wsl --shutdown`, wait about 8 seconds, then reopen the Ubuntu terminal.

## 3. Ubuntu (WSL2) settings

systemd must be PID 1 so that Docker runs as a service. Check with `ps -p 1 -o comm=`. If it does not print `systemd`, add this to `/etc/wsl.conf` and run `wsl --shutdown`:

```ini
[boot]
systemd=true
```

Keep the repository on the Linux filesystem (`~/polaris/...`), never under `/mnt/c/...`.

### cgroup version (matters for the Kubernetes version)

Kubernetes 1.35 and newer refuse to start the kubelet on a host that uses cgroup v1. Older WSL2 kernels (for example 5.15) use cgroup v1. Check:

```bash
stat -fc %T /sys/fs/cgroup     # cgroup2fs = v2 (good), tmpfs = v1
docker info | grep -i 'cgroup version'
```

On the reference machine (kernel 5.15.167.4) this printed `tmpfs` / `Cgroup Version: 1`, so the cluster is pinned to Kubernetes **1.34** (ADR-16). `make doctor` checks this combination and fails with an explanation if the pin and the host disagree.

## 4. Base packages and GitHub CLI

```bash
sudo apt-get update
sudo apt-get install -y git make jq curl unzip ca-certificates gnupg shellcheck python3 python3-venv python3-pip
```

GitHub CLI (from GitHub's official apt repository):

```bash
(type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update && sudo apt install gh -y
```

## 5. Docker Engine (inside WSL2)

Decision: Docker Engine inside WSL2 rather than Docker Desktop (ADR-13) — lighter, Linux-native, no desktop licensing question.

**First check whether Docker is already installed.** On the reference machine it was, and adding a second apt source for it broke `apt update` ("Conflicting values set for option Signed-By"):

```bash
docker --version && docker run --rm hello-world
ls /etc/apt/sources.list.d/ | grep -i docker
```

If `docker run --rm hello-world` works, skip to section 6. If Docker is missing, install it from Docker's official apt repository. Use **one** source file only (either `docker.list` or `docker.sources`, never both):

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Restart the distribution so the new group applies. Run this in **Windows PowerShell**, not inside Ubuntu (get the distro name from `wsl -l -v`), then reopen the Ubuntu terminal:

```powershell
wsl --terminate Ubuntu
```

Verify:

```bash
docker run --rm hello-world
```

Security note: membership of the `docker` group is equivalent to root on the WSL2 VM. Acceptable for a single-user development machine; not for shared hosts.

## 6. Pinned tools

`versions.env` pins k3d, kubectl and Helm. The Kubernetes version is pinned by the k3s image in `deploy/k3d/cluster.yaml` (currently 1.34.10; see the cgroup note in section 3 and ADR-16). kubectl must stay within one minor version of the cluster (Kubernetes version-skew policy); `make test` enforces this.

```bash
make tools-install   # downloads to ~/.local/bin and verifies each checksum
make doctor
```

Upgrade policy: change one version at a time, run `make doctor && make test && make smoke`, then commit.

## 7. Cluster and verification

```bash
make cluster-up      # creates cluster "polaris": 1 server + 2 agents, Traefik, local registry
make cluster-status
make smoke           # builds confidence end to end; see below
```

`make smoke` pushes a small image to the local registry, deploys it, calls it through Traefik on `http://localhost:8088`, checks the response, and cleans up.

| Endpoint | Meaning |
|----------|---------|
| `localhost:8088` / `localhost:8448` | Traefik ingress (HTTP / HTTPS). Set in `cluster.yaml`; 8080/8443 are avoided because other local clusters commonly use them |
| `localhost:5000` | Local registry (push from host). In the cluster the same registry is `registry.localhost:5000` |

The registry is unauthenticated and local-only. Never push anything sensitive to it.

## 8. AI service (Phase 2)

The service lives in `app/ai_service/` and runs locally in a Python virtualenv. It needs Python 3.12 or newer and the `venv` module (`sudo apt-get install -y python3-venv` on Ubuntu; `make doctor` checks both).

```bash
make app-install   # creates app/ai_service/.venv and installs the pinned dependencies
make app-check     # ruff lint + format check, then pytest with coverage (fails below 95 %)
make app-run       # serves http://127.0.0.1:8000  (interactive docs at /docs)
```

Call it from a second terminal:

```bash
curl -s -X POST http://127.0.0.1:8000/v1/chat \
  -H 'content-type: application/json' \
  -d '{"tenant_id":"demo","prompt":"Explain Kubernetes pods"}'
```

**Configuration** is read from environment variables (prefix `POLARIS_`); nothing is read from files.

| Variable | Default | Meaning |
|----------|---------|---------|
| `POLARIS_BACKEND` | `mock` | `mock` or `openai_compat` |
| `POLARIS_BACKEND_TIMEOUT_S` | `30` | Total time allowed for one backend call; exceeded means HTTP 504 |
| `POLARIS_LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARNING` or `ERROR` |
| `POLARIS_LOG_FORMAT` | `text` | `text` for a terminal, `json` for one JSON object per line (the container image sets `json`) |
| `POLARIS_READY_TIMEOUT_S` | `2` | How long `GET /readyz` waits for the backend before answering 503 |
| `POLARIS_MOCK_MODEL_NAME` | `mock-1` | Model name reported by the mock |
| `POLARIS_MOCK_LATENCY_MS` | `0` | Simulated processing time |
| `POLARIS_MOCK_FAILURE_RATE` | `0` | Fraction (0 to 1) of calls that fail on purpose |
| `POLARIS_MOCK_SEED` | unset | Makes the failure pattern reproducible |
| `POLARIS_MOCK_READY` | `true` | Set to `false` to make the mock report "not ready" on `/readyz` |
| `POLARIS_OPENAI_BASE_URL` | `http://localhost:11434/v1` | Server that speaks the OpenAI chat-completions API |
| `POLARIS_OPENAI_MODEL` | unset | Required when `POLARIS_BACKEND=openai_compat` |
| `POLARIS_OPENAI_API_KEY` | unset | Optional bearer token; never logged |

Example: `POLARIS_MOCK_LATENCY_MS=200 POLARIS_MOCK_FAILURE_RATE=0.2 make app-run`.

**Probes** (Phase 3): `GET /healthz` answers `{"status":"ok"}` whenever the process runs (liveness); `GET /readyz` answers `{"status":"ready"}` when the backend is ready and 503 otherwise (readiness). Try `POLARIS_MOCK_READY=false make app-run` and call both.

**Dependencies.** `app/ai_service/requirements.txt` (runtime) and `requirements-dev.txt` (tests, lint) pin exact versions, including transitive dependencies, so every machine installs the same set. `pyproject.toml` lists only the direct dependencies. To upgrade deliberately: create a scratch virtualenv, install the direct dependencies unpinned, run `pip freeze`, review the diff, update both files, then run `make app-check`. `make test` fails if any line in the requirements files is not pinned with `==`.

## 9. Container image (Phase 3)

The image is built from `app/ai_service/Dockerfile` by `scripts/build/image.sh`, through make targets. Docker must be running (`make doctor`). The first build downloads the base image from Docker Hub and the Python packages from PyPI.

```bash
make image-info      # tags, base image and scanner that would be used
make image-pin       # prints PYTHON_BASE_DIGEST= and TRIVY_IMAGE_DIGEST= lines; paste them into versions.env and commit (done once; run again to bump)
make image-build     # builds <registry>/polaris/ai-service:<version>-<git sha> and :<version>
make image-check     # starts the image and verifies: non-root, /healthz, /readyz, the /v1/chat contract, JSON logs, HEALTHCHECK, SIGTERM
make image-run       # runs it hardened on http://127.0.0.1:8000 (Ctrl+C to stop)
make image-push      # pushes both tags to the local registry (needs the cluster: make cluster-up)
make image-scan      # Trivy scan of the image; fails on HIGH/CRITICAL findings that have a fix
make image-sbom      # CycloneDX SBOM in artifacts/
```

**Tags.** `<version>-<12-character git sha>` is immutable: deploy by this one. A `-dirty` suffix means the working tree had uncommitted changes. `<version>` moves with every build of that version. There is no `latest`. Build from a clean tree (commit first) to get a tag that names a real commit.

**Configuration** works as for the virtualenv: any `POLARIS_*` variable exported in your shell is passed into the container by `make image-run`, for example `POLARIS_MOCK_FAILURE_RATE=0.3 make image-run`. The image itself only sets `POLARIS_LOG_FORMAT=json`.

**Run restrictions.** `make image-run` and `make image-check` run the container with a read-only root filesystem, all Linux capabilities dropped, `no-new-privileges`, a 256 MB memory limit and a process limit. They are the restrictions the Kubernetes manifests apply in Phase 4.

**Digest pins.** Both `PYTHON_BASE_DIGEST` and `TRIVY_IMAGE_DIGEST` are pinned in `versions.env` (2026-09-21). Without a pin the base image is a moving tag: the build works, but two builds a month apart can differ, and `make image-build` warns about it. With the pin, builds are reproducible for the base layer. Bumping the pin is a deliberate commit, followed by `make image-check` and `make image-scan`.

**Scanner and SBOM.** Trivy runs as a container on a saved copy of the image (`docker save`), without the Docker socket. Reports and SBOMs land in `artifacts/` (git-ignored); the first scan downloads the vulnerability database into `artifacts/trivy-cache` (about four minutes on the reference machine; later scans reuse it). Findings that cannot be fixed yet are recorded in `docs/security/image-scan.md`.

## 10. Kubernetes deployment (Phase 4)

The manifests are plain YAML under `deploy/k8s/ai-service/` (no Kustomize; Helm is section 11 below), applied through `scripts/deploy/app.sh` via make targets. Kept as a reference (ADR-23); still works, but Helm is the deploy path from Phase 5 on. The cluster must be up (`make cluster-up`) and the image must already be pushed (`make image-build && make image-push`).

```bash
make deploy-info      # image tag, namespace and context that would be used
make deploy-apply     # applies namespace, config, Deployment, Service, Ingress, PDB, then the NetworkPolicy last
make deploy-status     # pods, rollout status, Service, Ingress, PDB, NetworkPolicy
make deploy-logs       # tails JSON logs from all ai-service pods (ARGS=--follow to keep streaming)
make deploy-smoke      # calls /healthz, /readyz and /v1/chat through Traefik and checks the contract
make deploy-delete     # removes the ai-service workload (keeps the polaris-dev namespace)
```

**Namespace.** Everything lives in `polaris-dev`, one of the three environments the architecture document names (`docs/architecture.md` 4.3; ADR-11). Phase 5 is what adds `polaris-staging`/`polaris-prod` from the same resources, parameterised.

**Image reference.** `scripts/deploy/app.sh` computes the same `<version>-<git sha>` tag as `scripts/build/image.sh` and substitutes it into `deployment.yaml`'s `__AI_SERVICE_IMAGE__` placeholder as `registry.localhost:5000/polaris/ai-service:<tag>` (the in-cluster name for the registry; `localhost:5000` from the host — same distinction as Phase 3). It refuses to apply a tag that has not been pushed.

**Hardening.** Pod Security Admission `restricted` on the namespace; `securityContext` matches the already-verified Phase 3 `docker run`/`image-check` flags (non-root uid/gid 10001, no capabilities, no privilege escalation, read-only root filesystem). A `preStop` sleep plus a longer termination grace period narrows (does not close) the known gap that `/readyz` does not flip to "not ready" during shutdown.

**NetworkPolicy.** Applied last, after the Deployment is confirmed healthy, because it is the one manifest that could not be tested without a cluster: whether kubelet's own probe traffic is exempted from a default-deny "Ingress" policy depends on the CNI. `make deploy-apply` re-checks pod readiness after applying it and warns (without failing the whole command) if pods stop being Ready — see `docs/troubleshooting.md`, Phase 4, and ADR-22 for the removal command.

**Resource requests/limits** are the Phase 3 `docker run` numbers carried over as an estimate, not a measurement; `docs/component-qa.md` and this note both say so on purpose, until Phase 9/11 replace them with load-test numbers.

## 11. Helm deployment (Phase 5)

The Phase 4 manifests above still exist under `deploy/k8s/ai-service/` and still work — they are kept as a reference (ADR-23) — but from this phase on, deploying means `helm/ai-platform/` through `scripts/deploy/helm.sh`, which renders the same fields from `values.yaml` plus one `values-dev.yaml`/`values-staging.yaml`/`values-prod.yaml` per environment instead of duplicating YAML three times.

```bash
make helm-lint             # helm lint the chart against all three values files
make helm-template-dev     # render the dev release's manifests locally, no cluster needed
make helm-apply-dev        # helm upgrade --install (needs: cluster-up, image-build, image-push)
make helm-status-dev       # release status + resources in polaris-dev
make helm-logs-dev         # tails JSON logs (ARGS=--follow to keep streaming)
make helm-smoke-dev        # calls /healthz, /readyz and /v1/chat through Traefik
make helm-uninstall-dev    # removes the release (keeps the polaris-dev namespace)
```

Replace `-dev` with `-staging` or `-prod` for the other two environments; all three can be installed in the cluster at once, since each is its own namespace (`polaris-dev`/`polaris-staging`/`polaris-prod`) and its own Ingress host (`ai.localhost`/`ai-staging.localhost`/`ai-prod.localhost`) behind the same Traefik.

**Migrating `polaris-dev` from Phase 4 to Phase 5.** If `polaris-dev` still has Phase 4's raw-YAML-managed resources in it, `make helm-apply-dev` fails with "already exists and is not managed by Helm" — Helm refuses to take over objects it did not create. Run `make deploy-delete` first (removes those resources, keeps the namespace), then `make helm-apply-dev`. `polaris-staging`/`polaris-prod` have no such history, so `make helm-apply-staging`/`-prod` can be run directly.

**What moved to values, what didn't.** Security context, probes, lifecycle, resource requests/limits, the ConfigMap's keys and the NetworkPolicy's shape are all identical to Phase 4, just read from `values.yaml` instead of hardcoded. Only `namespace`, `environment` and `ingress.host` differ per environment file, plus `replicaCount`/`podDisruptionBudget.minAvailable` for `prod` specifically (ADR-23 explains why only those two).

**Verification status.** The chart's template logic was checked in the sandbox with a custom renderer (no real `helm` binary reachable there — `docs/component-qa.md`, Phase 5) and diffed field-for-field against Phase 4's already-target-machine-verified manifests. `helm lint`/`helm template`/`helm upgrade --install` with the real Helm 4.3.0 binary (already on the target machine from Phase 1's `make tools-install`) is *(pending first apply)* — see the Phase 5 guide.

## 12. Run profiles (memory budget)

Introduced progressively as components are added. Estimates only; measured values replace them in Phases 9 and 11.

| Profile | Contents | Approx. RAM |
|---------|----------|-------------|
| `core` | cluster + application | 2–3 GB |
| `obs` | core + observability stack | 4–6 GB |
| `full` | obs + delivery tooling + model server + FinOps | 7–10 GB |

## 13. Teardown

```bash
make helm-uninstall-dev      # removes each Helm release you installed (repeat for -staging/-prod)
make deploy-delete           # removes the Phase 4 raw-YAML ai-service workload, if it is still applied
make cluster-down            # deletes the cluster and the registry container
```
