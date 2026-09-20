#!/usr/bin/env bash
# scripts/bootstrap/cluster.sh
# Manage the local k3d cluster defined in deploy/k3d/cluster.yaml.
#
# Usage: scripts/bootstrap/cluster.sh up|down|reset|status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"

CONFIG="$ROOT/deploy/k3d/cluster.yaml"
CLUSTER_NAME="$(cluster_name_from_config "$CONFIG")"
K3S_IMAGE="$(k3s_image_from_config "$CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
# With registries.create in cluster.yaml, k3d uses the given name as-is for the container
# (verified on k3d v5.9.0: container "registry.localhost", no "k3d-" prefix).
REGISTRY_CONTAINER="registry.localhost"

[[ -n "$CLUSTER_NAME" && -n "$K3S_IMAGE" ]] || die "Could not read name/image from $CONFIG"

require_prereqs() {
  for c in docker k3d kubectl jq; do
    have "$c" || die "$c not found. Run 'make doctor' for guidance."
  done
  docker info >/dev/null 2>&1 || die "Docker daemon not reachable. Try: sudo systemctl start docker"
}

cluster_exists() {
  k3d cluster list -o json 2>/dev/null | jq -e --arg n "$CLUSTER_NAME" '.[] | select(.name == $n)' >/dev/null 2>&1
}

print_system_diagnostics() {
  log_info "kube-system pods:"
  kubectl --context "$CONTEXT" -n kube-system get pods -o wide || true
  log_info "Recent kube-system events (look for ErrImagePull / ImagePullBackOff):"
  kubectl --context "$CONTEXT" -n kube-system get events --sort-by=.lastTimestamp | tail -15 || true
}

# A fresh cluster pulls its own system images (klipper-helm, Traefik, metrics-server, ...)
# from Docker Hub inside the nodes. On a slow or flaky connection that takes minutes, and
# a failed pull backs off before it is retried. So the wait is generous and configurable:
#   POLARIS_TRAEFIK_WAIT=900 make cluster-up
# Observed once (2026-09-21): Traefik appeared ~5.5 minutes after cluster creation, so the
# default leaves a safety margin. The first helm-install-traefik attempt can also fail with
# "Required CRDs are missing" (it races the CRD chart) and succeeds on its automatic retry.
wait_until_ready() {
  local limit="${POLARIS_TRAEFIK_WAIT:-600}" waited=0

  log_info "Waiting for all nodes to be Ready (max 180s)"
  kubectl --context "$CONTEXT" wait --for=condition=Ready nodes --all --timeout=180s

  log_info "Waiting for Traefik (bundled ingress controller), max ${limit}s"
  until kubectl --context "$CONTEXT" -n kube-system get deployment traefik >/dev/null 2>&1; do
    if [[ "$waited" -ge "$limit" ]]; then
      print_system_diagnostics
      die "Traefik deployment did not appear within ${limit}s. Usually a slow or failed image pull from Docker Hub; retry with a longer wait: POLARIS_TRAEFIK_WAIT=900 make cluster-up"
    fi
    sleep 5
    waited=$((waited + 5))
    if [[ $((waited % 30)) -eq 0 ]]; then
      log_info "  still waiting for Traefik (${waited}s)..."
    fi
  done
  kubectl --context "$CONTEXT" -n kube-system rollout status deployment/traefik --timeout=180s
}

cmd_up() {
  require_prereqs
  if cluster_exists; then
    log_info "Cluster '$CLUSTER_NAME' already exists; making sure it is running"
    k3d cluster start "$CLUSTER_NAME" >/dev/null 2>&1 || true
  else
    log_info "Pulling $K3S_IMAGE"
    docker pull "$K3S_IMAGE" >/dev/null ||
      die "Could not pull $K3S_IMAGE. Check the tag exists on Docker Hub (rancher/k3s) or pin another tag of the same Kubernetes minor in deploy/k3d/cluster.yaml."
    log_info "Creating cluster '$CLUSTER_NAME' (first run takes 1-3 minutes)"
    k3d cluster create --config "$CONFIG"
  fi
  kubectl config use-context "$CONTEXT" >/dev/null
  wait_until_ready
  log_ok "Cluster '$CLUSTER_NAME' is ready (kubectl context: $CONTEXT)"
}

cmd_down() {
  require_prereqs
  if cluster_exists; then
    log_info "Deleting cluster '$CLUSTER_NAME'"
    k3d cluster delete "$CLUSTER_NAME"
  else
    log_info "Cluster '$CLUSTER_NAME' does not exist"
  fi
  # The registry created from cluster.yaml should go with the cluster; make sure.
  if docker ps -a --format '{{.Names}}' | grep -qx "$REGISTRY_CONTAINER"; then
    log_info "Removing leftover registry container $REGISTRY_CONTAINER"
    docker rm -f "$REGISTRY_CONTAINER" >/dev/null
  fi
  log_ok "Cluster removed"
}

cmd_status() {
  require_prereqs
  if ! cluster_exists; then
    log_warn "Cluster '$CLUSTER_NAME' does not exist. Create it with: make cluster-up"
    exit 1
  fi
  k3d cluster list
  echo
  kubectl --context "$CONTEXT" get nodes -o wide
  echo
  log_info "Pods that are not Running/Completed:"
  kubectl --context "$CONTEXT" get pods -A --no-headers 2>/dev/null |
    awk '$4 != "Running" && $4 != "Completed" {print}' || true
  echo
  log_info "Registry container:"
  docker ps --filter "name=$REGISTRY_CONTAINER" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  reset)  cmd_down; cmd_up ;;
  status) cmd_status ;;
  *)      echo "Usage: $(basename "$0") up|down|reset|status" >&2; exit 2 ;;
esac
