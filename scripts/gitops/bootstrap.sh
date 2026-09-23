#!/usr/bin/env bash
# scripts/gitops/bootstrap.sh — Phase 8: apply polaris-gitops' app-of-apps root Application
# (bootstrap/root-app.yaml) into the argocd namespace, once.
#
# This is deliberately the *only* manual `kubectl apply` in the whole GitOps flow. Everything
# after it — creating apps/dev-app.yaml's Application, syncing it, reconciling drift — is Argo CD
# itself pulling from polaris-gitops on its own schedule, not this script (ADR-26; the GitOps flow
# diagram in docs/architecture.md: "pull not push", "Git is the single source of truth").
#
# polaris-ai-platform and polaris-gitops are separate repositories (ADR-08): this script expects
# a local checkout of polaris-gitops, by default as a sibling of this repository
# (~/polaris/polaris-gitops next to ~/polaris/polaris-ai-platform), overridable with an explicit
# path or GITOPS_DIR.
#
# Usage: scripts/gitops/bootstrap.sh [GITOPS_DIR]
# Normally invoked through: make gitops-bootstrap [GITOPS_DIR=/path/to/polaris-gitops]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"

GITOPS_DIR="${1:-$ROOT/../polaris-gitops}"
ROOT_APP="$GITOPS_DIR/bootstrap/root-app.yaml"

kctl() { kubectl --context "$CONTEXT" "$@"; }

[[ -f "$ROOT_APP" ]] || die "Root Application not found: $ROOT_APP. Clone polaris-gitops next to this repository, or pass its path: scripts/gitops/bootstrap.sh /path/to/polaris-gitops"

have kubectl || die "kubectl not found. Run 'make doctor'."
kctl get nodes >/dev/null 2>&1 \
  || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
kctl get namespace argocd >/dev/null 2>&1 \
  || die "The 'argocd' namespace does not exist yet. Run 'make argocd-install' first."

log_info "applying $ROOT_APP (app-of-apps root) into the argocd namespace"
kctl apply -f "$ROOT_APP"
log_ok "root Application applied. Argo CD now reconciles apps/*.yaml from $GITOPS_DIR on its own — watch it with: make argocd-status"
