#!/usr/bin/env bash
# scripts/bootstrap/argo-rollouts.sh — Phase 18: install, inspect, and remove the Argo Rollouts
# controller in its own `argo-rollouts` namespace (ADR-39), the same separate-control-plane
# pattern argocd.sh already uses for Argo CD (ADR-26).
#
# Like Argo CD, Argo Rollouts is not a local binary -- it is a set of in-cluster CRDs/ServiceAccount/
# ClusterRole(Binding)/ConfigMap/Secret/Service/Deployment applied from the project's official
# install manifest, confirmed by parsing it with Python's yaml.safe_load_all in the sandbox: 15
# documents total, 5 CustomResourceDefinitions, 1 ServiceAccount, 4 ClusterRoles, 1
# ClusterRoleBinding, 1 ConfigMap (argo-rollouts-config), 1 Secret
# (argo-rollouts-notification-secret), 1 Service (argo-rollouts-metrics), 1 Deployment
# (argo-rollouts). That manifest has no published checksums file, so the pin in versions.env
# works the same way ARGOCD_INSTALL_SHA256 does: downloaded once for a specific tag, its sha256
# computed and committed, every future download checked against that fixed value.
# download()/verify_sha256() below are deliberately duplicated from argocd.sh/install-tools.sh,
# same reasoning as every other bootstrap script's header comment: a change here must never
# alter a previous phase's already-verified script.
#
# Usage: scripts/bootstrap/argo-rollouts.sh <install|status|dashboard|uninstall>
# Normally invoked through the make targets (make rollout-install, make rollout-status, ...).
#
# Status: written and shellchecked in the sandbox, where the install manifest was downloaded for
# real (github.com is reachable here) and its sha256 verified against the value now pinned in
# versions.env, but there is no cluster in the sandbox to install into. `install`/`status`/
# `uninstall` against a real cluster are the target-machine verification step, same pattern as
# every previous phase's bootstrap script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

NAMESPACE="argo-rollouts"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
MANIFEST_URL="https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml"

# The one Deployment the pinned install manifest creates (unlike Argo CD, which has six
# Deployments and a StatefulSet) -- confirmed the same way, by parsing the real manifest.
DEPLOYMENTS=(argo-rollouts)

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
# Argo Rollouts' own image is much smaller than Argo CD's quay.io/argoproj/argocd (one
# lightweight controller image, not six services' worth), so the 900s cold-pull margin Phase 8
# needed for Argo CD is not expected to apply here -- 180s, overridable, same as every other
# bootstrap script's *_ROLLOUT_TIMEOUT pattern.
ROLLOUT_TIMEOUT="${ARGO_ROLLOUTS_ROLLOUT_TIMEOUT:-180s}"

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
  [[ -n "$2" ]] || die "ARGO_ROLLOUTS_INSTALL_SHA256 is empty in versions.env"
  [[ "$actual" == "$2" ]] || die "Checksum mismatch for the Argo Rollouts ${ARGO_ROLLOUTS_VERSION} install manifest: expected $2, got $actual. Refusing to apply unverified YAML into the cluster."
  log_ok "Checksum verified for the Argo Rollouts ${ARGO_ROLLOUTS_VERSION} install manifest"
}

fetch_manifest() {
  MANIFEST="$TMP/argo-rollouts-install.yaml"
  log_info "downloading the Argo Rollouts ${ARGO_ROLLOUTS_VERSION} install manifest"
  download "$MANIFEST_URL" "$MANIFEST"
  verify_sha256 "$MANIFEST" "${ARGO_ROLLOUTS_INSTALL_SHA256:-}"
}

cmd_install() {
  need_kubectl
  log_info "installing Argo Rollouts ${ARGO_ROLLOUTS_VERSION} into the '${NAMESPACE}' namespace"
  fetch_manifest

  kctl get namespace "$NAMESPACE" >/dev/null 2>&1 || kctl create namespace "$NAMESPACE"
  # --server-side (not a plain client-side 'kubectl apply -f'), same reasoning as argocd.sh: the
  # CustomResourceDefinitions in this manifest can carry a large enough OpenAPIV3Schema to hit
  # client-side apply's 262144-byte last-applied-configuration annotation cap.
  kctl apply -n "$NAMESPACE" --server-side --force-conflicts -f "$MANIFEST"

  log_info "waiting for ${#DEPLOYMENTS[@]} Deployment to roll out (timeout ${ROLLOUT_TIMEOUT})"
  local d
  for d in "${DEPLOYMENTS[@]}"; do
    kctl -n "$NAMESPACE" rollout status "deployment/$d" --timeout="$ROLLOUT_TIMEOUT" \
      || die "deployment/$d did not become ready. Inspect it with: kubectl --context $CONTEXT -n $NAMESPACE describe deployment/$d"
  done

  log_ok "Argo Rollouts ${ARGO_ROLLOUTS_VERSION} is up in '${NAMESPACE}'."
  log_info "Next: make canary-demo-good (or canary-demo-bad) to watch a real canary promote or auto-rollback"
}

cmd_status() {
  need_kubectl
  log_info "Argo Rollouts controller pods"
  kctl -n "$NAMESPACE" get pods -o wide
  echo
  log_info "ai-service Rollout (sync/health per the Rollout CRD)"
  if ! kctl -n polaris-dev get rollout ai-service -o custom-columns='NAME:.metadata.name,STRATEGY:.spec.strategy.canary,STATUS:.status.phase' 2>/dev/null; then
    log_warn "no ai-service Rollout found yet in polaris-dev (run 'make app-install' with this phase's chart applied)"
  fi
}

cmd_dashboard() {
  need_kubectl
  have kubectl-argo-rollouts || die "kubectl-argo-rollouts not found. Run 'make tools-install ARGS=\"--only kubectl-argo-rollouts\"'."
  log_info "Argo Rollouts dashboard on http://localhost:3100 (Ctrl-C to stop)."
  # kubectl-argo-rollouts is a kubectl plugin binary, built on the same client-go flag parsing as
  # kubectl itself, so --context works the same way the kctl() wrapper's calls above use it.
  kubectl-argo-rollouts --context "$CONTEXT" -n polaris-dev dashboard
}

cmd_uninstall() {
  need_kubectl
  log_info "uninstalling Argo Rollouts ${ARGO_ROLLOUTS_VERSION} (re-downloads and re-verifies the same pinned manifest, so 'delete' removes exactly what 'install' created)"
  fetch_manifest
  kctl delete -n "$NAMESPACE" -f "$MANIFEST" --ignore-not-found
  kctl delete namespace "$NAMESPACE" --ignore-not-found
  log_ok "Argo Rollouts removed. Any Rollout resources it was managing (e.g. ai-service in polaris-dev) are untouched -- same no-cascade reasoning as Argo CD's own uninstall (docs/troubleshooting.md, Phase 8), but a Rollout with no controller watching it simply stops progressing; it does not revert to a plain Deployment on its own."
}

CMD="${1:-}"
case "$CMD" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  dashboard) cmd_dashboard ;;
  uninstall) cmd_uninstall ;;
  *)
    echo "Usage: $0 <install|status|dashboard|uninstall>" >&2
    exit 1
    ;;
esac
