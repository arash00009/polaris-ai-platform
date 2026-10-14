#!/usr/bin/env bash
# scripts/bootstrap/sealed-secrets.sh — Phase 15 / ADR-33: install, inspect, fetch the public
# cert of, and remove the sealed-secrets controller in its own `sealed-secrets` namespace. A
# separate concern from Argo CD, the observability stack and model-serving (each already has
# its own bootstrap script, its own namespace) -- this is a genuine Helm chart, so it follows
# scripts/bootstrap/observability.sh's shape (an `hctl()`/`kctl()` wrapper, --wait with a
# timeout, one subcommand per verb), not argocd.sh's kubectl-apply-a-manifest shape.
#
# SEALED_SECRETS_CHART_VERSION is deliberately left unpinned in versions.env (see its own Phase
# 15 comment for exactly why, and the "resolve for real, then pin" two-step this mirrors from
# Loki/Tempo/OpenCost) -- `install` below installs without --version, then prints the version
# Helm actually resolved (same install_release() pattern observability.sh already uses), to be
# pinned deliberately in a follow-up commit once a real target-machine install confirms it.
#
# Usage: scripts/bootstrap/sealed-secrets.sh <install|status|fetch-cert|uninstall>
# Normally invoked through the make targets (make sealed-secrets-install, ...).
#
# Status: written and shellchecked in the sandbox, where every values key this script's values
# file sets was confirmed for real against the chart's own templates (see
# deploy/platform/sealed-secrets/sealed-secrets-values.yaml's own comments) -- but there is no
# cluster, no `helm`, and no `kubeseal` binary in the sandbox (same constraint every previous
# phase's bootstrap/deploy script has carried). `install`/`status`/`fetch-cert`/`uninstall`
# against a real cluster are the target-machine verification step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

NAMESPACE="sealed-secrets"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
SS_DIR="deploy/platform/sealed-secrets"
VALUES_FILE="$SS_DIR/sealed-secrets-values.yaml"
RELEASE="sealed-secrets"
# Matches sealed-secrets-values.yaml's fullnameOverride -- the Service/Deployment name is this
# constant regardless of RELEASE above, which is why kubeseal's own --controller-name below can
# be a fixed value too.
CONTROLLER_NAME="sealed-secrets"
REPO_NAME="sealed-secrets"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
# 300s, not observability's 900s: this is one small, single-container Deployment pulling one
# image, not kube-prometheus-stack's several-image first pull -- closer to Argo CD's own
# original 180s than its 900s. Kept as its own named var (not a shared constant) for the same
# "a later timeout change to one already-verified script must never alter another's behaviour"
# reasoning ADR-22 already gives for this project's duplication in general.
ROLLOUT_TIMEOUT="${SEALED_SECRETS_ROLLOUT_TIMEOUT:-300s}"

hctl() { helm --kube-context "$CONTEXT" "$@"; }
kctl() { kubectl --context "$CONTEXT" "$@"; }

need_helm()     { have helm || die "helm not found. Run 'make tools-install'."; }
need_kubeseal() { have kubeseal || die "kubeseal not found. Run 'make tools-install'."; }
need_kubectl() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  local attempt
  for attempt in 1 2 3; do
    kctl get nodes >/dev/null 2>&1 && return 0
    [[ "$attempt" -lt 3 ]] && sleep 2
  done
  die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
}

cmd_install() {
  need_helm
  need_kubectl
  log_info "installing the sealed-secrets controller into '${NAMESPACE}'"
  kctl apply -f "$SS_DIR/namespace.yaml"
  hctl repo add "$REPO_NAME" "${SEALED_SECRETS_HELM_REPO:?SEALED_SECRETS_HELM_REPO is empty in versions.env}" >/dev/null
  log_info "helm repo update"
  hctl repo update >/dev/null

  local version_args=()
  if [[ -n "${SEALED_SECRETS_CHART_VERSION:-}" ]]; then
    version_args=(--version "$SEALED_SECRETS_CHART_VERSION")
  else
    log_warn "no SEALED_SECRETS_CHART_VERSION pinned in versions.env — installing whatever '$REPO_NAME/sealed-secrets' currently resolves to"
  fi
  log_info "helm upgrade --install $RELEASE ($REPO_NAME/sealed-secrets${SEALED_SECRETS_CHART_VERSION:+ @ $SEALED_SECRETS_CHART_VERSION})"
  hctl upgrade --install "$RELEASE" "$REPO_NAME/sealed-secrets" \
    -n "$NAMESPACE" -f "$VALUES_FILE" "${version_args[@]}" \
    --wait --timeout "$ROLLOUT_TIMEOUT"

  local resolved
  resolved="$(hctl list -n "$NAMESPACE" -o json | python3 -c "
import json, sys
rows = json.load(sys.stdin)
row = next((r for r in rows if r['name'] == '$RELEASE'), None)
print(row['chart'] if row else 'unknown')
")"
  if [[ -z "${SEALED_SECRETS_CHART_VERSION:-}" ]]; then
    log_warn "$RELEASE resolved to: $resolved — pin this in versions.env (see its Phase 15 comment) in a follow-up commit"
  else
    log_ok "$RELEASE installed at the pinned version: $resolved"
  fi
  log_info "Next: make gateway-seal ENV=dev — see docs/security/secrets-management.md"
}

cmd_status() {
  need_helm
  need_kubectl
  log_info "Helm release in '${NAMESPACE}'"
  hctl list -n "$NAMESPACE"
  echo
  log_info "Pods in '${NAMESPACE}'"
  kctl -n "$NAMESPACE" get pods -o wide
  echo
  log_info "SealedSecret CRD"
  kctl get crd sealedsecrets.bitnami.com 2>/dev/null \
    || log_warn "sealedsecrets.bitnami.com CRD not found yet (the controller's own install creates it; give it a moment after a fresh install)"
  echo
  log_info "SealedSecrets actually in the cluster (across the environments this controller watches)"
  for ns in polaris-dev polaris-staging polaris-prod; do
    kctl -n "$ns" get sealedsecrets.bitnami.com 2>/dev/null || true
  done
}

# Prints the controller's current public cert (PEM) to stdout — the one piece
# scripts/deploy/seal-gateway-secret.sh actually needs, and useful on its own to confirm the
# controller answers at all after a fresh install. Safe to redirect to a file and commit: this
# is a public key, used only to encrypt, never to decrypt (see ADR-33).
cmd_fetch_cert() {
  need_kubeseal
  need_kubectl
  kubeseal --fetch-cert \
    --controller-namespace "$NAMESPACE" \
    --controller-name "$CONTROLLER_NAME" \
    --context "$CONTEXT"
}

cmd_uninstall() {
  need_helm
  need_kubectl
  log_info "uninstalling the sealed-secrets controller from '${NAMESPACE}'"
  hctl uninstall "$RELEASE" -n "$NAMESPACE" --ignore-not-found
  kctl delete namespace "$NAMESPACE" --ignore-not-found
  log_ok "sealed-secrets controller removed."
  log_warn "Any SealedSecret already applied in polaris-dev/-staging/-prod is now undecryptable (the private key lived only in this namespace, gone with it) -- their last-materialised plain Secret is untouched by this uninstall, but will never be re-sealed/rotated without a fresh controller install AND re-sealing from the original plaintext (scripts/deploy/seal-gateway-secret.sh), not from the old SealedSecret. This is the real, inherent trade-off Sealed Secrets makes for GitOps-safety (docs/security/secrets-management.md) -- not a bug in this script."
}

CMD="${1:-}"
case "$CMD" in
  install)      cmd_install ;;
  status)       cmd_status ;;
  fetch-cert)   cmd_fetch_cert ;;
  uninstall)    cmd_uninstall ;;
  *)
    echo "Usage: $0 <install|status|fetch-cert|uninstall>" >&2
    exit 1
    ;;
esac
