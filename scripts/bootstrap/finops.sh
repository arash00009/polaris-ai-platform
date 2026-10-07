#!/usr/bin/env bash
# scripts/bootstrap/finops.sh — Phase 13: install, inspect, open the UI of, regenerate the
# dashboard ConfigMap of, and remove OpenCost in its own `finops` namespace. Same shape as
# scripts/bootstrap/observability.sh (a genuine Helm chart, so hctl()/install_release()/--wait,
# not model-serving.sh's kubectl-apply-raw-manifests shape).
#
# OpenCost reads cAdvisor/kube-state-metrics data from the Prometheus Phase 9 already installed
# (deploy/platform/finops/opencost-values.yaml's opencost.prometheus.internal.*) -- it is not a
# second, separate monitoring stack. It never gets ai_requests_total/ai_tokens_total/
# ai_inference_seconds_total (ai_service/telemetry.py) or ai_gateway_requests_total
# (gateway/telemetry.py) at all: those are this project's OWN tenant-attribution counters,
# already scraped by the same Prometheus directly from ai-service/ai-gateway's own /metrics
# (Phase 9's ServiceMonitor). The FinOps dashboard (dashboard-configmap below) is what combines
# OpenCost's pod/namespace cost estimate with this project's own per-tenant share of those
# counters -- see docs/finops.md for the exact queries.
#
# Usage: scripts/bootstrap/finops.sh <install|status|ui|dashboard-configmap|uninstall>
# Normally invoked through the make targets (make finops-install, ...).
#
# Status: written and shellchecked in the sandbox, where opencost-values.yaml's two confirmed
# config blocks (prometheus.internal, customPricing) were checked for real against opencost.io's
# own docs -- but there is no cluster, no helm binary, and (per that values file's own comments)
# no confirmed real Prometheus Service name in this sandbox. `install`/`status`/`uninstall`
# against a real cluster, and confirming opencost-values.yaml's serviceName/serviceMonitor gaps,
# are this phase's target-machine step -- see docs/troubleshooting.md, Phase 13.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

NAMESPACE="finops"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
FINOPS_DIR="deploy/platform/finops"
DASHBOARD_JSON="$FINOPS_DIR/dashboards/finops-dashboard.json"
DASHBOARD_CONFIGMAP="$FINOPS_DIR/dashboards/finops-dashboard-configmap.yaml"

OPENCOST_REPO_NAME="opencost-charts"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
# 300s: one Deployment (opencost + its UI sidecar container), a much smaller pull than
# kube-prometheus-stack's 900s or even model-serving's 600s (see those scripts' own comments).
ROLLOUT_TIMEOUT="${FINOPS_ROLLOUT_TIMEOUT:-300s}"

hctl() { helm --kube-context "$CONTEXT" "$@"; }
kctl() { kubectl --context "$CONTEXT" "$@"; }

need_helm()    { have helm || die "helm not found. Run 'make tools-install'."; }
# Same retry-a-few-times pattern as observability.sh/model-serving.sh's need_kubectl (a cold
# WSL2/Docker start can make the very first kubectl call fail even though the cluster is up).
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
  log_info "installing OpenCost into '${NAMESPACE}'"
  kctl apply -f "$FINOPS_DIR/namespace.yaml"
  hctl repo add "$OPENCOST_REPO_NAME" "${OPENCOST_HELM_REPO:?OPENCOST_HELM_REPO is empty in versions.env}" >/dev/null
  log_info "helm repo update"
  hctl repo update >/dev/null

  local version_args=()
  if [[ -n "${OPENCOST_CHART_VERSION:-}" ]]; then
    version_args=(--version "$OPENCOST_CHART_VERSION")
  else
    log_warn "OPENCOST_CHART_VERSION: no version pinned in versions.env — installing whatever '$OPENCOST_REPO_NAME/opencost' currently resolves to"
  fi
  hctl upgrade --install opencost "$OPENCOST_REPO_NAME/opencost" \
    -n "$NAMESPACE" -f "$FINOPS_DIR/opencost-values.yaml" "${version_args[@]}" \
    --wait --timeout "$ROLLOUT_TIMEOUT"
  local resolved
  resolved="$(hctl list -n "$NAMESPACE" -o json | python3 -c "
import json, sys
rows = json.load(sys.stdin)
row = next((r for r in rows if r['name'] == 'opencost'), None)
print(row['chart'] if row else 'unknown')
")"
  if [[ -z "${OPENCOST_CHART_VERSION:-}" ]]; then
    log_warn "opencost resolved to: $resolved — pin this in versions.env (see its Phase 13 comment) in a follow-up commit"
  else
    log_ok "opencost installed at the pinned version: $resolved"
  fi

  log_info "applying the FinOps Grafana dashboard ConfigMap"
  kctl apply -f "$DASHBOARD_CONFIGMAP"

  log_ok "OpenCost is up in '${NAMESPACE}'."
  log_info "View the OpenCost UI:  make finops-ui"
  log_info "If it shows no data: confirm the Prometheus Service name opencost-values.yaml assumes"
  log_info "  (kubectl -n observability get svc) and check docs/troubleshooting.md, Phase 13."
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

cmd_ui() {
  need_kubectl
  log_info "OpenCost UI on http://localhost:9090 . Ctrl-C to stop."
  kctl -n "$NAMESPACE" port-forward svc/opencost 9090:9090
}

# Regenerates dashboards/finops-dashboard-configmap.yaml from dashboards/finops-dashboard.json --
# same generator shape as scripts/bootstrap/observability.sh's cmd_dashboard_configmap, see its
# own comment for why env vars (not shell-interpolated strings) go into the heredoc.
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

header = f"""# {configmap_path} — Phase 13.
#
# The grafana_dashboard=1 label is what kube-prometheus-stack-values.yaml's
# grafana.sidecar.dashboards config watches for (searchNamespace: ALL -- same as Phase 9's
# ai-service-dashboard-configmap.yaml, this does not need to live in 'observability' or 'finops'
# specifically). finops-dashboard.json is embedded verbatim as this ConfigMap's data -- edit
# that file, not this one, and re-run 'scripts/bootstrap/finops.sh dashboard-configmap' (or
# 'make finops-dashboard-configmap') to regenerate it.
apiVersion: v1
kind: ConfigMap
metadata:
  name: finops-dashboard
  namespace: observability
  labels:
    app.kubernetes.io/part-of: polaris
    grafana_dashboard: "1"
data:
  finops-dashboard.json: |
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
  log_info "uninstalling OpenCost from '${NAMESPACE}'"
  hctl uninstall opencost -n "$NAMESPACE" --ignore-not-found
  kctl delete -f "$DASHBOARD_CONFIGMAP" --ignore-not-found
  kctl delete namespace "$NAMESPACE" --ignore-not-found
  log_ok "OpenCost removed. The counters it read from (ai_requests_total etc.) and Prometheus itself are untouched -- they belong to ai-service/ai-gateway and Phase 9, not this namespace."
}

CMD="${1:-}"
case "$CMD" in
  install)              cmd_install ;;
  status)               cmd_status ;;
  ui)                   cmd_ui ;;
  dashboard-configmap)  cmd_dashboard_configmap ;;
  uninstall)            cmd_uninstall ;;
  *)
    echo "Usage: $0 <install|status|ui|dashboard-configmap|uninstall>" >&2
    exit 1
    ;;
esac
