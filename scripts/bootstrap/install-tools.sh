#!/usr/bin/env bash
# scripts/bootstrap/install-tools.sh
# Install pinned versions of k3d, kubectl, helm, gitleaks, actionlint, kubeseal and cosign
# without sudo. Every download is verified against the checksum the project publishes (kubeseal:
# see its own function below and versions.env's Phase 15 comment for why that is a
# sandbox-computed checksum rather than a published checksums.txt; cosign DOES publish one, so it
# follows the k3d/gitleaks/actionlint pattern instead).
#
# gitleaks and actionlint (Phase 6) are local-dev conveniences too — the CI workflow installs
# its own copies the same way, in the runner, since a GitHub-hosted runner starts from nothing
# every time. This script is the one place both paths share the version pins and the download
# logic, so a version bump here is a version bump everywhere. kubeseal (Phase 15 session 1) is
# local-dev/target-machine only — nothing in CI seals a secret, so the workflow never needs its
# own copy. cosign (Phase 15 session 2) is the opposite of kubeseal in that respect: the CI
# `publish` job installs its own copy the same way gitleaks/actionlint do (`--only cosign`), to
# sign the image it just pushed with a real GitHub Actions OIDC token — see
# .github/workflows/ci.yml and ADR-35. Darya also gets a local copy, for `make cosign-verify`.
#
# Usage: scripts/bootstrap/install-tools.sh [--prefix DIR] [--only k3d|kubectl|helm|gitleaks|actionlint|kubeseal|cosign] [--force]
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
  --only TOOL    install just one tool (k3d, kubectl, helm, gitleaks, actionlint, kubeseal, cosign)
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

# gitleaks names its Linux amd64 asset "x64", not "amd64" like k3d/kubectl/helm.
GITLEAKS_ARCH="$ARCH"
[[ "$GITLEAKS_ARCH" == "amd64" ]] && GITLEAKS_ARCH="x64"

install_gitleaks() {
  needs_install gitleaks "$GITLEAKS_VERSION" || return 0
  local ver="${GITLEAKS_VERSION#v}"
  local base="https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VERSION}"
  local asset="gitleaks_${ver}_linux_${GITLEAKS_ARCH}.tar.gz"
  log_info "Installing gitleaks ${GITLEAKS_VERSION} (${GITLEAKS_ARCH})"
  download "$base/$asset" "$TMP/$asset"
  download "$base/gitleaks_${ver}_checksums.txt" "$TMP/gitleaks-checksums.txt"
  local expected
  expected="$(awk -v a="$asset" '$2 == a {print $1; exit}' "$TMP/gitleaks-checksums.txt")"
  [[ -n "$expected" ]] || die "No checksum entry for $asset in gitleaks checksums.txt"
  verify_sha256 "$TMP/$asset" "$expected"
  tar -xzf "$TMP/$asset" -C "$TMP" gitleaks
  install -m 0755 "$TMP/gitleaks" "$PREFIX/gitleaks"
  log_ok "gitleaks installed to $PREFIX/gitleaks"
}

install_actionlint() {
  needs_install actionlint "$ACTIONLINT_VERSION" || return 0
  local ver="${ACTIONLINT_VERSION#v}"
  local base="https://github.com/rhysd/actionlint/releases/download/${ACTIONLINT_VERSION}"
  local asset="actionlint_${ver}_linux_${ARCH}.tar.gz"
  log_info "Installing actionlint ${ACTIONLINT_VERSION} (${ARCH})"
  download "$base/$asset" "$TMP/$asset"
  download "$base/actionlint_${ver}_checksums.txt" "$TMP/actionlint-checksums.txt"
  local expected
  expected="$(awk -v a="$asset" '$2 == a {print $1; exit}' "$TMP/actionlint-checksums.txt")"
  [[ -n "$expected" ]] || die "No checksum entry for $asset in actionlint checksums.txt"
  verify_sha256 "$TMP/$asset" "$expected"
  tar -xzf "$TMP/$asset" -C "$TMP" actionlint
  install -m 0755 "$TMP/actionlint" "$PREFIX/actionlint"
  log_ok "actionlint installed to $PREFIX/actionlint"
}

# kubeseal (Phase 15): unlike every tool above, this release publishes no discoverable
# checksums.txt asset (versions.env's Phase 15 comment records exactly which filenames were
# checked and 404'd), so the expected digest is a sandbox-computed, per-arch constant instead of
# a value parsed out of a downloaded checksums file.
install_kubeseal() {
  needs_install kubeseal "$KUBESEAL_VERSION" || return 0
  local ver="${KUBESEAL_VERSION#v}"
  local base="https://github.com/bitnami-labs/sealed-secrets/releases/download/${KUBESEAL_VERSION}"
  local asset="kubeseal-${ver}-linux-${ARCH}.tar.gz"
  local expected
  case "$ARCH" in
    amd64) expected="$KUBESEAL_SHA256_AMD64" ;;
    arm64) expected="$KUBESEAL_SHA256_ARM64" ;;
    *) die "No pinned kubeseal checksum for architecture '$ARCH'" ;;
  esac
  log_info "Installing kubeseal ${KUBESEAL_VERSION} (${ARCH})"
  download "$base/$asset" "$TMP/$asset"
  verify_sha256 "$TMP/$asset" "$expected"
  tar -xzf "$TMP/$asset" -C "$TMP" kubeseal
  install -m 0755 "$TMP/kubeseal" "$PREFIX/kubeseal"
  log_ok "kubeseal installed to $PREFIX/kubeseal"
}

# cosign (Phase 15 session 2): unlike kubeseal, this release DOES publish a real checksums.txt
# asset (`cosign_checksums.txt`, confirmed reachable from github.com in this sandbox) -- the
# standard k3d/gitleaks/actionlint pattern applies, and the release assets are bare binaries
# named "cosign-linux-<arch>" (no .tar.gz to extract), unlike every tool above except kubectl.
install_cosign() {
  needs_install cosign "$COSIGN_VERSION" || return 0
  local base="https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}"
  local asset="cosign-linux-${ARCH}"
  local expected
  case "$ARCH" in
    amd64) expected="$COSIGN_SHA256_AMD64" ;;
    arm64) expected="$COSIGN_SHA256_ARM64" ;;
    *) die "No pinned cosign checksum for architecture '$ARCH'" ;;
  esac
  log_info "Installing cosign ${COSIGN_VERSION} (${ARCH})"
  download "$base/$asset" "$TMP/$asset"
  verify_sha256 "$TMP/$asset" "$expected"
  install -m 0755 "$TMP/$asset" "$PREFIX/cosign"
  log_ok "cosign installed to $PREFIX/cosign"
}

case "$ONLY" in
  ""|k3d|kubectl|helm|gitleaks|actionlint|kubeseal|cosign) ;;
  *) die "--only must be one of: k3d, kubectl, helm, gitleaks, actionlint, kubeseal, cosign" ;;
esac

install_k3d
install_kubectl
install_helm
install_gitleaks
install_actionlint
install_kubeseal
install_cosign

if [[ ":$ORIGINAL_PATH:" != *":$PREFIX:"* ]]; then
  log_warn "$PREFIX is not on your PATH. Add it permanently with:"
  # shellcheck disable=SC2016
  printf '       echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc && source ~/.bashrc\n' "$PREFIX"
fi
