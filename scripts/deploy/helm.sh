#!/usr/bin/env bash
# scripts/deploy/helm.sh — lint, template, install/upgrade, inspect and remove the Phase 5 Helm
# release for ai-service, per environment (dev|staging|prod).
#
# Usage: scripts/deploy/helm.sh <lint|template|apply|status|logs|smoke|uninstall> [dev|staging|prod] [--follow]
# Normally invoked through the make targets (make helm-apply-dev, make helm-status-staging, ...).
#
# Status: written and shellchecked in the sandbox, where `helm` itself could not be installed
# (get.helm.sh is outside the sandbox's allowlisted egress) or run against a cluster (no cluster
# in the sandbox). The chart's template logic was verified with a minimal Go-template-subset
# renderer instead and semantically diffed against Phase 4's already-verified manifests — see
# docs/adr/README.md ADR-23. `helm lint`/`helm template`/`helm install` with the real binary
# (already installed by `make tools-install`, Phase 1) is the target-machine verification step,
# the same pattern as Phase 4's kubectl apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

APP_DIR="app/ai_service"
CHART_DIR="helm/ai-platform"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
IMAGE_REPO="polaris/ai-service"
ENVIRONMENTS=(dev staging prod)

# ---- computed values -----------------------------------------------------------------------
# Deliberately duplicated from scripts/build/image.sh and scripts/deploy/app.sh rather than
# shared, so a change here can never alter Phase 3/4's already-verified scripts (same reasoning
# as ADR-22).

app_version() { awk -F'"' '/^version = / {print $2; exit}' "$APP_DIR/pyproject.toml"; }

app_revision() {
  local rev
  rev="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
  [[ -n "$rev" ]] || { printf 'unknown'; return; }
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then rev="$rev-dirty"; fi
  printf '%s' "$rev"
}

VERSION="$(app_version)"
REVISION="$(app_revision)"
TAG="$VERSION-$REVISION"

REG_NAME="$(awk '/create:/{f=1} f && /name:/{print $2; exit}' "$CLUSTER_CONFIG")"
[[ -n "$REG_NAME" ]] || die "Could not read the registry name from $CLUSTER_CONFIG"
CLUSTER_REPO="$REG_NAME:5000/$IMAGE_REPO"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
INGRESS_PORT="$(host_port_for "$CLUSTER_CONFIG" 80)"

# A clearly-fake tag used only so `helm lint`/`helm template` can render without a real deploy
# (the chart's `required` guard on image.tag would otherwise fail every lint run). It is never
# used by `apply`, which always computes the real $TAG above.
LINT_TAG="0.0.0-lintonly000"

namespace_for() { printf 'polaris-%s' "$1"; }
release_for()   { printf 'ai-platform-%s' "$1"; }
host_for()      { awk '/^ingress:/{f=1} f && /host:/{gsub(/"/,"",$2); print $2; exit}' "$CHART_DIR/values-$1.yaml"; }

need_env() {
  local env="${1:-}"
  [[ -n "$env" ]] || die "Missing environment. Usage: $0 $CMD <dev|staging|prod>"
  for e in "${ENVIRONMENTS[@]}"; do [[ "$e" == "$env" ]] && return 0; done
  die "Unknown environment '$env'. Must be one of: ${ENVIRONMENTS[*]}"
}

need_helm() { have helm || die "helm not found. Run 'make tools-install' (pins $CHART_DIR's expected version via versions.env's HELM_VERSION)."; }

need_kubectl() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  kubectl --context "$CONTEXT" get nodes >/dev/null 2>&1 \
    || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
}

need_pushed() {
  have curl || die "curl not found. Run 'make doctor'."
  local tags
  tags="$(curl -fsS "http://localhost:5000/v2/$IMAGE_REPO/tags/list" 2>/dev/null || true)"
  if ! grep -q "\"$TAG\"" <<<"$tags"; then
    die "Tag $TAG is not in the local registry (localhost:5000). Run: make image-build && make image-push"
  fi
}

hctl() { helm --kube-context "$CONTEXT" "$@"; }
kctl() { kubectl --context "$CONTEXT" "$@"; }

# ---- subcommands -----------------------------------------------------------------------------

cmd_lint() {
  need_helm
  local rc=0
  for env in "${ENVIRONMENTS[@]}"; do
    log_info "helm lint ($env, using a placeholder image tag — this checks structure, not a real deploy)"
    if ! helm lint "$CHART_DIR" -f "$CHART_DIR/values-$env.yaml" \
        --set "image.repository=$CLUSTER_REPO" --set "image.tag=$LINT_TAG"; then
      rc=1
    fi
  done
  [[ $rc -eq 0 ]] || die "helm lint failed for at least one environment."
  log_ok "helm lint passed for: ${ENVIRONMENTS[*]}"
}

cmd_template() {
  need_helm
  local env="${1:-}"; need_env "$env"
  helm template "$(release_for "$env")" "$CHART_DIR" -f "$CHART_DIR/values-$env.yaml" \
    --set "image.repository=$CLUSTER_REPO" --set "image.tag=${TAG}"
}

cmd_apply() {
  need_helm
  need_kubectl
  need_pushed
  local env="${1:-}"; need_env "$env"
  local ns; ns="$(namespace_for "$env")"
  local rel; rel="$(release_for "$env")"

  log_info "helm upgrade --install $rel ($env -> namespace $ns, image $CLUSTER_REPO:$TAG)"
  hctl upgrade --install "$rel" "$CHART_DIR" \
    -f "$CHART_DIR/values-$env.yaml" \
    --set "image.repository=$CLUSTER_REPO" \
    --set "image.tag=$TAG" \
    --namespace "$ns" --create-namespace \
    --wait --timeout 120s

  log_ok "$rel is rolled out (image $CLUSTER_REPO:$TAG)"

  log_info "checking pod readiness after the NetworkPolicy in this release (same check as Phase 4's app.sh apply)"
  sleep 10
  local not_ready
  not_ready="$(kctl -n "$ns" get pods -l app.kubernetes.io/name=ai-service \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].ready}{"\n"}{end}' \
    | grep -c 'false' || true)"
  if [[ "$not_ready" -eq 0 ]]; then
    log_ok "pods in $ns are still Ready after the NetworkPolicy was applied"
  else
    log_warn "$not_ready pod(s) in $ns are not Ready after the NetworkPolicy was applied."
    log_warn "See docs/troubleshooting.md (Phase 4/5). To remove just the policy for this release:"
    log_warn "  kubectl --context $CONTEXT -n $ns delete networkpolicy ai-service-default-deny ai-service-allow-ingress"
  fi
}

cmd_status() {
  need_helm
  need_kubectl
  local env="${1:-}"; need_env "$env"
  local ns; ns="$(namespace_for "$env")"
  log_info "release status ($env)"
  hctl status "$(release_for "$env")" -n "$ns" || true
  echo
  log_info "resources in $ns"
  kctl -n "$ns" get deployment,pods,svc,ingress,pdb,networkpolicy -o wide
}

cmd_logs() {
  need_kubectl
  local env="${1:-}"; need_env "$env"
  local ns; ns="$(namespace_for "$env")"
  local follow=()
  [[ "${2:-}" == "--follow" ]] && follow=(--follow)
  kctl -n "$ns" logs -l app.kubernetes.io/name=ai-service --prefix=true --tail=100 "${follow[@]}"
}

cmd_smoke() {
  need_kubectl
  local env="${1:-}"; need_env "$env"
  [[ -n "$INGRESS_PORT" ]] || die "No host port mapped to container port 80 in $CLUSTER_CONFIG"
  local host; host="$(host_for "$env")"
  [[ -n "$host" ]] || die "Could not read ingress.host from $CHART_DIR/values-$env.yaml"
  local base="http://localhost:${INGRESS_PORT}"

  log_info "1/3 GET /healthz through Traefik ($env, Host: $host)"
  local healthz
  healthz="$(curl -fsS --max-time 5 -H "Host: $host" "$base/healthz")" \
    || die "No response from $base/healthz. Is 'make helm-apply-$env' rolled out?"
  jq -e '.status == "ok"' <<<"$healthz" >/dev/null || die "/healthz did not answer ok: $healthz"
  log_ok "healthz: $healthz"

  log_info "2/3 GET /readyz through Traefik"
  local readyz
  readyz="$(curl -fsS --max-time 5 -H "Host: $host" "$base/readyz")" \
    || die "No response from $base/readyz."
  jq -e '.status == "ready"' <<<"$readyz" >/dev/null || die "/readyz was not ready: $readyz"
  log_ok "readyz: $readyz"

  log_info "3/3 POST /v1/chat through Traefik and check the contract"
  local chat
  chat="$(curl -fsS --max-time 10 -H "Host: $host" -H 'content-type: application/json' \
    -d '{"tenant_id":"demo","prompt":"hello from helm-smoke ('"$env"')"}' "$base/v1/chat")" \
    || die "POST /v1/chat failed."
  jq -e 'has("response") and has("model") and has("request_id") and has("latency_ms")' <<<"$chat" >/dev/null \
    || die "Response is missing a required field: $chat"
  log_ok "chat: $chat"

  log_ok "HELM SMOKE TEST PASSED ($env)"
}

cmd_uninstall() {
  need_helm
  need_kubectl
  local env="${1:-}"; need_env "$env"
  local ns; ns="$(namespace_for "$env")"
  log_info "uninstalling $(release_for "$env") from $ns (the namespace is kept: helm.sh/resource-policy)"
  hctl uninstall "$(release_for "$env")" -n "$ns" --ignore-not-found
  log_ok "release removed. Namespace $ns is untouched."
}

# ---- dispatch ------------------------------------------------------------------------------

CMD="${1:-}"
case "$CMD" in
  lint)      cmd_lint ;;
  template)  cmd_template "${2:-}" ;;
  apply)     cmd_apply "${2:-}" ;;
  status)    cmd_status "${2:-}" ;;
  logs)      cmd_logs "${2:-}" "${3:-}" ;;
  smoke)     cmd_smoke "${2:-}" ;;
  uninstall) cmd_uninstall "${2:-}" ;;
  *)
    echo "Usage: $0 <lint|template|apply|status|logs|smoke|uninstall> [dev|staging|prod] [--follow]" >&2
    exit 1
    ;;
esac
