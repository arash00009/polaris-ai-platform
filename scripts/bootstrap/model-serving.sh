#!/usr/bin/env bash
# scripts/bootstrap/model-serving.sh — Phase 11: install, inspect, pull the configured model into,
# and remove the local model server (Ollama) in its own `model-serving` namespace. A separate
# concern from deploy/k8s/ai-service and deploy/platform/observability, following the same shape
# as scripts/bootstrap/observability.sh: one subcommand per verb, invoked through make targets.
#
# Ollama is deployed as a plain Kubernetes manifest here, not a Helm chart -- there is no official
# Ollama Helm chart, and a single-instance server with one Deployment/Service/PVC/NetworkPolicy is
# exactly the case deploy/k8s/ai-service/ (Phase 4) already established this project writes as raw
# YAML rather than reaching for Helm to avoid.
#
# Usage: scripts/bootstrap/model-serving.sh <install|status|pull-model|uninstall>
# Normally invoked through the make targets (make model-serving-install, ...).
#
# Status: written and shellchecked in the sandbox. There is no Docker daemon and no cluster here
# (same constraint scripts/bootstrap/observability.sh and scripts/bootstrap/argocd.sh already
# document), so `install`/`status`/`pull-model`/`uninstall` against a real cluster, and whether the
# ollama/ollama image actually starts under the non-root securityContext in deployment.yaml, are
# both this phase's target-machine step -- see docs/troubleshooting.md, Phase 11.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

NAMESPACE="model-serving"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
MS_DIR="deploy/platform/model-serving"
RENDERED_DIR="artifacts/deploy"
RENDERED_DEPLOYMENT="$RENDERED_DIR/ollama-deployment.yaml"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
# 600s: the image itself is a few hundred MB (smaller than kube-prometheus-stack's combined pulls,
# which needed 900s -- see scripts/bootstrap/observability.sh), and unlike that install this one
# is a single Deployment, not five releases' worth of images at once.
ROLLOUT_TIMEOUT="${MODEL_SERVING_ROLLOUT_TIMEOUT:-600s}"

kctl() { kubectl --context "$CONTEXT" "$@"; }

# Same retry-a-few-times pattern as scripts/bootstrap/observability.sh's need_kubectl: a cold
# WSL2/Docker start can make the very first kubectl call fail even though the cluster is actually
# up (docs/troubleshooting.md, Phase 9).
need_kubectl() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  local attempt
  for attempt in 1 2 3; do
    kctl get nodes >/dev/null 2>&1 && return 0
    [[ "$attempt" -lt 3 ]] && sleep 2
  done
  die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
}

ollama_image() {
  local tag="${OLLAMA_IMAGE_TAG:?OLLAMA_IMAGE_TAG is empty in versions.env}"
  printf 'ollama/ollama:%s' "$tag"
}

cmd_install() {
  need_kubectl
  mkdir -p "$RENDERED_DIR"
  local image
  image="$(ollama_image)"
  log_info "installing the model server into '${NAMESPACE}' (image: $image)"
  kctl apply -f "$MS_DIR/namespace.yaml"
  kctl apply -f "$MS_DIR/pvc.yaml"
  sed "s#__OLLAMA_IMAGE__#${image}#" "$MS_DIR/deployment.yaml" > "$RENDERED_DEPLOYMENT"
  kctl apply -f "$RENDERED_DEPLOYMENT"
  kctl apply -f "$MS_DIR/service.yaml"
  log_info "waiting for the ollama rollout (up to $ROLLOUT_TIMEOUT)"
  if ! kctl -n "$NAMESPACE" rollout status deployment/ollama --timeout "$ROLLOUT_TIMEOUT"; then
    log_warn "rollout did not finish in time -- diagnostics:"
    kctl -n "$NAMESPACE" get pods,events
    die "ollama rollout failed. If the pod is stuck Pending/CrashLoopBackOff, check whether the non-root securityContext in deployment.yaml is the cause (see docs/troubleshooting.md, Phase 11, for the documented fallback)."
  fi
  log_info "applying NetworkPolicy (after the rollout, same ordering reasoning as scripts/deploy/app.sh)"
  kctl apply -f "$MS_DIR/networkpolicy.yaml"
  sleep 2
  if ! kctl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=ollama --no-headers | grep -q Running; then
    die "the ollama pod is not Running after the NetworkPolicy step -- see docs/troubleshooting.md Phase 11"
  fi
  log_ok "model server is up in '${NAMESPACE}'."
  log_info "Next: pull the configured model -- make model-serving-pull"
}

cmd_status() {
  need_kubectl
  log_info "Resources in '${NAMESPACE}'"
  kctl -n "$NAMESPACE" get deployment,pods,pvc,svc -o wide
  echo
  log_info "models currently pulled (needs the pod to be Running)"
  kctl -n "$NAMESPACE" exec deploy/ollama -- ollama list 2>/dev/null \
    || log_warn "could not list models -- is the pod Running? (make model-serving-install first)"
}

cmd_pull_model() {
  need_kubectl
  local model="${OLLAMA_MODEL:?OLLAMA_MODEL is empty in versions.env}"
  log_info "pulling '$model' (this can take several minutes on the first run, then never again -- see pvc.yaml)"
  kctl -n "$NAMESPACE" exec deploy/ollama -- ollama pull "$model"
  log_ok "model pulled. Confirm: make model-serving-status"
}

cmd_uninstall() {
  need_kubectl
  log_info "removing the model server from '${NAMESPACE}'"
  kctl delete -f "$MS_DIR/networkpolicy.yaml" --ignore-not-found
  kctl delete -f "$MS_DIR/service.yaml" --ignore-not-found
  kctl delete deployment ollama -n "$NAMESPACE" --ignore-not-found
  kctl delete -f "$MS_DIR/pvc.yaml" --ignore-not-found
  kctl delete namespace "$NAMESPACE" --ignore-not-found
  log_ok "model server removed. The pulled model was deleted along with the PVC -- pull it again after the next install."
}

CMD="${1:-}"
case "$CMD" in
  install)      cmd_install ;;
  status)       cmd_status ;;
  pull-model)   cmd_pull_model ;;
  uninstall)    cmd_uninstall ;;
  *)
    echo "Usage: $0 <install|status|pull-model|uninstall>" >&2
    exit 1
    ;;
esac
