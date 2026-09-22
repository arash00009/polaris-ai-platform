#!/usr/bin/env bash
# scripts/verify/post-deploy.sh — Phase 7: the "post-deploy verification job" from ADR-12's
# second verification loop ("in the local cluster"). Answers one question a smoke test does not:
# not just "did the last apply finish", but "is what's running right now actually healthy" —
# rollout status, health, readiness, a real AI answer, structured logs, and (advisory only, since
# there is no Prometheus yet — Phase 9/10) whether the cluster is even reporting pod metrics.
#
# Usage: scripts/verify/post-deploy.sh <dev|staging|prod>
# Normally invoked through the make targets (make verify-dev, make verify-staging, ...).
#
# Deliberately duplicates small pieces of scripts/deploy/helm.sh (env/namespace/release/host
# resolution, the ingress smoke pattern) rather than sourcing it, for the same reason helm.sh
# itself gives for duplicating from scripts/build/image.sh and scripts/deploy/app.sh: a change
# here must never alter a previous phase's already-verified script (ADR-22).
#
# Unlike scripts/deploy/helm.sh smoke (which fails fast on the first problem), this script runs
# every check and reports all of them — a real post-deploy verification job should say everything
# that is wrong with a bad deploy, not just the first thing it happened to notice.
#
# Status: written and shellchecked in the sandbox, where there is no cluster to run it against
# (same gap as Phase 4/5's deploy/helm scripts before their first target-machine run). Its first
# real run — including the deliberate-failure test in the Phase 7 guide, which forces a bad
# readyz via `config.POLARIS_MOCK_READY=false` and confirms this script actually catches it — is
# on the target machine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

CHART_DIR="helm/ai-platform"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
ENVIRONMENTS=(dev staging prod)

ROLLOUT_TIMEOUT="${VERIFY_ROLLOUT_TIMEOUT:-60s}"
LOG_WINDOW="${VERIFY_LOG_WINDOW:-5m}"
LOG_LINES="${VERIFY_LOG_LINES:-20}"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
INGRESS_PORT="$(host_port_for "$CLUSTER_CONFIG" 80)"

namespace_for() { printf 'polaris-%s' "$1"; }
release_for()   { printf 'ai-platform-%s' "$1"; }
host_for()      { awk '/^ingress:/{f=1} f && /host:/{gsub(/"/,"",$2); print $2; exit}' "$CHART_DIR/values-$1.yaml"; }

need_env() {
  local env="${1:-}"
  [[ -n "$env" ]] || die "Missing environment. Usage: $0 <dev|staging|prod>"
  for e in "${ENVIRONMENTS[@]}"; do [[ "$e" == "$env" ]] && return 0; done
  die "Unknown environment '$env'. Must be one of: ${ENVIRONMENTS[*]}"
}

need_kubectl() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  kubectl --context "$CONTEXT" get nodes >/dev/null 2>&1 \
    || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
}

kctl() { kubectl --context "$CONTEXT" "$@"; }

# ---- result tracking -------------------------------------------------------------------------
# Every check appends one line to RESULTS ("PASS <name>", "FAIL <name>: <detail>" or
# "WARN <name>: <detail>") instead of exiting on the spot, so one run reports everything a bad
# deploy got wrong, not just whichever check happened to run first.
RESULTS=()
record_pass() { RESULTS+=("PASS $1"); log_ok "$1"; }
record_fail() { RESULTS+=("FAIL $1: $2"); log_fail "$1: $2"; }
record_warn() { RESULTS+=("WARN $1: $2"); log_warn "$1: $2"; }

check_rollout() {
  log_info "1/6 rollout status (deployment/ai-service, timeout ${ROLLOUT_TIMEOUT})"
  local out
  if out="$(kctl -n "$NS" rollout status deployment/ai-service --timeout="$ROLLOUT_TIMEOUT" 2>&1)"; then
    record_pass "rollout: $out"
  else
    record_fail "rollout" "$out"
  fi
}

check_health() {
  log_info "2/6 GET /healthz through Traefik"
  local out
  if out="$(curl -fsS --max-time 5 -H "Host: $HOST" "$BASE/healthz" 2>&1)" && jq -e '.status == "ok"' <<<"$out" >/dev/null 2>&1; then
    record_pass "healthz: $out"
  else
    record_fail "healthz" "${out:-no response from $BASE/healthz}"
  fi
}

check_ready() {
  log_info "3/6 GET /readyz through Traefik"
  local out
  if out="$(curl -fsS --max-time 5 -H "Host: $HOST" "$BASE/readyz" 2>&1)" && jq -e '.status == "ready"' <<<"$out" >/dev/null 2>&1; then
    record_pass "readyz: $out"
  else
    record_fail "readyz" "${out:-no response from $BASE/readyz}"
  fi
}

check_ai_answer() {
  log_info "4/6 POST /v1/chat and check for a real answer, not just the envelope"
  local out
  if ! out="$(curl -fsS --max-time 10 -H "Host: $HOST" -H 'content-type: application/json' \
      -d '{"tenant_id":"demo","prompt":"post-deploy verification ('"$ENV"')"}' "$BASE/v1/chat" 2>&1)"; then
    record_fail "ai-answer" "POST /v1/chat failed: $out"
    return
  fi
  if ! jq -e 'has("response") and has("model") and has("request_id") and has("latency_ms")' <<<"$out" >/dev/null 2>&1; then
    record_fail "ai-answer" "response is missing a required field: $out"
    return
  fi
  if ! jq -e '.response | length > 0' <<<"$out" >/dev/null 2>&1; then
    record_fail "ai-answer" "response.response was empty: $out"
    return
  fi
  record_pass "ai-answer: $out"
}

check_logs() {
  log_info "5/6 pod logs: present and JSON-parseable (last ${LOG_LINES} lines, ${LOG_WINDOW})"
  local lines
  lines="$(kctl -n "$NS" logs -l app.kubernetes.io/name=ai-service --tail="$LOG_LINES" --since="$LOG_WINDOW" 2>/dev/null || true)"
  if [[ -z "$lines" ]]; then
    record_fail "logs" "no log lines from the last $LOG_WINDOW (are the pods running? make helm-status-$ENV)"
    return
  fi
  local bad=0 total=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    total=$((total + 1))
    jq empty <<<"$line" >/dev/null 2>&1 || bad=$((bad + 1))
  done <<<"$lines"
  if [[ "$total" -eq 0 ]]; then
    record_fail "logs" "no non-empty log lines in the last $LOG_WINDOW"
  elif [[ "$bad" -gt 0 ]]; then
    record_fail "logs" "$bad of $total recent lines are not valid JSON"
  else
    record_pass "logs: $total/$total recent lines are valid JSON"
  fi
}

check_metrics() {
  log_info "6/6 pod resource metrics (advisory — k3s ships metrics-server; Prometheus/app-level metrics arrive in Phase 9/10)"
  local out
  if out="$(kctl top pod -n "$NS" -l app.kubernetes.io/name=ai-service --no-headers 2>&1)" && [[ -n "$out" ]]; then
    record_pass "metrics: $(tr '\n' ';' <<<"$out")"
  else
    record_warn "metrics" "kubectl top pod returned nothing yet (${out:-empty}). Not a deploy failure by itself — metrics-server can take a minute to report after a fresh rollout, and no threshold-based analysis exists until Phase 9/10/18 add Prometheus and Argo Rollouts"
  fi
}

main() {
  local env="${1:-}"; need_env "$env"
  need_kubectl
  have jq || die "jq not found. Run 'make doctor'."
  [[ -n "$INGRESS_PORT" ]] || die "No host port mapped to container port 80 in $CLUSTER_CONFIG"

  ENV="$env"
  NS="$(namespace_for "$env")"
  HOST="$(host_for "$env")"
  [[ -n "$HOST" ]] || die "Could not read ingress.host from $CHART_DIR/values-$env.yaml"
  BASE="http://localhost:${INGRESS_PORT}"

  log_info "post-deploy verification: $env (namespace $NS, release $(release_for "$env"))"
  echo

  check_rollout
  check_health
  check_ready
  check_ai_answer
  check_logs
  check_metrics

  echo
  log_info "summary ($env)"
  local failed=0
  for r in "${RESULTS[@]}"; do
    echo "  $r"
    [[ "$r" == FAIL* ]] && failed=$((failed + 1))
  done

  echo
  if [[ "$failed" -eq 0 ]]; then
    log_ok "POST-DEPLOY VERIFICATION PASSED ($env)"
  else
    die "POST-DEPLOY VERIFICATION FAILED ($env): $failed check(s) failed. See the summary above and docs/troubleshooting.md (Phase 7)."
  fi
}

main "${1:-}"
