#!/usr/bin/env bash
# scripts/bootstrap/argocd.sh — Phase 8: install, inspect, get the initial admin password for,
# and remove the Argo CD control plane in its own `argocd` namespace. A separate concern from
# the workloads it will manage in polaris-dev/-staging/-prod (ADR-26).
#
# Unlike k3d/kubectl/helm (scripts/bootstrap/install-tools.sh), Argo CD is not a local binary --
# it is a set of in-cluster Deployments/StatefulSet/CRDs applied from the project's official
# install manifest. That manifest has no published checksums file the way k3d/kubectl/gitleaks/
# actionlint's release assets do, so the pin in versions.env works like PYTHON_BASE_DIGEST/
# TRIVY_IMAGE_DIGEST instead: the manifest was downloaded once for a specific tag, its sha256
# computed and committed, and every future download here is checked against that fixed value —
# an unexpected change (a re-tagged release, a compromised mirror) fails loudly instead of
# silently applying different YAML than was ever reviewed. download()/verify_sha256() below are
# deliberately duplicated from install-tools.sh rather than shared, same reasoning as helm.sh's
# header comment: a change here must never alter a previous phase's already-verified script.
#
# Usage: scripts/bootstrap/argocd.sh <install|status|password|uninstall>
# Normally invoked through the make targets (make argocd-install, make argocd-status, ...).
#
# Status: written and shellchecked in the sandbox, where the install manifest was downloaded for
# real (raw.githubusercontent.com is reachable here, unlike get.helm.sh/dl.k8s.io) and its sha256
# verified against the value now pinned in versions.env, but there is no cluster in the sandbox to
# install into. `install`/`status`/`password`/`uninstall` against a real cluster are the
# target-machine verification step, same pattern as every previous phase's bootstrap/deploy script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

NAMESPACE="argocd"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Every Deployment and StatefulSet the pinned install manifest creates, confirmed by parsing it
# with Python's yaml.safe_load_all in the sandbox: 59 documents total, 6 Deployments, 1
# StatefulSet (see docs/adr/README.md ADR-26 for the full kind count). If a future Argo CD
# release adds or renames a workload, this list simply will not know about it — 'make
# argocd-status' always shows the ground truth via 'kubectl -n argocd get deploy,sts'.
DEPLOYMENTS=(argocd-applicationset-controller argocd-dex-server argocd-notifications-controller argocd-redis argocd-repo-server argocd-server)
STATEFULSETS=(argocd-application-controller)

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
ROLLOUT_TIMEOUT="${ARGOCD_ROLLOUT_TIMEOUT:-180s}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

kctl() { kubectl --context "$CONTEXT" "$@"; }

need_kubectl() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  kctl get nodes >/dev/null 2>&1 \
    || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
}

download() { curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$2" "$1" || die "Download failed: $1"; }

verify_sha256() { # file expected
  local actual
  actual="$(sha256sum "$1" | awk '{print $1}')"
  [[ -n "$2" ]] || die "ARGOCD_INSTALL_SHA256 is empty in versions.env"
  [[ "$actual" == "$2" ]] || die "Checksum mismatch for the Argo CD ${ARGOCD_VERSION} install manifest: expected $2, got $actual. Refusing to apply unverified YAML into the cluster."
  log_ok "Checksum verified for the Argo CD ${ARGOCD_VERSION} install manifest"
}

# Downloads and checksum-verifies the pinned manifest, writes it to $MANIFEST, and never lets any
# log line leak into a caller that captures this function's stdout.
fetch_manifest() {
  MANIFEST="$TMP/argocd-install.yaml"
  log_info "downloading the Argo CD ${ARGOCD_VERSION} install manifest"
  download "$MANIFEST_URL" "$MANIFEST"
  verify_sha256 "$MANIFEST" "${ARGOCD_INSTALL_SHA256:-}"
}

cmd_install() {
  need_kubectl
  log_info "installing Argo CD ${ARGOCD_VERSION} into the '${NAMESPACE}' namespace"
  fetch_manifest

  kctl get namespace "$NAMESPACE" >/dev/null 2>&1 || kctl create namespace "$NAMESPACE"
  kctl apply -n "$NAMESPACE" -f "$MANIFEST"

  log_info "waiting for ${#DEPLOYMENTS[@]} Deployments and ${#STATEFULSETS[@]} StatefulSet to roll out (timeout ${ROLLOUT_TIMEOUT} each)"
  local d
  for d in "${DEPLOYMENTS[@]}"; do
    kctl -n "$NAMESPACE" rollout status "deployment/$d" --timeout="$ROLLOUT_TIMEOUT" \
      || die "deployment/$d did not become ready. Inspect it with: kubectl --context $CONTEXT -n $NAMESPACE describe deployment/$d"
  done
  local s
  for s in "${STATEFULSETS[@]}"; do
    kctl -n "$NAMESPACE" rollout status "statefulset/$s" --timeout="$ROLLOUT_TIMEOUT" \
      || die "statefulset/$s did not become ready. Inspect it with: kubectl --context $CONTEXT -n $NAMESPACE describe statefulset/$s"
  done

  log_ok "Argo CD ${ARGOCD_VERSION} is up in '${NAMESPACE}'. Initial admin password: make argocd-password"
  log_info "Next: make gitops-bootstrap GITOPS_DIR=/path/to/polaris-gitops"
}

cmd_status() {
  need_kubectl
  log_info "Argo CD Applications (sync/health per the Application CRD — verified with kubectl, not the argocd CLI, ADR-26)"
  if ! kctl -n "$NAMESPACE" get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null; then
    log_warn "no Applications found yet (run 'make gitops-bootstrap' after 'make argocd-install')"
  fi
  echo
  log_info "Argo CD control plane pods"
  kctl -n "$NAMESPACE" get pods -o wide
}

cmd_password() {
  need_kubectl
  have base64 || die "base64 not found"
  local pw
  pw="$(kctl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" \
    || die "argocd-initial-admin-secret not found. Is Argo CD installed (make argocd-install)? Note: Argo CD deletes this secret the first time the admin password is changed."
  [[ -n "$pw" ]] || die "argocd-initial-admin-secret exists but is empty (password already rotated?)"
  printf 'admin / %s\n' "$pw"
}

cmd_uninstall() {
  need_kubectl
  log_info "uninstalling Argo CD ${ARGOCD_VERSION} (re-downloads and re-verifies the same pinned manifest, so 'delete' removes exactly what 'install' created)"
  fetch_manifest
  kctl delete -n "$NAMESPACE" -f "$MANIFEST" --ignore-not-found
  kctl delete namespace "$NAMESPACE" --ignore-not-found
  log_ok "Argo CD removed. polaris-dev/-staging/-prod and their workloads are untouched — Kubernetes has no ownership link from a Deployment/Service/etc. back to the Application CRD that created it, so deleting Argo CD never cascades into the namespaces it was managing (see docs/troubleshooting.md, Phase 8)."
}

CMD="${1:-}"
case "$CMD" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  password)  cmd_password ;;
  uninstall) cmd_uninstall ;;
  *)
    echo "Usage: $0 <install|status|password|uninstall>" >&2
    exit 1
    ;;
esac
