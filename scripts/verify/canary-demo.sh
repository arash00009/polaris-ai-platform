#!/usr/bin/env bash
# scripts/verify/canary-demo.sh — Phase 18 (ADR-39): proves "Version A -> B canary with
# analysis; failed B rolls back automatically" (docs/architecture.md roadmap, Phase 18 "Done
# when") against a REAL cluster -- the one thing a unit test cannot prove.
#
# --good bumps ONE harmless config value (config.POLARIS_LOG_LEVEL, flipped INFO<->DEBUG) via
# `helm upgrade --reuse-values` -- a real, honest, trivial change, not a no-op annotation bump --
# which the Rollout's own checksum/config annotation (Phase 7, ADR-25) turns into a new
# ReplicaSet/canary revision. Expects the Rollout to promote through the full canary (setWeight
# 50 -> analysis -> setWeight 100) to status.phase=Healthy.
#
# --bad raises config.POLARIS_MOCK_FAILURE_RATE past the AnalysisTemplate's success-rate
# threshold (0.99) the same way, on an environment that actually runs MockBackend (staging,
# prod). Expects the AnalysisTemplate to notice during the analysis step and the Rollout to
# abort automatically (status.abort=true, status.phase=Degraded) -- nothing about this script
# tells Argo Rollouts "this one is bad"; the AnalysisTemplate has to actually catch it on its
# own.
#
# --bad --env dev (Phase 19, ADR-40, Scenario 1: closes the exact gap ADR-39's Decision named)
# points config.POLARIS_OPENAI_BASE_URL at a wrong port on the same real Ollama Service instead
# -- dev runs OpenAICompatBackend, which has no mock_failure_rate-style knob, but a genuinely
# unreachable upstream produces the same real outcome=backend_error series the AnalysisTemplate's
# success-rate metric already queries (see OpenAICompatBackend.generate()'s httpx.RequestError
# handling). Same expectation: the Rollout aborts on its own.
#
# Both modes start scripts/load/chat-load.js (k6) in the background first: the AnalysisTemplate's
# two metrics are defined with explicit successCondition AND failureCondition so a genuinely
# empty Prometheus result (no traffic) is scored Inconclusive rather than Failed (ADR-39), but
# k6 exists so that case stays rare in practice rather than being the only safeguard against it.
#
# --promote/--retry/--abort (found necessary for real on the target machine, 2026-10-30: an
# AnalysisRun that lands on Inconclusive rather than Failed does NOT auto-resolve -- the Rollout
# just stays Paused indefinitely until a person runs one of these three by hand. Argo Rollouts'
# own documented behaviour, confirmed for real; see docs/troubleshooting.md's Phase 18/19 section
# and ADR-39's Consequences). These three are a thin, deliberately dumb wrapper around
# `kubectl-argo-rollouts ... <verb> ai-service` -- the exact working syntax confirmed against the
# plugin's own upstream docs after an earlier wrong guess (`abort rollout ai-service`, which fails
# with `Error: rollouts.argoproj.io "rollout" not found`): the verb takes the Rollout's bare name
# directly, no extra `rollout` keyword.
#
# Usage: scripts/verify/canary-demo.sh --good|--bad|--promote|--retry|--abort [--env dev|staging|prod]
# Normally invoked through the make targets (make canary-demo-good, make canary-demo-bad,
# make canary-demo-promote, make canary-demo-retry, make canary-demo-abort).
#
# Status: written and shellchecked in the sandbox; this sandbox has no cluster/helm/Argo
# Rollouts controller. scripts/load/chat-load.js itself WAS run for real here against a locally
# started ai_service (uvicorn, MockBackend, no cluster) -- see docs/progressive-delivery.md §5.
# --good/--bad against staging/prod are confirmed for real on the target machine
# (docs/progressive-delivery.md). --bad --env dev (Phase 19's new branch, ADR-40) has only been
# written and checked in the sandbox so far -- a real target-machine run is pending, see
# docs/failure-engineering.md. --promote/--retry/--abort wrap a command confirmed for real on the
# target machine (the --abort case, specifically); --promote/--retry use the identical syntax
# pattern but have not individually been run for real yet -- named honestly, not assumed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

CHART_DIR="helm/ai-platform"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"

MODE=""
ENV="staging"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --good)    MODE="good"; shift ;;
    --bad)     MODE="bad"; shift ;;
    --promote) MODE="promote"; shift ;;
    --retry)   MODE="retry"; shift ;;
    --abort)   MODE="abort"; shift ;;
    --env)  ENV="${2:?--env needs dev, staging or prod}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --good|--bad|--promote|--retry|--abort [--env dev|staging|prod]" >&2
      exit 0
      ;;
    *) die "Unknown argument: $1. Usage: $0 --good|--bad|--promote|--retry|--abort [--env staging|prod]" ;;
  esac
done
[[ -n "$MODE" ]] || die "Must pass --good, --bad, --promote, --retry or --abort. Usage: $0 --good|--bad|--promote|--retry|--abort [--env staging|prod]"
case "$ENV" in
  dev|staging|prod) ;;
  *) die "--env must be dev, staging or prod" ;;
esac

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
INGRESS_PORT="$(host_port_for "$CLUSTER_CONFIG" 80)"
NAMESPACE="polaris-${ENV}"
RELEASE="ai-platform-${ENV}"
# values-dev.yaml alone uses the bare "ai.localhost" host; every other environment is
# "ai-<env>.localhost" (helm/ai-platform/values-staging.yaml, values-prod.yaml).
HOST="ai-${ENV}.localhost"
[[ "$ENV" == "dev" ]] && HOST="ai.localhost"

kctl() { kubectl --context "$CONTEXT" "$@"; }
rollouts_plugin() { kubectl-argo-rollouts --context "$CONTEXT" "$@"; }

need_tools() {
  have helm || die "helm not found. Run 'make doctor'."
  have kubectl || die "kubectl not found. Run 'make doctor'."
  have kubectl-argo-rollouts || die "kubectl-argo-rollouts not found. Run 'make tools-install ARGS=\"--only kubectl-argo-rollouts\"'."
  have k6 || die "k6 not found. Run 'make tools-install ARGS=\"--only k6\"'."
  [[ -n "$INGRESS_PORT" ]] || die "No host port mapped to container port 80 in $CLUSTER_CONFIG"
  kctl get nodes >/dev/null 2>&1 \
    || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
  kctl -n "$NAMESPACE" get rollout ai-service >/dev/null 2>&1 \
    || die "No ai-service Rollout found in '$NAMESPACE'. Run 'make helm-apply-$ENV' with this phase's chart first -- see docs/progressive-delivery.md for the one-time Deployment-to-Rollout migration step this chart version needs on an already-deployed namespace."
}

LOAD_PID=""
cleanup() { if [[ -n "$LOAD_PID" ]]; then kill "$LOAD_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT

start_load() {
  log_info "starting k6 traffic against http://localhost:${INGRESS_PORT} (Host: $HOST) in the background, logging to canary-demo-k6.log"
  TARGET_URL="http://localhost:${INGRESS_PORT}" HOST_HEADER="$HOST" \
    k6 run --quiet --no-usage-report --vus 3 --duration 8m "$ROOT/scripts/load/chat-load.js" \
    > "$ROOT/canary-demo-k6.log" 2>&1 &
  LOAD_PID=$!
  sleep 3
  log_ok "k6 running (pid $LOAD_PID)"
}

watch_rollout() {
  log_info "watching the Rollout (Ctrl-C stops watching; the canary and the k6 traffic above keep running either way until k6's own 8m duration ends)"
  rollouts_plugin -n "$NAMESPACE" get rollout ai-service --watch || true
}

cmd_good() {
  need_tools
  start_load
  local current new_level
  current="$(kctl -n "$NAMESPACE" get configmap ai-service-config -o jsonpath='{.data.POLARIS_LOG_LEVEL}' 2>/dev/null || echo INFO)"
  new_level="DEBUG"; [[ "$current" == "DEBUG" ]] && new_level="INFO"
  log_info "bumping config.POLARIS_LOG_LEVEL from '$current' to '$new_level' (a real, harmless change) via 'helm upgrade --reuse-values'"
  # --force-conflicts: same reason scripts/deploy/helm.sh's cmd_apply has carried it since Phase
  # 15 (2026-10-14) -- helm v4's default server-side apply otherwise fails outright the moment a
  # field here is already owned by another field manager ("argocd-controller", since Phase 8 put
  # every environment under Argo CD management). Found for real on the target machine running
  # this exact command against polaris-staging, 2026-10-30 -- this script's own helm upgrade
  # calls had never carried the flag before, unlike cmd_apply's.
  helm upgrade "$RELEASE" "$CHART_DIR" --namespace "$NAMESPACE" --kube-context "$CONTEXT" \
    --reuse-values --set "config.POLARIS_LOG_LEVEL=$new_level" --force-conflicts
  watch_rollout
  log_ok "If the Rollout's STATUS reached Healthy at 100% weight, the canary promoted -- the real proof this phase's 'Done when' line asks for. Re-check any time with: kubectl-argo-rollouts --context $CONTEXT -n $NAMESPACE get rollout ai-service"
}

cmd_bad() {
  need_tools
  start_load
  local set_arg revert_arg
  if [[ "$ENV" == "dev" ]]; then
    # Phase 19 (ADR-40), Scenario 1: port 19999 is deliberately not 11434 (Ollama's real port,
    # confirmed in values-dev.yaml) on the exact same real Service DNS name -- a genuinely
    # unreachable upstream (connection refused), not a typo'd hostname that might resolve
    # somewhere unexpected.
    set_arg="config.POLARIS_OPENAI_BASE_URL=http://ollama.model-serving.svc.cluster.local:19999/v1"
    revert_arg="config.POLARIS_OPENAI_BASE_URL=http://ollama.model-serving.svc.cluster.local:11434/v1"
    log_info "pointing config.POLARIS_OPENAI_BASE_URL at an unreachable port on the real Ollama Service via 'helm upgrade --reuse-values'"
  else
    set_arg="config.POLARIS_MOCK_FAILURE_RATE=0.5"
    revert_arg="config.POLARIS_MOCK_FAILURE_RATE=0.0"
    log_info "raising config.POLARIS_MOCK_FAILURE_RATE to 0.5 (past the AnalysisTemplate's 0.99 success-rate threshold) via 'helm upgrade --reuse-values'"
  fi
  # --force-conflicts: see cmd_good's comment above -- same Argo-CD-vs-helm-v4-server-side-apply
  # field-ownership conflict, found for real against polaris-staging, 2026-10-30.
  helm upgrade "$RELEASE" "$CHART_DIR" --namespace "$NAMESPACE" --kube-context "$CONTEXT" \
    --reuse-values --set "$set_arg" --force-conflicts
  watch_rollout
  log_ok "If the Rollout's STATUS reached Degraded (status.abort=true) and traffic rolled back to the previous, stable ReplicaSet on its own, the AnalysisTemplate caught it -- the real proof of 'failed B rolls back automatically.'"
  log_info "Revert the injected failure: helm upgrade $RELEASE $CHART_DIR --namespace $NAMESPACE --kube-context $CONTEXT --reuse-values --set $revert_arg --force-conflicts"
}

need_rollouts_tools() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  have kubectl-argo-rollouts || die "kubectl-argo-rollouts not found. Run 'make tools-install ARGS=\"--only kubectl-argo-rollouts\"'."
  kctl get nodes >/dev/null 2>&1 \
    || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
  kctl -n "$NAMESPACE" get rollout ai-service >/dev/null 2>&1 \
    || die "No ai-service Rollout found in '$NAMESPACE'."
}

cmd_promote() {
  need_rollouts_tools
  log_info "promoting the Rollout (use when you want to skip the rest of the pause/analysis, e.g. after inspecting an Inconclusive result by hand and deciding it's actually fine)"
  # Synopsis: `kubectl argo rollouts promote ROLLOUT_NAME` -- bare name, no resource-type
  # keyword. Checked against the plugin's own upstream docs, not guessed.
  rollouts_plugin -n "$NAMESPACE" promote ai-service
  rollouts_plugin -n "$NAMESPACE" get rollout ai-service
}

cmd_retry() {
  need_rollouts_tools
  log_info "retrying the Rollout's analysis (use when an AnalysisRun landed on Inconclusive/Failed and you want Argo Rollouts to re-run the analysis step rather than abort or promote)"
  # Synopsis: `kubectl argo rollouts retry <rollout|experiment> RESOURCE_NAME` -- unlike
  # promote/abort, retry DOES require the resource-type keyword before the name. Checked against
  # the plugin's own upstream docs, not guessed: each verb's own synopsis differs, not a
  # consistent pattern across the plugin.
  rollouts_plugin -n "$NAMESPACE" retry rollout ai-service
  rollouts_plugin -n "$NAMESPACE" get rollout ai-service
}

cmd_abort() {
  need_rollouts_tools
  log_info "aborting the Rollout (use to unstick a Paused/Inconclusive canary and roll back to the stable ReplicaSet by hand -- confirmed for real on the target machine, 2026-10-30)"
  # Synopsis: `kubectl argo rollouts abort ROLLOUT_NAME` -- bare name, no extra "rollout"
  # keyword. `abort rollout ai-service` fails with `Error: rollouts.argoproj.io "rollout" not
  # found` -- confirmed for real on the target machine, then verified against the plugin's own
  # upstream docs before writing this.
  rollouts_plugin -n "$NAMESPACE" abort ai-service
  rollouts_plugin -n "$NAMESPACE" get rollout ai-service
}

case "$MODE" in
  good)    cmd_good ;;
  bad)     cmd_bad ;;
  promote) cmd_promote ;;
  retry)   cmd_retry ;;
  abort)   cmd_abort ;;
esac
