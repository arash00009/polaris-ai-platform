#!/usr/bin/env bash
# scripts/bootstrap/pushgateway.sh — Phase 17: install, inspect, regenerate the eval dashboard
# ConfigMap of, and remove a Prometheus Pushgateway in its own `eval` namespace (ADR-38). Same
# shape as scripts/bootstrap/finops.sh (a genuine Helm chart, so hctl()/install_release()/--wait,
# not model-serving.sh's kubectl-apply-raw-manifests shape).
#
# The Pushgateway holds the eval/ harness's pushed scores (eval/src/eval_harness/
# pushgateway.py's polaris_eval_score metric) until the kube-prometheus-stack Prometheus
# (Phase 9) already installed scrapes them via this chart's own bundled ServiceMonitor
# (serviceMonitor.enabled: true, honorLabels: true -- see pushgateway-values.yaml's comments
# for why honorLabels matters here specifically). It is not a second, separate monitoring
# stack, the same relationship scripts/bootstrap/finops.sh's own header comment describes for
# OpenCost and Phase 9's Prometheus.
#
# Usage: scripts/bootstrap/pushgateway.sh <install|status|dashboard-configmap|uninstall>
# Normally invoked through the make targets (make pushgateway-install, ...).
#
# Status: written and shellchecked in the sandbox, where pushgateway-values.yaml's two
# confirmed config blocks (serviceMonitor, persistentVolume) were checked for real against the
# chart's own real values.yaml -- but there is no cluster and no helm binary in this sandbox.
# `install`/`status`/`uninstall` against a real cluster are this phase's target-machine step --
# see docs/troubleshooting.md, Phase 17, once run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

NAMESPACE="eval"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
PUSHGATEWAY_DIR="deploy/platform/pushgateway"
EVAL_DASHBOARD_DIR="deploy/platform/eval/dashboards"
DASHBOARD_JSON="$EVAL_DASHBOARD_DIR/eval-dashboard.json"
DASHBOARD_CONFIGMAP="$EVAL_DASHBOARD_DIR/eval-dashboard-configmap.yaml"

# Same repo name/URL scripts/bootstrap/observability.sh already adds for kube-prometheus-stack
# -- `helm repo add` with an identical name+url is a harmless no-op if it is already present.
PROM_REPO_NAME="prometheus-community"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
# 180s: a single, tiny stateless Pod (no persistent volume, no sidecar) -- the smallest
# rollout-timeout budget of any platform piece in this project.
ROLLOUT_TIMEOUT="${PUSHGATEWAY_ROLLOUT_TIMEOUT:-180s}"

hctl() { helm --kube-context "$CONTEXT" "$@"; }
kctl() { kubectl --context "$CONTEXT" "$@"; }

need_helm()    { have helm || die "helm not found. Run 'make tools-install'."; }
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
  log_info "installing the Prometheus Pushgateway into '${NAMESPACE}'"
  kctl apply -f "$PUSHGATEWAY_DIR/namespace.yaml"
  hctl repo add "$PROM_REPO_NAME" "${PUSHGATEWAY_HELM_REPO:?PUSHGATEWAY_HELM_REPO is empty in versions.env}" >/dev/null
  log_info "helm repo update"
  hctl repo update >/dev/null

  local version_args=()
  if [[ -n "${PUSHGATEWAY_CHART_VERSION:-}" ]]; then
    version_args=(--version "$PUSHGATEWAY_CHART_VERSION")
  else
    log_warn "PUSHGATEWAY_CHART_VERSION: no version pinned in versions.env — installing whatever '$PROM_REPO_NAME/prometheus-pushgateway' currently resolves to"
  fi
  hctl upgrade --install pushgateway "$PROM_REPO_NAME/prometheus-pushgateway" \
    -n "$NAMESPACE" -f "$PUSHGATEWAY_DIR/pushgateway-values.yaml" "${version_args[@]}" \
    --wait --timeout "$ROLLOUT_TIMEOUT"
  local resolved
  resolved="$(hctl list -n "$NAMESPACE" -o json | python3 -c "
import json, sys
rows = json.load(sys.stdin)
row = next((r for r in rows if r['name'] == 'pushgateway'), None)
print(row['chart'] if row else 'unknown')
")"
  log_ok "pushgateway installed: $resolved"

  log_info "applying the eval Grafana dashboard ConfigMap"
  kctl apply -f "$DASHBOARD_CONFIGMAP"

  log_ok "Pushgateway is up in '${NAMESPACE}'."
  log_info "Run the eval harness against it: make eval-run ARGS='--base-url http://<ai-service>:8000 --backend mock --pushgateway-url http://pushgateway.eval.svc.cluster.local:9091'"
}

cmd_status() {
  need_helm
  need_kubectl
  log_info "Helm releases in '${NAMESPACE}'"
  hctl list -n "$NAMESPACE"
  echo
  log_info "Pods in '${NAMESPACE}'"
  kctl -n "$NAMESPACE" get pods -o wide
}

# Regenerates dashboards/eval-dashboard-configmap.yaml from dashboards/eval-dashboard.json --
# same generator shape as scripts/bootstrap/finops.sh's own cmd_dashboard_configmap.
cmd_dashboard_configmap() {
  have python3 || die "python3 not found"
  [[ -f "$DASHBOARD_JSON" ]] || die "$DASHBOARD_JSON not found"
  DASHBOARD_JSON="$DASHBOARD_JSON" DASHBOARD_CONFIGMAP="$DASHBOARD_CONFIGMAP" python3 - <<'PYEOF'
import json
import os

json_path = os.environ["DASHBOARD_JSON"]
configmap_path = os.environ["DASHBOARD_CONFIGMAP"]

with open(json_path) as f:
    content = f.read()
json.loads(content)  # fail fast on invalid JSON before writing anything

header = f"""# {configmap_path} — Phase 17.
#
# The grafana_dashboard=1 label is what kube-prometheus-stack-values.yaml's
# grafana.sidecar.dashboards config watches for (searchNamespace: ALL -- same as Phase 9/13's
# own dashboard ConfigMaps). eval-dashboard.json is embedded verbatim as this ConfigMap's data
# -- edit that file, not this one, and re-run 'scripts/bootstrap/pushgateway.sh
# dashboard-configmap' (or 'make pushgateway-dashboard-configmap') to regenerate it.
apiVersion: v1
kind: ConfigMap
metadata:
  name: eval-dashboard
  namespace: observability
  labels:
    app.kubernetes.io/part-of: polaris
    grafana_dashboard: "1"
data:
  eval-dashboard.json: |
"""

indented = "\n".join("    " + line if line else "" for line in content.splitlines())
with open(configmap_path, "w") as f:
    f.write(header + indented + "\n")
print(f"wrote {configmap_path}")
PYEOF
  log_ok "dashboard ConfigMap regenerated from $DASHBOARD_JSON"
}

cmd_uninstall() {
  need_helm
  need_kubectl
  log_info "uninstalling the Pushgateway from '${NAMESPACE}'"
  hctl uninstall pushgateway -n "$NAMESPACE" --ignore-not-found
  kctl delete -f "$DASHBOARD_CONFIGMAP" --ignore-not-found
  kctl delete namespace "$NAMESPACE" --ignore-not-found
  log_ok "Pushgateway removed. Prometheus itself (Phase 9) and ai_service's own eval-tagged traffic (eval/, Phase 17) are untouched -- they do not live in this namespace."
}

CMD="${1:-}"
case "$CMD" in
  install)              cmd_install ;;
  status)               cmd_status ;;
  dashboard-configmap)  cmd_dashboard_configmap ;;
  uninstall)            cmd_uninstall ;;
  *)
    echo "Usage: $0 <install|status|dashboard-configmap|uninstall>" >&2
    exit 1
    ;;
esac
