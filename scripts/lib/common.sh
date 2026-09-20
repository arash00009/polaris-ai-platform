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
tool_version() {
  {
    case "$1" in
      k3d)     k3d version 2>/dev/null | head -n1 ;;
      kubectl) kubectl version --client 2>/dev/null | head -n1 ;;
      helm)    helm version --short 2>/dev/null || helm version 2>/dev/null ;;
      *)       return 0 ;;
    esac
  } | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# "v1.35.8" -> "35"
semver_minor() { sed -E 's/^v?[0-9]+\.([0-9]+)\..*/\1/' <<<"$1"; }

# Read the top-level `image:` value from a k3d config file.
k3s_image_from_config() { awk '/^image:/ {print $2; exit}' "$1"; }

# Read metadata.name from a k3d config file.
cluster_name_from_config() {
  awk '/^metadata:/ {f=1; next} f && /^[[:space:]]+name:/ {print $2; exit}' "$1"
}

# "rancher/k3s:v1.35.8-k3s1" -> "35"
k3s_minor_from_image() { sed -E 's/.*:v[0-9]+\.([0-9]+)\..*/\1/' <<<"$1"; }
