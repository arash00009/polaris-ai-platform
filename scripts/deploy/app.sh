#!/usr/bin/env bash
# scripts/deploy/app.sh — deploy, inspect and remove the ai-service Kubernetes workload.
#
# Usage: scripts/deploy/app.sh <info|apply|status|logs|smoke|delete> [--follow]
# Normally invoked through the make targets (make deploy-apply, make deploy-status, ...).
#
# Status: written and shellchecked; first real run happens on the target machine (Phase 4).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

APP_DIR="app/ai_service"
KUBE_DIR="deploy/k8s/ai-service"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
IMAGE_REPO="polaris/ai-service"
NAMESPACE="polaris-dev"
RENDERED_DIR="artifacts/deploy"
RENDERED_DEPLOYMENT="$RENDERED_DIR/ai-service-deployment.yaml"

# ---- computed values -----------------------------------------------------------------------
# Deliberately duplicated from scripts/build/image.sh rather than shared, so that a Phase 4
# change here can never alter Phase 3's already-verified build script.

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

# The registry name k3d wrote into cluster.yaml (see deploy/k3d/cluster.yaml comments): pushed
# from the host as localhost:5000/<repo>:<tag>, pulled in the cluster as <name>:5000/<repo>:<tag>.
REG_NAME="$(awk '/create:/{f=1} f && /name:/{print $2; exit}' "$CLUSTER_CONFIG")"
[[ -n "$REG_NAME" ]] || die "Could not read the registry name from $CLUSTER_CONFIG"
HOST_REF="localhost:5000/$IMAGE_REPO:$TAG"
CLUSTER_REF="$REG_NAME:5000/$IMAGE_REPO:$TAG"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
INGRESS_PORT="$(host_port_for "$CLUSTER_CONFIG" 80)"
HOST_HEADER="ai.localhost"

need_kubectl() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  kubectl --context "$CONTEXT" get nodes >/dev/null 2>&1 \
    || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
}

# Fails fast (before kubectl apply) if the tag was never pushed: an ImagePullBackOff is a much
# slower way to discover the same thing.
need_pushed() {
  have curl || die "curl not found. Run 'make doctor'."
  local tags
  tags="$(curl -fsS "http://localhost:5000/v2/$IMAGE_REPO/tags/list" 2>/dev/null || true)"
  if ! grep -q "\"$TAG\"" <<<"$tags"; then
    die "Tag $TAG is not in the local registry (localhost:5000). Run: make image-build && make image-push"
  fi
}

kctl() { kubectl --context "$CONTEXT" "$@"; }

# ---- subcommands -----------------------------------------------------------------------------

cmd_info() {
  log_info "version:          $VERSION"
  log_info "revision:         $REVISION"
  log_info "context:          $CONTEXT"
  log_info "namespace:        $NAMESPACE"
  log_info "host image ref:   $HOST_REF"
  log_info "cluster image ref: $CLUSTER_REF"
  log_info "ingress:          http://localhost:${INGRESS_PORT:-<unknown>}/  (Host: $HOST_HEADER)"
  [[ "$REVISION" != *-dirty ]] || log_warn "working tree has uncommitted changes: the tag ends in -dirty."
}

cmd_apply() {
  need_kubectl
  need_pushed

  mkdir -p "$RENDERED_DIR"
  sed "s#__AI_SERVICE_IMAGE__#${CLUSTER_REF}#" "$KUBE_DIR/deployment.yaml" > "$RENDERED_DEPLOYMENT"

  log_info "applying namespace, config, workload, service, ingress and PodDisruptionBudget"
  kctl apply -f "$KUBE_DIR/namespace.yaml" >/dev/null
  kctl apply -f "$KUBE_DIR/configmap.yaml" >/dev/null
  kctl apply -f "$RENDERED_DEPLOYMENT" >/dev/null
  kctl apply -f "$KUBE_DIR/service.yaml" >/dev/null
  kctl apply -f "$KUBE_DIR/ingress.yaml" >/dev/null
  kctl apply -f "$KUBE_DIR/poddisruptionbudget.yaml" >/dev/null

  if ! kctl -n "$NAMESPACE" rollout status deployment/ai-service --timeout=120s; then
    log_fail "Rollout did not become available. Diagnostics:"
    kctl -n "$NAMESPACE" get pods -o wide || true
    kctl -n "$NAMESPACE" describe pods -l app.kubernetes.io/name=ai-service | grep -A12 '^Events:' || true
    die "Rollout failed. Check: image reference matches the registry name in cluster.yaml; 'kubectl -n $NAMESPACE describe pod <name>' for Pod Security Admission or probe errors."
  fi
  log_ok "ai-service is rolled out (image $CLUSTER_REF)"

  log_info "applying NetworkPolicy (default-deny + allow from kube-system) — the one part not testable without a cluster"
  kctl apply -f "$KUBE_DIR/networkpolicy.yaml" >/dev/null
  sleep 10
  local not_ready
  not_ready="$(kctl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=ai-service \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].ready}{"\n"}{end}' \
    | grep -c 'false' || true)"
  if [[ "$not_ready" -eq 0 ]]; then
    log_ok "pods are still Ready after the NetworkPolicy was applied"
  else
    log_warn "$not_ready pod(s) are not Ready after the NetworkPolicy was applied."
    log_warn "This can mean kubelet's own probe traffic is being blocked (see docs/troubleshooting.md, Phase 4)."
    log_warn "To remove it without touching the rest of the deployment: kubectl --context $CONTEXT -n $NAMESPACE delete networkpolicy ai-service-default-deny ai-service-allow-ingress"
  fi
}

cmd_status() {
  need_kubectl
  log_info "deployment / pods / service / ingress / pdb / networkpolicy in $NAMESPACE"
  kctl -n "$NAMESPACE" get deployment,pods,svc,ingress,pdb,networkpolicy -o wide
  echo
  kctl -n "$NAMESPACE" rollout status deployment/ai-service --timeout=5s || true
}

cmd_logs() {
  need_kubectl
  local follow=()
  [[ "${1:-}" == "--follow" ]] && follow=(--follow)
  kctl -n "$NAMESPACE" logs -l app.kubernetes.io/name=ai-service --prefix=true --tail=100 "${follow[@]}"
}

cmd_smoke() {
  need_kubectl
  [[ -n "$INGRESS_PORT" ]] || die "No host port mapped to container port 80 in $CLUSTER_CONFIG"
  local base="http://localhost:${INGRESS_PORT}"

  log_info "1/3 GET /healthz through Traefik (Host: $HOST_HEADER)"
  local healthz
  healthz="$(curl -fsS --max-time 5 -H "Host: $HOST_HEADER" "$base/healthz")" \
    || die "No response from $base/healthz. Is 'make deploy-apply' rolled out? make deploy-status"
  jq -e '.status == "ok"' <<<"$healthz" >/dev/null || die "/healthz did not answer ok: $healthz"
  log_ok "healthz: $healthz"

  log_info "2/3 GET /readyz through Traefik"
  local readyz
  readyz="$(curl -fsS --max-time 5 -H "Host: $HOST_HEADER" "$base/readyz")" \
    || die "No response from $base/readyz."
  jq -e '.status == "ready"' <<<"$readyz" >/dev/null || die "/readyz was not ready (POLARIS_MOCK_READY in the ConfigMap?): $readyz"
  log_ok "readyz: $readyz"

  log_info "3/3 POST /v1/chat through Traefik and check the contract"
  local chat
  chat="$(curl -fsS --max-time 10 -H "Host: $HOST_HEADER" -H 'content-type: application/json' \
    -d '{"tenant_id":"demo","prompt":"hello from deploy-smoke"}' "$base/v1/chat")" \
    || die "POST /v1/chat failed."
  jq -e 'has("response") and has("model") and has("request_id") and has("latency_ms")' <<<"$chat" >/dev/null \
    || die "Response is missing a required field: $chat"
  log_ok "chat: $chat"

  log_ok "DEPLOY SMOKE TEST PASSED"
}

cmd_delete() {
  need_kubectl
  log_info "removing ai-service resources from $NAMESPACE (the namespace itself is kept)"
  kctl delete -f "$KUBE_DIR/networkpolicy.yaml" --ignore-not-found >/dev/null
  kctl delete -f "$KUBE_DIR/poddisruptionbudget.yaml" --ignore-not-found >/dev/null
  kctl delete -f "$KUBE_DIR/ingress.yaml" --ignore-not-found >/dev/null
  kctl delete -f "$KUBE_DIR/service.yaml" --ignore-not-found >/dev/null
  kctl -n "$NAMESPACE" delete deployment ai-service --ignore-not-found >/dev/null
  kctl delete -f "$KUBE_DIR/configmap.yaml" --ignore-not-found >/dev/null
  log_ok "ai-service removed. Namespace $NAMESPACE and its future contents (Phase 5+) are untouched."
  log_info "To also remove the namespace: kubectl --context $CONTEXT delete namespace $NAMESPACE"
}

# ---- dispatch ------------------------------------------------------------------------------

case "${1:-}" in
  info)   cmd_info ;;
  apply)  cmd_apply ;;
  status) cmd_status ;;
  logs)   cmd_logs "${2:-}" ;;
  smoke)  cmd_smoke ;;
  delete) cmd_delete ;;
  *)
    echo "Usage: $0 <info|apply|status|logs|smoke|delete> [--follow]" >&2
    exit 1
    ;;
esac
