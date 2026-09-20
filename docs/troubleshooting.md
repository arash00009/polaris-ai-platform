# Troubleshooting

A running log of real problems, their causes and fixes. Add an entry whenever something breaks — this is evidence of understanding, not clutter.

Format: **Symptom** → **Cause** → **Fix** → **How to confirm**.

## Phase 1: local platform

Entries below are the failure modes expected from the design. They are marked *expected* until reproduced on a real machine; replace the marker with the date and the actual output when that happens.

| Symptom | Likely cause | Fix | Confirm |
|---------|--------------|-----|---------|
| `make doctor`: "systemd is not PID 1" *(expected)* | systemd not enabled for the WSL distro | Add `[boot]` / `systemd=true` to `/etc/wsl.conf`, then `wsl --shutdown` in PowerShell | `ps -p 1 -o comm=` prints `systemd` |
| `permission denied while trying to connect to the Docker daemon socket` *(expected)* | User not in the `docker` group, or WSL not restarted after `usermod` | `sudo usermod -aG docker "$USER"`, then `wsl --terminate <DistroName>` and reopen | `docker ps` works without sudo |
| `Cannot connect to the Docker daemon` *(expected)* | Docker service not running | `sudo systemctl enable --now docker` | `systemctl status docker --no-pager` |
| `/usr/bin/env: 'bash\r': No such file or directory` *(expected)* | Scripts saved with Windows (CRLF) line endings | `sed -i 's/\r$//' <file>`; keep `.gitattributes` in the repo | `make test` (CRLF check) passes |
| `make: *** missing separator` *(expected)* | Makefile indented with spaces instead of tabs | Recipes must start with a real tab (see `.editorconfig`) | `make help` prints the target list |
| `make doctor`: RAM below the expectation *(expected)* | WSL2 default memory cap (50 % of Windows RAM) | Set `memory=` in `%UserProfile%\.wslconfig`, `wsl --shutdown` | `free -h` shows the new total |
| `k3d cluster create` times out *(expected)* | Not enough RAM/CPU, or slow first-time image pulls | Raise `.wslconfig` limits; retry `make cluster-reset` | `make cluster-status` shows all nodes Ready |
| `Could not pull rancher/k3s:...` *(expected)* | Tag not available or Docker Hub unreachable/rate-limited | Pick another `v1.35.x-k3sN` tag in `deploy/k3d/cluster.yaml`; keep kubectl within one minor | `docker pull <image>` succeeds |
| Port already in use: 8080, 8443 or 5000 *(expected)* | Another process uses the port | Find it with `ss -ltnp \| grep -E ':(8080\|8443\|5000)\b'`; stop it or change the mapping in `cluster.yaml` (and `smoke-test.sh`) | `make cluster-up` succeeds |
| `make smoke`: no response from ingress *(expected)* | Traefik not ready yet, or port mapping changed | `kubectl -n kube-system get pods`; `kubectl -n polaris-smoke get ingress,pods` | `curl -H 'Host: whoami.localhost' http://localhost:8080/` returns text |
| `make smoke`: `Cannot pull traefik/whoami:...` *(expected)* | Tag unavailable or Docker Hub rate limit | `SMOKE_IMAGE=traefik/whoami:latest make smoke` | Smoke test passes |
| Everything is slow, file watching misbehaves *(expected)* | Repository stored under `/mnt/c/...` | Move it to `~/polaris/...` on the Linux filesystem | `make doctor` shows the repo on the Linux filesystem |
