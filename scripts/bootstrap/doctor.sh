#!/usr/bin/env bash
# scripts/bootstrap/doctor.sh
# Verifies that this machine can run the Polaris local platform.
# Exit code: 0 = no FAIL results (warnings are allowed), 1 = at least one FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
CONFIG="$ROOT/deploy/k3d/cluster.yaml"

PASS=0
WARN=0
FAIL=0
pass() { log_ok "$*"; PASS=$((PASS + 1)); }
warn() { log_warn "$*"; WARN=$((WARN + 1)); }
fail() { log_fail "$*"; FAIL=$((FAIL + 1)); }
section() { printf '\n== %s ==\n' "$*"; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }

# ---------------------------------------------------------------- Host
section "Host"

if [[ "$(uname -s)" == "Linux" ]]; then
  pass "Linux kernel: $(uname -r)"
else
  fail "Not Linux. Run this inside WSL2 (Ubuntu), not in PowerShell."
fi

if grep -qi microsoft /proc/version 2>/dev/null; then
  if uname -r | grep -qi 'wsl2'; then
    pass "Running inside WSL2"
  else
    warn "Running inside WSL, but the kernel does not say WSL2. Check with: wsl -l -v (in PowerShell)"
  fi
else
  warn "Not running inside WSL (fine on native Linux; the docs assume WSL2)"
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
    pass "Ubuntu 24.04"
  else
    warn "OS is ${PRETTY_NAME:-unknown}; the project is developed on Ubuntu 24.04"
  fi
fi

if [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]; then
  pass "systemd is PID 1 (Docker can run as a service)"
else
  fail "systemd is not PID 1. Add '[boot]' + 'systemd=true' to /etc/wsl.conf, then run 'wsl --shutdown' in PowerShell."
fi

case "$ROOT" in
  /mnt/*) warn "Repository is on the Windows filesystem ($ROOT). Move it to ~/polaris (Linux filesystem) for speed and correct file permissions." ;;
  *)      pass "Repository is on the Linux filesystem ($ROOT)" ;;
esac

# ---------------------------------------------------------------- Resources
section "Resources (what WSL2 can see)"

mem_gb="$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)"
cpus="$(nproc)"
disk_gb="$(df -Pk "$HOME" | awk 'NR==2 {printf "%.0f", $4/1048576}')"

if lt "$mem_gb" 5; then
  fail "RAM visible to WSL2: ${mem_gb} GB (< 5 GB). Raise 'memory=' in %UserProfile%\\.wslconfig."
elif lt "$mem_gb" 10; then
  warn "RAM visible to WSL2: ${mem_gb} GB. Enough for the core profile; the full stack (Phase 9+) wants ~10 GB. See docs/deployment.md."
else
  pass "RAM visible to WSL2: ${mem_gb} GB"
fi

if lt "$cpus" 4; then
  fail "CPU cores visible: ${cpus} (< 4)"
elif lt "$cpus" 6; then
  warn "CPU cores visible: ${cpus} (6+ recommended)"
else
  pass "CPU cores visible: ${cpus}"
fi

if lt "$disk_gb" 15; then
  fail "Free disk in \$HOME: ${disk_gb} GB (< 15 GB)"
elif lt "$disk_gb" 30; then
  warn "Free disk in \$HOME: ${disk_gb} GB (30+ GB recommended: images and volumes add up)"
else
  pass "Free disk in \$HOME: ${disk_gb} GB"
fi

# ---------------------------------------------------------------- Tools
section "Tools"

for t in git make jq curl unzip; do
  if have "$t"; then
    pass "$t found"
  else
    fail "$t not found. Install: sudo apt-get install -y $t"
  fi
done

if have gh; then
  pass "gh (GitHub CLI) found"
else
  warn "gh not found (needed to publish to GitHub; see docs/deployment.md)"
fi

if have python3 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
  pass "Python $(python3 -c 'import platform; print(platform.python_version())') (>= 3.12)"
elif have python3; then
  warn "Python $(python3 -c 'import platform; print(platform.python_version())') is older than 3.12 (needed from Phase 2)"
else
  warn "python3 not found (needed from Phase 2)"
fi

if have docker; then
  if docker info >/dev/null 2>&1; then
    pass "Docker daemon reachable ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
  else
    fail "Docker CLI found but the daemon is not reachable. Try: sudo systemctl start docker  (and check 'groups' includes docker)"
  fi
  if id -nG | tr ' ' '\n' | grep -qx docker; then
    pass "User is in the docker group"
  else
    warn "User is not in the docker group (commands would need sudo). Run: sudo usermod -aG docker \$USER, then restart WSL."
  fi
else
  fail "docker not found. See docs/deployment.md (Docker Engine install)."
fi

for t in k3d kubectl helm; do
  want_var="$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')_VERSION"
  want="${!want_var}"
  if ! have "$t"; then
    fail "$t not found on PATH. Run: make tools-install (installs to ~/.local/bin; make sure that is on PATH)"
    continue
  fi
  got="$(tool_version "$t")"
  if [[ "$got" == "$want" ]]; then
    pass "$t $got (matches versions.env)"
  else
    warn "$t is ${got:-unknown}, versions.env pins $want. Run: make tools-install"
  fi
done

# ---------------------------------------------------------------- Config consistency
section "Configuration consistency"

if [[ -f "$CONFIG" ]]; then
  image="$(k3s_image_from_config "$CONFIG")"
  if [[ -n "$image" ]]; then
    pass "k3s image pinned in cluster.yaml: $image"
    k3s_minor="$(k3s_minor_from_image "$image")"
    kubectl_minor="$(semver_minor "$KUBECTL_VERSION")"
    diff=$((k3s_minor - kubectl_minor))
    diff=${diff#-}
    if [[ "$diff" -le 1 ]]; then
      pass "kubectl minor (1.$kubectl_minor) is within one minor of the cluster (1.$k3s_minor)"
    else
      fail "kubectl 1.$kubectl_minor vs cluster 1.$k3s_minor breaks the Kubernetes version-skew policy (max 1 minor apart)"
    fi

    # Kubernetes >= 1.35: the kubelet refuses to run on cgroup v1 by default.
    # WSL2 with an old kernel (e.g. 5.15) is cgroup v1. See docs/adr/README.md, ADR-16.
    cg="$(cgroup_fs_type)"
    if [[ "$cg" == "cgroup2fs" ]]; then
      pass "Host uses cgroup v2 (any supported Kubernetes version can run)"
    elif [[ "$k3s_minor" -ge 35 ]]; then
      fail "Host uses cgroup v1 (${cg:-unknown}) but cluster.yaml pins Kubernetes 1.$k3s_minor: the kubelet will not start. Pin a 1.34.x k3s image, or move WSL2 to cgroup v2 (docs/troubleshooting.md)."
    else
      warn "Host uses cgroup v1 (${cg:-unknown}); Kubernetes 1.$k3s_minor still works, but 1.35+ will not start until WSL2 moves to cgroup v2 (ADR-16)."
    fi
  else
    fail "No 'image:' line found in $CONFIG"
  fi
else
  fail "Missing $CONFIG"
fi

# ---------------------------------------------------------------- Cluster (informational)
section "Cluster (informational)"

if have docker && have k3d && have jq && docker info >/dev/null 2>&1; then
  name="$(cluster_name_from_config "$CONFIG")"
  if k3d cluster list -o json 2>/dev/null | jq -e --arg n "$name" '.[] | select(.name == $n)' >/dev/null 2>&1; then
    pass "k3d cluster '$name' exists"
  else
    log_info "k3d cluster '$name' does not exist yet. Create it with: make cluster-up"
    # A missing cluster means nothing of ours should hold these ports yet.
    if have ss; then
      for port in $(host_ports_from_config "$CONFIG"); do
        holder="$(ss -H -ltnp "sport = :$port" 2>/dev/null | head -n1)"
        if [[ -n "$holder" ]]; then
          fail "Host port $port is already in use (needed by cluster.yaml). Find it: ss -ltnp 'sport = :$port'; or a Docker container: docker ps --format '{{.Names}} {{.Ports}}' | grep $port"
        else
          pass "Host port $port is free"
        fi
      done
    else
      log_info "ss not found; skipping the host-port check"
    fi
  fi
else
  log_info "Skipped (needs docker, k3d and jq)"
fi

# ---------------------------------------------------------------- Summary
printf '\n== Summary ==\nPASS=%d  WARN=%d  FAIL=%d\n' "$PASS" "$WARN" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  log_fail "Fix the FAIL items above, then run: make doctor"
  exit 1
fi
if [[ "$WARN" -gt 0 ]]; then
  log_warn "No blocking problems. Review the warnings when convenient."
else
  log_ok "Environment is ready."
fi
exit 0
