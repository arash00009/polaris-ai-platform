#!/usr/bin/env bash
# scripts/bootstrap/observability.sh — Phase 9: install, inspect, get the Grafana admin password
# for, regenerate the dashboard ConfigMap of, and remove the observability stack (kube-prometheus-
# stack, Loki, Tempo, the OTel Collector) in its own `observability` namespace. A separate
# concern from Argo CD (scripts/bootstrap/argocd.sh, its own `argocd` namespace) and from the
# workloads both control the deployment of (polaris-dev/-staging/-prod).
#
# Unlike Argo CD, all four components here are genuine Helm charts (not a single install
# manifest), so this script follows scripts/deploy/helm.sh's shape (an `hctl()` wrapper, --wait
# with a timeout, one subcommand per verb) rather than argocd.sh's kubectl-apply-a-manifest shape.
#
# kube-prometheus-stack and the OTel Collector chart are pinned exactly in versions.env, the same
# as every other tool in this project. Loki and Tempo are NOT: both charts moved to a fast-moving
# community fork mid-2026 (see versions.env's comment) that had already disagreed with itself
# between two checks minutes apart during Phase 9 development. `install` below installs them
# without --version, then prints the version Helm actually resolved and installed
# (`helm list -n observability`) so it can be pinned deliberately in a follow-up commit — the
# same "resolve for real, then pin" two-step already used for PYTHON_BASE_DIGEST/TRIVY_IMAGE_
# DIGEST in this file's Phase 3 section.
#
# Usage: scripts/bootstrap/observability.sh <install|status|password|grafana|dashboard-configmap|uninstall>
# Normally invoked through the make targets (make obs-install, make obs-status, ...).
#
# Status: written and shellchecked in the sandbox, where every chart's Chart.yaml/values.yaml was
# fetched for real from raw.githubusercontent.com and read to confirm the config keys this script
# and its values files use actually exist at the pinned/observed versions (see the values files'
# own comments for specifics) — but there is no cluster and no `helm` binary in the sandbox (same
# constraint as scripts/deploy/helm.sh). `install`/`status`/`password`/`dashboard-configmap`/
# `uninstall` against a real cluster are the target-machine verification step, same pattern as
# every previous phase's bootstrap/deploy script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

NAMESPACE="observability"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
OBS_DIR="deploy/platform/observability"
DASHBOARD_JSON="$OBS_DIR/dashboards/ai-service-dashboard.json"
DASHBOARD_CONFIGMAP="$OBS_DIR/dashboards/ai-service-dashboard-configmap.yaml"

PROM_REPO_NAME="prometheus-community"
PROM_REPO_URL="https://prometheus-community.github.io/helm-charts"
OTEL_REPO_NAME="open-telemetry"
OTEL_REPO_URL="https://open-telemetry.github.io/opentelemetry-helm-charts"
GRAFANA_COMMUNITY_REPO_NAME="grafana-community"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
ROLLOUT_TIMEOUT="${OBS_ROLLOUT_TIMEOUT:-600s}"

hctl() { helm --kube-context "$CONTEXT" "$@"; }
kctl() { kubectl --context "$CONTEXT" "$@"; }

need_helm()    { have helm || die "helm not found. Run 'make tools-install'."; }
need_kubectl() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  kctl get nodes >/dev/null 2>&1 \
    || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
}

add_repos() {
  hctl repo add "$PROM_REPO_NAME" "$PROM_REPO_URL" >/dev/null
  hctl repo add "$OTEL_REPO_NAME" "$OTEL_REPO_URL" >/dev/null
  hctl repo add "$GRAFANA_COMMUNITY_REPO_NAME" "${LOKI_HELM_REPO:?LOKI_HELM_REPO is empty in versions.env}" >/dev/null
  log_info "helm repo update"
  hctl repo update >/dev/null
}

# Installs one release, pinning --version only when the given version variable is non-empty, and
# always prints the version Helm actually resolved and installed afterwards. $1=release
# $2=chart-ref $3=values-file $4=version (may be empty).
install_release() {
  local release="$1" chart="$2" values="$3" version="$4"
  local version_args=()
  if [[ -n "$version" ]]; then
    version_args=(--version "$version")
  else
    log_warn "$release: no version pinned in versions.env — installing whatever '$chart' currently resolves to"
  fi
  log_info "helm upgrade --install $release ($chart${version:+ @ $version})"
  hctl upgrade --install "$release" "$chart" \
    -n "$NAMESPACE" -f "$values" "${version_args[@]}" \
    --wait --timeout "$ROLLOUT_TIMEOUT"
  local resolved
  resolved="$(hctl list -n "$NAMESPACE" -o json | python3 -c "
import json, sys
rows = json.load(sys.stdin)
row = next((r for r in rows if r['name'] == '$release'), None)
print(row['chart'] if row else 'unknown')
")"
  if [[ -z "$version" ]]; then
    log_warn "$release resolved to: $resolved — pin this in versions.env (see its Phase 9 comment) in a follow-up commit"
  else
    log_ok "$release installed at the pinned version: $resolved"
  fi
}

cmd_install() {
  need_helm
  need_kubectl
  log_info "installing the observability stack into '${NAMESPACE}'"
  kctl apply -f "$OBS_DIR/namespace.yaml"
  add_repos

  install_release kube-prometheus-stack "$PROM_REPO_NAME/kube-prometheus-stack" \
    "$OBS_DIR/kube-prometheus-stack-values.yaml" "${KUBE_PROMETHEUS_STACK_VERSION:-}"

  log_info "applying the ai-service Grafana dashboard ConfigMap"
  kctl apply -f "$DASHBOARD_CONFIGMAP"

  install_release loki "$GRAFANA_COMMUNITY_REPO_NAME/loki" \
    "$OBS_DIR/loki-values.yaml" "${LOKI_CHART_VERSION:-}"

  install_release tempo "$GRAFANA_COMMUNITY_REPO_NAME/tempo" \
    "$OBS_DIR/tempo-values.yaml" "${TEMPO_CHART_VERSION:-}"

  install_release otel-collector "$OTEL_REPO_NAME/opentelemetry-collector" \
    "$OBS_DIR/otel-collector-values.yaml" "${OTEL_COLLECTOR_CHART_VERSION:-}"

  log_ok "observability stack is up in '${NAMESPACE}'."
  log_info "Grafana admin password: make obs-password"
  log_info "View Grafana:  kubectl --context $CONTEXT -n $NAMESPACE port-forward svc/kube-prometheus-stack-grafana 3000:80"
  log_info "Next: confirm 'kubectl get crd servicemonitors.monitoring.coreos.com' exists, then set"
  log_info "  serviceMonitor.enabled and config.POLARIS_OTEL_ENABLED to true for ai-platform"
  log_info "  (already done in helm/ai-platform/values-dev.yaml) and roll it out — see docs/observability.md."
}

cmd_status() {
  need_helm
  need_kubectl
  log_info "Helm releases in '${NAMESPACE}'"
  hctl list -n "$NAMESPACE"
  echo
  log_info "Pods in '${NAMESPACE}'"
  kctl -n "$NAMESPACE" get pods -o wide
  echo
  log_info "ai-service ServiceMonitor discovered by Prometheus"
  kctl -n polaris-dev get servicemonitor ai-service -o wide 2>/dev/null \
    || log_warn "no ServiceMonitor found in polaris-dev yet (serviceMonitor.enabled must be true and 'helm upgrade'/Argo CD sync must have run)"
}

cmd_password() {
  need_kubectl
  have base64 || die "base64 not found"
  local pw
  pw="$(kctl -n "$NAMESPACE" get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)" \
    || die "kube-prometheus-stack-grafana secret not found. Is the stack installed (make obs-install)?"
  [[ -n "$pw" ]] || die "Secret exists but is empty."
  printf 'admin / %s\n' "$pw"
}

cmd_grafana() {
  need_kubectl
  log_info "Grafana on http://localhost:3000 (user: admin, password: make obs-password). Ctrl-C to stop."
  kctl -n "$NAMESPACE" port-forward svc/kube-prometheus-stack-grafana 3000:80
}

# Regenerates dashboards/ai-service-dashboard-configmap.yaml from dashboards/ai-service-
# dashboard.json, so the two never drift (the JSON is the file to actually edit).
cmd_dashboard_configmap() {
  have python3 || die "python3 not found"
  [[ -f "$DASHBOARD_JSON" ]] || die "$DASHBOARD_JSON not found"
  # Env vars, not shell-interpolated strings, into a single-quoted heredoc: the previous version
  # of this function built the Python source with the paths spliced directly into a double-quoted
  # -c string, and every literal apostrophe in the comment text below had to be individually
  # escaped for that to work. A real run during Phase 9 development caught it: the escaping was
  # wrong and every apostrophe came out as `'''` instead of `'`. This form sidesteps the whole
  # problem — nothing here is shell-expanded, so no apostrophe needs escaping at all.
  DASHBOARD_JSON="$DASHBOARD_JSON" DASHBOARD_CONFIGMAP="$DASHBOARD_CONFIGMAP" python3 - <<'PYEOF'
import json
import os

json_path = os.environ["DASHBOARD_JSON"]
configmap_path = os.environ["DASHBOARD_CONFIGMAP"]

with open(json_path) as f:
    content = f.read()
json.loads(content)  # fail fast on invalid JSON before writing anything

header = f"""# {configmap_path} — Phase 9.
#
# The grafana_dashboard=1 label is what kube-prometheus-stack-values.yaml's
# grafana.sidecar.dashboards config watches for (searchNamespace: ALL, so this does not need to
# live in the observability namespace itself). ai-service-dashboard.json is embedded verbatim as
# this ConfigMap's data -- edit that file, not this one, and re-run
# 'scripts/bootstrap/observability.sh dashboard-configmap' (or 'make obs-dashboard-configmap')
# to regenerate it.
apiVersion: v1
kind: ConfigMap
metadata:
  name: ai-service-dashboard
  namespace: observability
  labels:
    app.kubernetes.io/part-of: polaris
    grafana_dashboard: "1"
data:
  ai-service-dashboard.json: |
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
  log_info "uninstalling the observability stack from '${NAMESPACE}'"
  for release in otel-collector tempo loki kube-prometheus-stack; do
    hctl uninstall "$release" -n "$NAMESPACE" --ignore-not-found
  done
  kctl delete -f "$DASHBOARD_CONFIGMAP" --ignore-not-found
  kctl delete namespace "$NAMESPACE" --ignore-not-found
  log_ok "observability stack removed. polaris-dev/-staging/-prod are untouched (no ownership link from their workloads back into this namespace, same reasoning as argocd.sh's uninstall)."
  log_warn "Remember to set serviceMonitor.enabled and config.POLARIS_OTEL_ENABLED back to false for any environment this was wired up for, or 'helm upgrade'/Argo CD sync will fail with 'no matches for kind ServiceMonitor'."
}

CMD="${1:-}"
case "$CMD" in
  install)               cmd_install ;;
  status)                cmd_status ;;
  password)              cmd_password ;;
  grafana)               cmd_grafana ;;
  dashboard-configmap)   cmd_dashboard_configmap ;;
  uninstall)             cmd_uninstall ;;
  *)
    echo "Usage: $0 <install|status|password|grafana|dashboard-configmap|uninstall>" >&2
    exit 1
    ;;
esac
