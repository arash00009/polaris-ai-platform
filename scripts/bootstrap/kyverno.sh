#!/usr/bin/env bash
# scripts/bootstrap/kyverno.sh — Phase 15 session 2 / ADR-36: install, inspect, apply the
# image-verification policy to, demonstrate, and remove Kyverno in its own `kyverno` namespace.
# Same shape as scripts/bootstrap/sealed-secrets.sh (a real Helm chart with its own CRDs, an
# `hctl()`/`kctl()` wrapper, --wait with a timeout, one subcommand per verb) — the one new verb,
# `apply-policy`, renders deploy/platform/kyverno/policies/verify-ai-service-images.yaml.tmpl
# with this repo's own real owner/repo and applies it directly from stdin, never from a file on
# disk (see that template's own header comment for exactly why).
#
# KYVERNO_CHART_VERSION was left unpinned in versions.env until a real target-machine install
# resolved it, the same two-step sealed-secrets.sh/finops.sh/observability.sh already used — now
# pinned to 3.9.1, confirmed via Darya's own `helm list` on 2026-10-15 (see versions.env's own
# comment and docs/troubleshooting.md's Phase 15 session 2 section for the install-stability
# finding from that same run).
#
# Usage: scripts/bootstrap/kyverno.sh <install|status|apply-policy|verify-demo|uninstall> [args]
# Normally invoked through the make targets (make kyverno-install, ...).
#
# Status: `install`/`status` confirmed on the target machine, 2026-10-15 (all four controllers
# stable, 0 restarts over 101 minutes — docs/troubleshooting.md has the full finding, including
# an unrelated leftover kubeadm kubelet.service found and disabled along the way). `apply-policy`
# has not yet been re-attempted since the clean reinstall. `verify-demo` additionally needs a REAL
# signed image digest as input — which only exists after a real GitHub Actions run of the updated
# ci.yml has actually signed one (ADR-35) — so it is sequenced after that run, not after a plain
# cluster-up, unlike every other command here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

NAMESPACE="kyverno"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
KY_DIR="deploy/platform/kyverno"
VALUES_FILE="$KY_DIR/kyverno-values.yaml"
POLICY_TMPL="$KY_DIR/policies/verify-ai-service-images.yaml.tmpl"
RELEASE="kyverno"
REPO_NAME="kyverno"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
# 600s, not sealed-secrets' 300s: four controllers' images to pull on first install (admission,
# background, cleanup, reports), not one single-container Deployment — closer to observability's
# own first-pull budget than sealed-secrets'. Its own named var, per ADR-22's "a later timeout
# change to one already-verified script must never alter another's behaviour" reasoning.
ROLLOUT_TIMEOUT="${KYVERNO_ROLLOUT_TIMEOUT:-600s}"

hctl() { helm --kube-context "$CONTEXT" "$@"; }
kctl() { kubectl --context "$CONTEXT" "$@"; }

need_helm() { have helm || die "helm not found. Run 'make tools-install'."; }
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
  log_info "installing Kyverno into '${NAMESPACE}'"
  kctl apply -f "$KY_DIR/namespace.yaml"
  hctl repo add "$REPO_NAME" "${KYVERNO_HELM_REPO:?KYVERNO_HELM_REPO is empty in versions.env}" >/dev/null
  log_info "helm repo update"
  hctl repo update >/dev/null

  local version_args=()
  if [[ -n "${KYVERNO_CHART_VERSION:-}" ]]; then
    version_args=(--version "$KYVERNO_CHART_VERSION")
  else
    log_warn "no KYVERNO_CHART_VERSION pinned in versions.env — installing whatever '$REPO_NAME/kyverno' currently resolves to"
  fi
  log_info "helm upgrade --install $RELEASE ($REPO_NAME/kyverno${KYVERNO_CHART_VERSION:+ @ $KYVERNO_CHART_VERSION})"
  hctl upgrade --install "$RELEASE" "$REPO_NAME/kyverno" \
    -n "$NAMESPACE" -f "$VALUES_FILE" "${version_args[@]}" \
    --wait --timeout "$ROLLOUT_TIMEOUT"

  local resolved
  resolved="$(hctl list -n "$NAMESPACE" -o json | python3 -c "
import json, sys
rows = json.load(sys.stdin)
row = next((r for r in rows if r['name'] == '$RELEASE'), None)
print(row['chart'] if row else 'unknown')
")"
  if [[ -z "${KYVERNO_CHART_VERSION:-}" ]]; then
    log_warn "$RELEASE resolved to: $resolved — pin this in versions.env (see its Phase 15 session 2 comment) in a follow-up commit"
  else
    log_ok "$RELEASE installed at the pinned version: $resolved"
  fi
  log_info "Next: make kyverno-apply-policy — see docs/security/admission-policy.md"
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
  log_info "ClusterPolicies"
  kctl get clusterpolicy 2>/dev/null \
    || log_warn "no ClusterPolicy found yet — run 'make kyverno-apply-policy' after a fresh install"
  echo
  log_info "Policy background scan status (if verify-ai-service-images exists)"
  if kctl get clusterpolicy verify-ai-service-images -o jsonpath='{.status}' 2>/dev/null; then
    echo
  else
    log_warn "verify-ai-service-images not found"
  fi
}

# Resolves "owner/repo" the exact same way scripts/build/image.sh's own ghcr_owner_repo() does —
# deliberately duplicated rather than sourced, per ADR-22: a later change to one already-verified
# script must never alter the other's behaviour by accident.
owner_repo() {
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '%s' "$GITHUB_REPOSITORY"
    return
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' <<<"$url"
}

cmd_apply_policy() {
  need_kubectl
  local raw lower
  raw="$(owner_repo)"
  [[ -n "$raw" && "$raw" == */* ]] \
    || die "Could not determine the GitHub owner/repo. Set GITHUB_REPOSITORY=owner/repo, or run inside a checkout with a GitHub 'origin' remote."
  # Matches image.sh's own tr '[:upper:]' '[:lower:]' on the owner/repo before it becomes a GHCR
  # path — the policy's imageReferences must match the exact (lowercased) path that was
  # actually published to, or every real image silently fails to match the glob at all.
  lower="$(tr '[:upper:]' '[:lower:]' <<<"$raw")"
  log_info "rendering $POLICY_TMPL for ghcr.io/${lower}/ai-service (never written to disk)"
  sed "s#__POLARIS_OWNER_REPO__#${lower}#g" "$POLICY_TMPL" | kctl apply -f -
  log_ok "applied ClusterPolicy/verify-ai-service-images for ghcr.io/${lower}/ai-service"
}

# Proves the policy actually blocks what it should and admits what it should, against a REAL
# signed image — not a assumption that `kubectl apply -f -` above "probably works" because the
# YAML looks right. Two throwaway Pods, both cleaned up unconditionally on exit:
#   1. positive: the real digest the caller passed (from a real CI publish+sign run, ADR-35) —
#      must be admitted.
#   2. negative: the SAME real repo path, at a neighbouring digest derived by flipping the real
#      digest's last hex character — guaranteed to be a real-looking reference that was never
#      pushed, let alone signed, without needing to know any actual prior unsigned tag's name —
#      must be rejected by the webhook itself (kubectl apply fails with an admission error, not
#      a later ImagePullBackOff).
cmd_verify_demo() {
  need_kubectl
  local good_ref="${1:?Usage: $0 verify-demo <ghcr.io/owner/repo/ai-service@sha256:...> (the GHCR_IMAGE_DIGEST= value a real, signed CI publish run printed)}"
  [[ "$good_ref" == *@sha256:* ]] || die "Expected an image reference pinned by digest (...@sha256:<64 hex chars>), got: $good_ref"

  local repo_path digest last_char bad_hex bad_digest bad_ref
  repo_path="${good_ref%@*}"
  digest="${good_ref##*@sha256:}"
  last_char="${digest: -1}"
  case "$last_char" in
    f) bad_hex=0 ;;
    0) bad_hex=1 ;;
    *) bad_hex="$(printf '%x' "$(( 0x$last_char + 1 ))")" ;;
  esac
  bad_digest="${digest%?}${bad_hex}"
  bad_ref="${repo_path}@sha256:${bad_digest}"

  pod_yaml() { # name image
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: default
  labels:
    app.kubernetes.io/part-of: polaris
spec:
  containers:
    - name: ai-service
      image: $2
  restartPolicy: Never
EOF
  }

  log_info "positive case: expecting this Pod to be ADMITTED — $good_ref"
  if pod_yaml kyverno-verify-demo-signed "$good_ref" | kctl apply -f -; then
    log_ok "positive case passed: a correctly-signed image was admitted"
  else
    die "positive case FAILED: a correctly-signed image was rejected — the policy, the signature, or the owner/repo substitution is wrong. See docs/security/admission-policy.md."
  fi

  log_info "negative case: expecting this Pod to be REJECTED — $bad_ref"
  if pod_yaml kyverno-verify-demo-unsigned "$bad_ref" | kctl apply -f - 2>/tmp/kyverno-verify-demo-negative.err; then
    kctl -n default delete pod kyverno-verify-demo-signed kyverno-verify-demo-unsigned --ignore-not-found >/dev/null 2>&1 || true
    die "negative case FAILED: an unsigned/nonexistent image was admitted — the policy is not actually enforcing. See /tmp/kyverno-verify-demo-negative.err and docs/security/admission-policy.md."
  else
    log_ok "negative case passed: an unsigned/nonexistent image was rejected by the admission webhook — see /tmp/kyverno-verify-demo-negative.err for the real rejection message"
  fi

  kctl -n default delete pod kyverno-verify-demo-signed --ignore-not-found
  log_ok "both cases confirmed — see docs/security/admission-policy.md and docs/troubleshooting.md for the real output to record"
}

cmd_uninstall() {
  need_helm
  need_kubectl
  log_info "removing the verify-ai-service-images ClusterPolicy (if present)"
  kctl delete clusterpolicy verify-ai-service-images --ignore-not-found
  log_info "uninstalling Kyverno from '${NAMESPACE}'"
  hctl uninstall "$RELEASE" -n "$NAMESPACE" --ignore-not-found
  kctl delete namespace "$NAMESPACE" --ignore-not-found
  log_ok "Kyverno removed."
  log_warn "Every Pod in the cluster can now start regardless of its image's signature — this is the deliberate, documented effect of removing the admission controller itself, not a bug. Nothing that was already running is affected either way: verifyImages only ever ran at admission time for a NEW Pod."
}

CMD="${1:-}"
shift || true
case "$CMD" in
  install)      cmd_install ;;
  status)       cmd_status ;;
  apply-policy) cmd_apply_policy ;;
  verify-demo)  cmd_verify_demo "$@" ;;
  uninstall)    cmd_uninstall ;;
  *)
    echo "Usage: $0 <install|status|apply-policy|verify-demo|uninstall> [args]" >&2
    exit 1
    ;;
esac
