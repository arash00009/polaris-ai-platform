#!/usr/bin/env bash
# scripts/bootstrap/smoke-test.sh
# End-to-end check of the local platform:
#   host -> local registry -> cluster image pull -> Deployment -> Service
#   -> Traefik Ingress -> host ingress port (read from deploy/k3d/cluster.yaml)
#
# Usage: scripts/bootstrap/smoke-test.sh [--keep]   (--keep leaves the workload running)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

CONFIG="$ROOT/deploy/k3d/cluster.yaml"
CLUSTER_NAME="$(cluster_name_from_config "$CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
NAMESPACE="polaris-smoke"
HOST_HEADER="whoami.localhost"
# PUSH_REF/CLUSTER_REF must match deploy/k3d/cluster.yaml and deploy/k8s-smoke/whoami.yaml.
PUSH_REF="localhost:5000/smoke/whoami:v1"
CLUSTER_REF="registry.localhost:5000/smoke/whoami:v1"
INGRESS_PORT="$(host_port_for "$CONFIG" 80)"
[[ -n "$INGRESS_PORT" ]] || die "No host port mapped to container port 80 in $CONFIG"
INGRESS_URL="http://localhost:${INGRESS_PORT}/"

cleanup() {
  if [[ "$KEEP" -eq 0 ]]; then
    kubectl --context "$CONTEXT" delete namespace "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
  else
    log_info "Leaving namespace $NAMESPACE in place (--keep). Remove with: kubectl delete namespace $NAMESPACE"
  fi
}
trap cleanup EXIT

for c in docker kubectl curl; do
  have "$c" || die "$c not found. Run 'make doctor'."
done
docker info >/dev/null 2>&1 || die "Docker daemon not reachable."
kubectl --context "$CONTEXT" get nodes >/dev/null 2>&1 ||
  die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"

log_info "1/6 Pull $SMOKE_IMAGE"
docker pull "$SMOKE_IMAGE" >/dev/null ||
  die "Cannot pull $SMOKE_IMAGE. Try: SMOKE_IMAGE=traefik/whoami:latest make smoke"

log_info "2/6 Push to the local registry as $PUSH_REF"
docker tag "$SMOKE_IMAGE" "$PUSH_REF"
docker push "$PUSH_REF" >/dev/null ||
  die "Push to localhost:5000 failed. Is the registry container running? (make cluster-status)"

log_info "3/6 Deploy workload from $CLUSTER_REF"
kubectl --context "$CONTEXT" apply -f "$ROOT/deploy/k8s-smoke/whoami.yaml" >/dev/null
if ! kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout status deployment/whoami --timeout=120s; then
  log_fail "Deployment did not become available. Diagnostics:"
  kubectl --context "$CONTEXT" -n "$NAMESPACE" get pods -o wide || true
  kubectl --context "$CONTEXT" -n "$NAMESPACE" describe pods | grep -A12 '^Events:' || true
  die "Rollout failed. Common cause: image reference not matching the registry name in cluster.yaml."
fi

log_info "4/6 Confirm the pods use the local-registry image"
image="$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get pods -l app=whoami \
  -o jsonpath='{.items[0].spec.containers[0].image}')"
[[ "$image" == "$CLUSTER_REF" ]] || die "Unexpected image: $image (expected $CLUSTER_REF)"
log_ok "Pod image: $image"

log_info "5/6 Call it through Traefik at $INGRESS_URL (Host: $HOST_HEADER)"
response=""
for i in $(seq 1 30); do
  if response="$(curl -fsS --max-time 5 -H "Host: $HOST_HEADER" "$INGRESS_URL" 2>/dev/null)"; then
    break
  fi
  response=""
  sleep 2
  [[ "$i" -eq 30 ]] && die "No successful response from $INGRESS_URL after 60s. Check: kubectl -n $NAMESPACE get ingress,pods; kubectl -n kube-system get pods"
done

log_info "6/6 Validate the response"
grep -q '^Hostname:' <<<"$response" || die "Response has no 'Hostname:' line:"$'\n'"$response"
grep -q "^Host: ${HOST_HEADER}" <<<"$response" || die "Host header did not reach the pod:"$'\n'"$response"
log_ok "Received a response from pod: $(grep '^Hostname:' <<<"$response")"

log_ok "SMOKE TEST PASSED"
