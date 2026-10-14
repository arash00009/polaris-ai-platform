#!/usr/bin/env bash
# scripts/deploy/seal-gateway-secret.sh — Phase 15 / ADR-33: seal the real, local, gitignored
# api_key->tenant_id map (deploy/platform/gateway/api-keys.<env>.local.json) against a real
# sealed-secrets controller, and print the resulting ciphertext ready to paste into
# helm/ai-platform/values-<env>.yaml's `gateway.apiKeysSealed` (see that file's own Phase 15
# comment for the exact two lines to uncomment).
#
# Deliberately a standalone script, not a new subcommand bolted onto scripts/deploy/helm.sh --
# ADR-22's own reasoning: a later change to one already-verified script must never alter
# another's behaviour by accident, and this one has nothing in common with helm.sh's lint/
# template/apply/status/logs/smoke/uninstall verbs beyond also reading the same local JSON file
# (gateway_api_keys_json_for() there is deliberately re-derived here, not sourced).
#
# What this does NOT do: write anything back into the chart's values files, or run `helm
# upgrade` -- it only prints the ciphertext. Pasting it into values-dev.yaml, uncommenting
# sealedSecrets.enabled, committing, and running `make helm-apply-dev` (or letting Argo CD sync
# it) is a deliberate, separate, reviewable step -- the same "print the result, let the human
# commit it" shape versions.env's own "resolve for real, then pin" convention already uses for
# a chart version, applied here to a secret's ciphertext instead.
#
# Usage: scripts/deploy/seal-gateway-secret.sh <dev|staging|prod>
# Normally invoked through the make target (make gateway-seal ENV=dev).
#
# Status: written and shellchecked in the sandbox. Cannot be run for real there -- no cluster,
# no `kubeseal`, and the one real input (api-keys.dev.local.json) is itself a target-machine-only
# file (gitignored, never committed, per templates/gateway-secret.yaml's own comment). Running
# this against a real controller and pasting its real output is the target-machine verification
# step for ADR-33's whole premise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
GATEWAY_KEYS_DIR="deploy/platform/gateway"
SS_NAMESPACE="sealed-secrets"
SS_CONTROLLER_NAME="sealed-secrets"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"

ENV="${1:-}"
case "$ENV" in
  dev|staging|prod) ;;
  *) die "Usage: $0 <dev|staging|prod>" ;;
esac

need_kubeseal() { have kubeseal || die "kubeseal not found. Run 'make tools-install'."; }
need_kubectl() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  kubectl --context "$CONTEXT" get nodes >/dev/null 2>&1 \
    || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
}
need_controller() {
  kubectl --context "$CONTEXT" -n "$SS_NAMESPACE" get deployment "$SS_CONTROLLER_NAME" >/dev/null 2>&1 \
    || die "sealed-secrets controller not found in '$SS_NAMESPACE'. Run 'make sealed-secrets-install' first."
}
# Same resolution as scripts/deploy/helm.sh's own gateway_api_keys_json_for() -- re-derived
# here rather than sourced, per ADR-22.
KEYS_FILE="$GATEWAY_KEYS_DIR/api-keys.$ENV.local.json"
[[ -f "$KEYS_FILE" ]] || die "$KEYS_FILE not found. See $GATEWAY_KEYS_DIR/api-keys.$ENV.example.json for the format -- this must hold real tenant keys before sealing an empty map is pointless."

need_kubeseal
need_kubectl
need_controller

NAMESPACE_FOR_SECRET="polaris-$ENV"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log_info "building a plain Secret manifest from $KEYS_FILE (never written to disk outside \$TMP, never logged)"
# Builds the exact shape templates/gateway-secret.yaml itself renders (same name, namespace,
# type, key) so kubeseal's own encryptedData key ends up named identically either way --
# kubectl's own JSON/YAML generation, not a hand-written heredoc, so the real file's content is
# never re-typed or shell-interpolated (the same risk class a `--set-string` JSON blob already
# hit for real once, per ADR-30's own bug writeup).
kubectl --context "$CONTEXT" create secret generic ai-gateway-api-keys \
  --namespace "$NAMESPACE_FOR_SECRET" \
  --from-file "GATEWAY_API_KEYS_JSON=$KEYS_FILE" \
  --dry-run=client -o yaml > "$TMP/plain-secret.yaml"

log_info "sealing against the real controller in '$SS_NAMESPACE' (namespace-scoped: only ai-gateway-api-keys in $NAMESPACE_FOR_SECRET can ever decrypt this)"
kubeseal --format yaml \
  --controller-namespace "$SS_NAMESPACE" \
  --controller-name "$SS_CONTROLLER_NAME" \
  --context "$CONTEXT" \
  < "$TMP/plain-secret.yaml" > "$TMP/sealed-secret.yaml"

# awk, not a YAML library: PyYAML is not a dependency anything else in this project needs
# (app/ai_service and app/gateway's own requirements have no reason for it), and the one line
# this needs to read is fully predictable -- kubeseal's own `--format yaml` always emits exactly
# one `encryptedData:` map with exactly one key (GATEWAY_API_KEYS_JSON, since the plain Secret
# above has exactly one data key) on its own line, indented once under it.
CIPHERTEXT="$(awk '/^  encryptedData:/{f=1; next} f && /^    GATEWAY_API_KEYS_JSON:/{sub(/^    GATEWAY_API_KEYS_JSON:[[:space:]]*/, ""); print; exit}' "$TMP/sealed-secret.yaml")"

[[ -n "$CIPHERTEXT" ]] || die "kubeseal produced no encryptedData.GATEWAY_API_KEYS_JSON -- something upstream failed silently; re-run with 'set -x' before trusting this."

log_ok "sealed. Paste the two lines below into helm/ai-platform/values-$ENV.yaml (uncomment and fill in, per that file's own Phase 15 comment):"
echo
echo "sealedSecrets:"
echo "  enabled: true"
echo "gateway:"
echo "  apiKeysSealed: \"$CIPHERTEXT\""
echo
log_info "This ciphertext is SAFE to commit (ADR-33) -- only the controller's own private key, which never left '$SS_NAMESPACE', can decrypt it. It is scoped to namespace '$NAMESPACE_FOR_SECRET' only: kubeseal's own default scope (\"strict\") means pasting this same ciphertext under a different namespace in a values file will fail to decrypt there, by design."
