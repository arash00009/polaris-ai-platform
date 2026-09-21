# Troubleshooting

A running log of real problems, their causes and fixes. Add an entry whenever something breaks — this is evidence of understanding, not clutter.

Format: **Symptom** → **Cause** → **Fix** → **How to confirm**.

## Phase 1: local platform

### Encountered on a real machine (Windows 11, WSL2 Ubuntu 24.04, 2026-09-20/21)

| Symptom | Cause | Fix | Confirm |
|---------|-------|-----|---------|
| `apt update`: `Conflicting values set for option Signed-By` after following an older version of the Docker install steps | Docker was already installed with `docker.list` + `docker.gpg`; a second source file (`docker.sources` + `docker.asc`) declared the same repository with a different key file | `sudo rm /etc/apt/sources.list.d/docker.sources`. Check for existing Docker first (`docker --version`). Never keep two source files for one repository | `sudo apt update` succeeds (an unrelated `NO_PUBKEY` warning for a third-party repository may remain; it is harmless here) |
| `make cluster-up` times out; `k3d-polaris-agent-0` never registers with the API server, with k3s v1.35.8 | The host uses **cgroup v1** (`stat -fc %T /sys/fs/cgroup` prints `tmpfs`; `docker info` shows `Cgroup Version: 1`; WSL2 kernel 5.15.167.4). Kubernetes 1.35+ refuses to start the kubelet on cgroup v1 by default | Pin k3s to 1.34: `image: rancher/k3s:v1.34.10-k3s1` in `cluster.yaml` and `KUBECTL_VERSION=v1.34.10` in `versions.env`; `make cluster-reset`. Long-term: move WSL2 to cgroup v2 (see ADR-16). `make doctor` now detects the combination | `kubectl --context k3d-polaris get nodes` shows 3 nodes Ready on `v1.34.10+k3s1` |
| `Bind for 0.0.0.0:8080 failed: port is already allocated` | Another local cluster (a `kind` container) already published 8080/8443 | Find the holder: `docker ps --format '{{.Names}}  {{.Ports}}' \| grep 8080`. Change the host ports in `deploy/k3d/cluster.yaml` (now 8088/8448); the smoke test reads the port from that file. `make doctor` now checks the ports before the cluster exists | `make cluster-up` succeeds; `docker ps` shows the load balancer on the new ports |
| `make tools-install`: `Connection reset by peer` while downloading kubectl | A transient network reset | Re-run. Downloads now use `curl --retry 5 --retry-all-errors` | The tool prints its version after install |
| `make smoke` step 3: rollout times out; pods `ImagePullBackOff` with `dial tcp [::1]:5000: connect: connection refused` for `k3d-registry.localhost:5000/...` | The registry container is named exactly as in `cluster.yaml` (`registry.localhost`); there is **no** `k3d-` prefix. The name `k3d-registry.localhost` has no containerd mirror, so containerd tried plain HTTPS on localhost | Use `registry.localhost:5000/<repo>:<tag>` inside the cluster and `localhost:5000/<repo>:<tag>` from the host. `make test` now checks the manifest against the registry name in `cluster.yaml` | `docker exec k3d-polaris-server-0 cat /etc/rancher/k3s/registries.yaml` lists the mirror `registry.localhost:5000`; `make smoke` prints `SMOKE TEST PASSED` |
| `make cluster-up` (fresh cluster): nodes Ready, but `Traefik deployment did not appear ... within 180s`; `make smoke` step 5 then gets no response on the ingress port | On a new cluster the nodes pull their own system images from Docker Hub. Events showed `Failed to pull image "rancher/klipper-helm:...": ... failed to fetch anonymous token: Get "https://auth.docker.io/token...": context canceled` (a cancelled token request, not a `toomanyrequests` rate limit). Failed pulls back off before retrying, so Traefik's installer started late. `helm-install-traefik` also failed once with `Required CRDs are missing` (it races the CRD chart) and succeeded on its automatic retry | Wait. Traefik appeared about 5.5 minutes after cluster creation without any action. `cluster.sh` now waits up to 600 s (`POLARIS_TRAEFIK_WAIT=900 make cluster-up` for longer) and prints pods and events if it still times out. If it never recovers: `kubectl -n kube-system get pods,jobs` and the events | `kubectl -n kube-system get deploy traefik` shows `1/1`; `helm-install-traefik` pod is `Completed` (one restart is normal); `make smoke` passes |
| `wsl --terminate` typed inside Ubuntu does nothing useful | `wsl` is a Windows command | Run it in Windows PowerShell | `wsl -l -v` (PowerShell) shows the distro as Stopped |

Diagnostic habit that found the registry-name problem: the smoke test deletes its namespace on failure, so deploy the manifest by hand (`kubectl apply -f deploy/k8s-smoke/whoami.yaml`) and read `kubectl -n polaris-smoke describe pods` (the Events section). The smoke test now prints pod status and events itself when the rollout fails.

### Expected failure modes (not yet reproduced)

These come from the design. They are marked *expected* until reproduced on a real machine; replace the marker with the date and the actual output when that happens.

| Symptom | Likely cause | Fix | Confirm |
|---------|--------------|-----|---------|
| `make doctor`: "systemd is not PID 1" *(expected)* | systemd not enabled for the WSL distro | Add `[boot]` / `systemd=true` to `/etc/wsl.conf`, then `wsl --shutdown` in PowerShell | `ps -p 1 -o comm=` prints `systemd` |
| `permission denied while trying to connect to the Docker daemon socket` *(expected)* | User not in the `docker` group, or WSL not restarted after `usermod` | `sudo usermod -aG docker "$USER"`, then run `wsl --terminate <DistroName>` in Windows PowerShell and reopen Ubuntu | `docker ps` works without sudo |
| `Cannot connect to the Docker daemon` *(expected)* | Docker service not running | `sudo systemctl enable --now docker` | `systemctl status docker --no-pager` |
| `/usr/bin/env: 'bash\r': No such file or directory` *(expected)* | Scripts saved with Windows (CRLF) line endings | `sed -i 's/\r$//' <file>`; keep `.gitattributes` in the repo | `make test` (CRLF check) passes |
| `make: *** missing separator` *(expected)* | Makefile indented with spaces instead of tabs | Recipes must start with a real tab (see `.editorconfig`) | `make help` prints the target list |
| `make doctor`: RAM below the expectation *(expected)* | WSL2 default memory cap (50 % of Windows RAM) | Set `memory=` in `%UserProfile%\.wslconfig`, `wsl --shutdown` | `free -h` shows the new total |
| `k3d cluster create` times out *(expected)* | Not enough RAM/CPU, or slow first-time image pulls | Raise `.wslconfig` limits; retry `make cluster-reset` | `make cluster-status` shows all nodes Ready |
| `Could not pull rancher/k3s:...` *(expected)* | Tag not available or Docker Hub unreachable/rate-limited | Pick another tag of the same Kubernetes minor (`v1.34.x-k3sN`) in `deploy/k3d/cluster.yaml`; keep kubectl within one minor | `docker pull <image>` succeeds |
| Port 5000 already in use *(expected)* | Another local registry uses it | `ss -ltnp 'sport = :5000'`; stop it or change `hostPort` in `cluster.yaml` (and the `PUSH_REF` in `smoke-test.sh`) | `make cluster-up` succeeds |
| `make smoke`: no response from ingress *(expected)* | Traefik not ready yet, or port mapping changed | `kubectl -n kube-system get pods`; `kubectl -n polaris-smoke get ingress,pods` | `curl -H 'Host: whoami.localhost' http://localhost:8088/` returns text (use the port from `cluster.yaml`) |
| `make smoke`: `Cannot pull traefik/whoami:...` *(expected)* | Tag unavailable or Docker Hub rate limit | `SMOKE_IMAGE=traefik/whoami:latest make smoke` | Smoke test passes |
| Everything is slow, file watching misbehaves *(expected)* | Repository stored under `/mnt/c/...` | Move it to `~/polaris/...` on the Linux filesystem | `make doctor` shows the repo on the Linux filesystem |

## Phase 2: AI service

Marked *expected* until reproduced on the target machine. The last three were reproduced in the sandbox while testing (2026-09-21) and are marked *seen*.

| Symptom | Likely cause | Fix | Confirm |
|---------|--------------|-----|---------|
| `make app-install`: `The virtual environment was not created successfully because ensurepip is not available` *(expected)* | Ubuntu splits `venv` into a separate package | `sudo apt-get install -y python3-venv`; remove the half-made `app/ai_service/.venv` and retry | `make doctor` shows "python3 can create virtualenvs" |
| `pip install -e`: `requires a different Python: 3.10.x not in '>=3.12'` *(expected)* | `python3` on PATH is older than 3.12 | Use Ubuntu 24.04 (Python 3.12), or create the venv with `python3.12 -m venv app/ai_service/.venv` by hand | `app/ai_service/.venv/bin/python --version` prints 3.12 or newer |
| `make app-test`: `No module named ai_service` *(expected)* | The package was not installed into the venv | `make app-install` (the last step is `pip install -e`) | `.venv/bin/python -c "import ai_service"` |
| `make app-run`: `Address already in use` on port 8000 *(expected)* | Another process uses 8000 | `ss -ltnp 'sport = :8000'`; stop it, or run uvicorn by hand with `--port 8001` | `curl http://127.0.0.1:8000/docs` answers |
| Service refuses to start: `POLARIS_OPENAI_MODEL must be set when POLARIS_BACKEND=openai_compat` *(seen)* | The real backend was selected without a model name | Set `POLARIS_OPENAI_MODEL` (the model is chosen in Phase 11), or unset `POLARIS_BACKEND` to use the mock | The service starts |
| `POST /v1/chat` returns 502 `backend_error` with `reason=model backend unreachable` in the log *(seen)* | `POLARIS_BACKEND=openai_compat` but nothing listens on `POLARIS_OPENAI_BASE_URL` | Start the model server (Phase 11) or use the mock. Failure injection with `POLARIS_MOCK_FAILURE_RATE` returns the same 502 on purpose | Log shows `chat completed` |
| `POST /v1/chat` returns 504 `backend_timeout` *(seen)* | Backend slower than `POLARIS_BACKEND_TIMEOUT_S` (or `POLARIS_MOCK_LATENCY_MS` set higher than the budget) | Raise the timeout or lower the latency | The request returns 200 |

## Phase 3: container image, probes, logs, scanner

All rows are *expected*: they come from the design and from how these tools usually fail. Replace the marker with the date and the real output when one is reproduced on the target machine.

| Symptom | Likely cause | Fix | Confirm |
|---------|--------------|-----|---------|
| `make image-build`: `failed to fetch anonymous token` or `toomanyrequests` while pulling `python:3.12-slim-trixie` *(expected)* | Docker Hub is slow, cancelled the request, or rate-limits anonymous pulls (the same family of problem as the Traefik pull in Phase 1) | Retry; `docker login` raises the limit; pull once with `docker pull python:3.12-slim-trixie` and build again | `docker images python` lists the tag |
| `make image-build`: `manifest unknown` for `python:3.12-slim-trixie@sha256:...` *(expected)* | `PYTHON_BASE_DIGEST` in `versions.env` was mistyped or copied for another tag | Empty the value, or run `make image-pin` and paste the printed line | `make image-info` prints the base image; the build finds it |
| `make image-build`: `No matching distribution found ... --only-binary` *(expected)* | A pinned dependency has no binary wheel for this platform; the image deliberately refuses to compile | Pin a version that ships a wheel (check `pip download --only-binary=:all:` in a scratch venv), then `make app-check` | The build passes the `pip install` step |
| Tag ends in `-dirty` *(expected)* | The git working tree has uncommitted changes | Commit, then `make image-build` again. A `-dirty` image is for local tests only, never for `make image-push` in a real workflow | `make image-info` shows a tag without `-dirty` |
| `make image-check`: `does not run as a non-root user` *(expected)* | The `USER` line was changed or removed | Restore `USER 10001:10001`; `make test` also catches it | `docker run --rm --entrypoint id <image> -u` prints `10001` |
| `make image-check`: `/healthz did not answer ok` *(expected)* | The container exited at start (bad configuration, a missing file) | `docker logs polaris-ai-service-check` (the check container is removed at the end; run `make image-run` to keep it in the foreground). A misconfiguration shows as a JSON line with an `exception` field | `make image-check` shows all checks passing |
| `make image-check`: `some log lines are not JSON` *(expected)* | Something writes to stdout outside the logging setup (a `print`, a library warning) | Find it in `docker logs`; route it through the `logging` module | Every line parses with `jq` |
| `make image-check`: SIGTERM exit code 137 *(expected)* | The process did not stop within 10 s and was killed. Signals sent to PID 1 are not handled the same as for other processes | Run with `docker run --init` (tini) or check for blocking work in the lifespan shutdown | Exit code 0 or 143, and `Application shutdown complete` in the logs |
| `make image-push`: `The registry at localhost:5000 does not answer` *(expected)* | The k3d cluster (and its registry) is not running | `make cluster-up`; `docker ps --filter name=registry` | `curl -s localhost:5000/v2/_catalog` answers |
| `make image-scan`: `manifest unknown` for the Trivy image *(expected)* | The tag `ghcr.io/aquasecurity/trivy:0.74.0` was inferred, not checked, or the registry name differs | `docker pull` the tag by hand; if the tag really does not exist, edit `TRIVY_IMAGE` (and if needed `TRIVY_VERSION`) in `versions.env` (an exported variable does not override that file), for example to `docker.io/aquasec/trivy`, after checking the project's installation page for the current image name and tag format | The scan starts and prints the operating system |
| `make image-scan`: `TOOMANYREQUESTS` while downloading the vulnerability database *(expected)* | The default database registry rate-limits anonymous downloads | Retry later, or point Trivy at a mirror: `TRIVY_DB_REPOSITORY=public.ecr.aws/aquasecurity/trivy-db make image-scan` (any exported `TRIVY_*` variable is passed on; confirm the mirror name in the Trivy documentation first) | The report file appears in `artifacts/` |
| `make image-scan`: `permission denied` on `artifacts/trivy-cache` *(expected)* | The directory was created by an earlier run as root | `sudo rm -rf artifacts/trivy-cache`, run again (the script runs the scanner as your user) | The scan writes its report |
| `make image-scan` fails with `N HIGH/CRITICAL finding(s) have a fix available` *(expected)* | The base image or a dependency has a known vulnerability with a fix | Rebuild on a newer base (`make image-pin` for the new digest), or bump the dependency in `requirements.txt` and run `make app-check`; scan again. Record anything you accept in `docs/security/image-scan.md` | The scan prints "no HIGH/CRITICAL finding with an available fix" |
