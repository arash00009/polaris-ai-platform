#!/usr/bin/env bash
# scripts/lib/common.sh — shared helpers. Source this file; do not execute it.
# shellcheck shell=bash

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_RESET=""
fi

log_info() { printf '%s[info]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()      { log_fail "$*"; exit 1; }

# Absolute path of the repository root (two levels above scripts/lib).
repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "$here/../.." && pwd)
}

# Export every variable defined in versions.env.
load_versions() {
  local root
  root="$(repo_root)"
  [[ -f "$root/versions.env" ]] || die "versions.env not found in $root"
  set -a
  # shellcheck source=/dev/null
  source "$root/versions.env"
  set +a
}

have() { command -v "$1" >/dev/null 2>&1; }

# Print the first semantic version (vX.Y.Z) a tool reports, or nothing.
# gitleaks and actionlint print their version without a leading "v" (e.g. "8.30.0"), unlike
# k3d/kubectl/helm; one is added back so every pin in versions.env can be compared the same way.
tool_version() {
  case "$1" in
    gitleaks|actionlint)
      local raw
      raw="$(
        case "$1" in
          gitleaks)   gitleaks version 2>/dev/null ;;
          actionlint) actionlint -version 2>/dev/null | head -n1 ;;
        esac
      )"
      [[ -n "$raw" ]] || return 0
      printf 'v%s' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$raw" | head -n1)"
      return 0
      ;;
  esac
  {
    case "$1" in
      k3d)     k3d version 2>/dev/null | head -n1 ;;
      kubectl) kubectl version --client 2>/dev/null | head -n1 ;;
      helm)    helm version --short 2>/dev/null || helm version 2>/dev/null ;;
      *)       return 0 ;;
    esac
  } | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# "v1.34.10" -> "34"
semver_minor() { sed -E 's/^v?[0-9]+\.([0-9]+)\..*/\1/' <<<"$1"; }

# Read the top-level `image:` value from a k3d config file.
k3s_image_from_config() { awk '/^image:/ {print $2; exit}' "$1"; }

# Read metadata.name from a k3d config file.
cluster_name_from_config() {
  awk '/^metadata:/ {f=1; next} f && /^[[:space:]]+name:/ {print $2; exit}' "$1"
}

# "rancher/k3s:v1.34.10-k3s1" -> "34"
k3s_minor_from_image() { sed -E 's/.*:v[0-9]+\.([0-9]+)\..*/\1/' <<<"$1"; }

# Host port that the k3d load balancer maps to container port $2 (e.g. 80 -> 8088).
# Reads "- port: HOST:CONTAINER" lines from a k3d config file.
host_port_for() {
  awk -v want="$2" '/^[[:space:]]*-[[:space:]]*port:/ {
    split($3, a, ":"); if (a[2] == want) { print a[1]; exit }
  }' "$1"
}

# All host ports a k3d config publishes (load balancer ports + registry hostPort), one per line.
host_ports_from_config() {
  awk '
    /^[[:space:]]*-[[:space:]]*port:/ { split($3, a, ":"); print a[1] }
    /^[[:space:]]*hostPort:/ { gsub(/"/, "", $2); print $2 }
  ' "$1"
}

# "tmpfs" (cgroup v1 / hybrid) or "cgroup2fs" (cgroup v2) for the host.
cgroup_fs_type() { stat -fc %T /sys/fs/cgroup 2>/dev/null || true; }
