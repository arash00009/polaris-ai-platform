# Deployment: reproducing the local environment

This document lets another engineer reproduce the local platform from a clean Windows machine. It covers **Phase 1** (the local development platform). Later phases add their own sections.

**Verified state:** the scripts and configuration were written and statically tested (`make test`, `shellcheck`). Docker, cluster creation and the smoke test have to be run on the target machine; results are recorded in the README status table and in `docs/troubleshooting.md`.

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

Decision: Docker Engine inside WSL2 rather than Docker Desktop — lighter, Linux-native, no desktop licensing question. Installation follows Docker's official apt-repository method for Ubuntu:

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

Restart WSL so the new group applies (`wsl --terminate <DistroName>` in PowerShell, then reopen), then verify:

```bash
docker run --rm hello-world
```

Security note: membership of the `docker` group is equivalent to root on the WSL2 VM. Acceptable for a single-user development machine; not for shared hosts.

## 6. Pinned tools

`versions.env` pins k3d, kubectl and Helm. The Kubernetes version is pinned by the k3s image in `deploy/k3d/cluster.yaml`. kubectl must stay within one minor version of the cluster (Kubernetes version-skew policy); `make test` enforces this.

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

`make smoke` pushes a small image to the local registry, deploys it, calls it through Traefik on `http://localhost:8080`, checks the response, and cleans up.

| Endpoint | Meaning |
|----------|---------|
| `localhost:8080` / `localhost:8443` | Traefik ingress (HTTP / HTTPS) |
| `localhost:5000` | Local registry (push from host). In the cluster the same registry is `registry.localhost:5000` |

The registry is unauthenticated and local-only. Never push anything sensitive to it.

## 8. Run profiles (memory budget)

Introduced progressively as components are added. Estimates only; measured values replace them in Phases 9 and 11.

| Profile | Contents | Approx. RAM |
|---------|----------|-------------|
| `core` | cluster + application | 2–3 GB |
| `obs` | core + observability stack | 4–6 GB |
| `full` | obs + delivery tooling + model server + FinOps | 7–10 GB |

## 9. Teardown

```bash
make cluster-down    # deletes the cluster and the registry container
```
