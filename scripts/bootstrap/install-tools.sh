#!/usr/bin/env bash
# scripts/bootstrap/install-tools.sh
# Install pinned versions of k3d, kubectl and helm without sudo.
# Every download is verified against the checksum the project publishes.
#
# Usage: scripts/bootstrap/install-tools.sh [--prefix DIR] [--only k3d|kubectl|helm] [--force]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions

PREFIX="${HOME}/.local/bin"
ONLY=""
FORCE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--prefix DIR] [--only k3d|kubectl|helm] [--force]

  --prefix DIR   install directory (default: \$HOME/.local/bin)
  --only TOOL    install just one tool
  --force        reinstall even if the pinned version is already present

Pinned versions come from versions.env.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --only)   ONLY="${2:?--only needs a tool name}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || die "This installer supports Linux (WSL2) only."
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

for c in curl sha256sum tar awk install; do
  have "$c" || die "Missing required command: $c (try: sudo apt-get install -y curl coreutils tar gawk)"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$PREFIX"
ORIGINAL_PATH="$PATH"
export PATH="$PREFIX:$PATH"

download() { # url dest
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$2" "$1" || die "Download failed: $1"
}

verify_sha256() { # file expected
  local actual
  actual="$(sha256sum "$1" | awk '{print $1}')"
  [[ -n "$2" ]] || die "Empty expected checksum for $(basename "$1")"
  [[ "$actual" == "$2" ]] || die "Checksum mismatch for $(basename "$1"): expected $2, got $actual"
  log_ok "Checksum verified for $(basename "$1")"
}

# needs_install TOOL WANTED_VERSION -> returns 0 if the tool should be installed
needs_install() {
  if [[ -n "$ONLY" && "$ONLY" != "$1" ]]; then
    return 1
  fi
  if [[ "$FORCE" -eq 1 ]]; then
    return 0
  fi
  local current
  current="$(tool_version "$1")"
  if [[ "$current" == "$2" ]]; then
    log_ok "$1 $2 already installed"
    return 1
  fi
  return 0
}

install_k3d() {
  needs_install k3d "$K3D_VERSION" || return 0
  local base="https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}"
  local asset="k3d-linux-${ARCH}"
  log_info "Installing k3d ${K3D_VERSION} (${ARCH})"
  download "$base/$asset" "$TMP/$asset"
  download "$base/checksums.txt" "$TMP/k3d-checksums.txt"
  local expected
  expected="$(awk -v a="$asset" '$2 ~ (a "$") {print $1; exit}' "$TMP/k3d-checksums.txt")"
  [[ -n "$expected" ]] || die "No checksum entry for $asset in k3d checksums.txt"
  verify_sha256 "$TMP/$asset" "$expected"
  install -m 0755 "$TMP/$asset" "$PREFIX/k3d"
  log_ok "k3d installed to $PREFIX/k3d"
}

install_kubectl() {
  needs_install kubectl "$KUBECTL_VERSION" || return 0
  local base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}"
  log_info "Installing kubectl ${KUBECTL_VERSION} (${ARCH})"
  download "$base/kubectl" "$TMP/kubectl"
  download "$base/kubectl.sha256" "$TMP/kubectl.sha256"
  verify_sha256 "$TMP/kubectl" "$(awk '{print $1}' "$TMP/kubectl.sha256")"
  install -m 0755 "$TMP/kubectl" "$PREFIX/kubectl"
  log_ok "kubectl installed to $PREFIX/kubectl"
}

install_helm() {
  needs_install helm "$HELM_VERSION" || return 0
  local tarball="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  log_info "Installing helm ${HELM_VERSION} (${ARCH})"
  download "https://get.helm.sh/${tarball}" "$TMP/$tarball"
  download "https://get.helm.sh/${tarball}.sha256sum" "$TMP/${tarball}.sha256sum"
  verify_sha256 "$TMP/$tarball" "$(awk '{print $1}' "$TMP/${tarball}.sha256sum")"
  tar -xzf "$TMP/$tarball" -C "$TMP"
  install -m 0755 "$TMP/linux-${ARCH}/helm" "$PREFIX/helm"
  log_ok "helm installed to $PREFIX/helm"
}

case "$ONLY" in
  ""|k3d|kubectl|helm) ;;
  *) die "--only must be one of: k3d, kubectl, helm" ;;
esac

install_k3d
install_kubectl
install_helm

if [[ ":$ORIGINAL_PATH:" != *":$PREFIX:"* ]]; then
  log_warn "$PREFIX is not on your PATH. Add it permanently with:"
  # shellcheck disable=SC2016
  printf '       echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc && source ~/.bashrc\n' "$PREFIX"
fi
