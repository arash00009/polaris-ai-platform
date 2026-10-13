#!/usr/bin/env bash
# scripts/verify/tenant-tiers.sh — Phase 14: proves the three tenants seeded in
# deploy/platform/gateway/api-keys.dev.local.json actually get three DIFFERENT rate-limit
# tiers from the real, deployed gateway, not just three different tenant_ids sharing one flat
# limit (which is all Phase 12 built -- see ADR-30's own "Revisit when" column, closed by
# ADR-32). This does not re-check anything scripts/deploy/helm.sh's own `smoke` already covers
# (health, auth, the chat contract) -- it is the one NEW thing this phase adds: hammer each
# tenant's own token bucket through the real ingress until it 429s, and assert the three
# survival counts are ordered premium > standard > trial, matching values-dev.yaml's
# GATEWAY_TENANT_LIMITS_JSON (acme burst 40, demo burst 20, globex burst 5).
#
# Usage: scripts/verify/tenant-tiers.sh [dev]
# Normally invoked through `make tenants-smoke`. dev is the only environment gateway.enabled is
# true for (helm/ai-platform/values-dev.yaml), so it is also the only one this script supports.
#
# Deliberately duplicates helm.sh's own host/port/key resolution rather than sourcing it --
# ADR-22's reasoning: a change to one already-verified script must never alter another's
# behaviour by accident.
#
# Status: written and shellchecked in the sandbox, where there is no cluster and no
# api-keys.dev.local.json (gitignored, provisioned only on the target machine) to run this
# against. Its first real run is the target-machine verification step for this phase.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

CHART_DIR="helm/ai-platform"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
GATEWAY_KEYS_DIR="deploy/platform/gateway"
ENV="${1:-dev}"

[[ "$ENV" == "dev" ]] || die "Only 'dev' has gateway.enabled: true (values-$ENV.yaml). Usage: $0 [dev]"

need_jq()  { have jq  || die "jq not found. Run 'make tools-install'."; }
need_curl() { have curl || die "curl not found."; }
need_jq
need_curl

INGRESS_PORT="$(host_port_for "$CLUSTER_CONFIG" 80)"
[[ -n "$INGRESS_PORT" ]] || die "No host port mapped to container port 80 in $CLUSTER_CONFIG"
HOST="$(awk '/^ingress:/{f=1} f && /host:/{gsub(/"/,"",$2); print $2; exit}' "$CHART_DIR/values-$ENV.yaml")"
[[ -n "$HOST" ]] || die "Could not read ingress.host from $CHART_DIR/values-$ENV.yaml"
BASE="http://localhost:${INGRESS_PORT}"

KEYS_FILE="$GATEWAY_KEYS_DIR/api-keys.$ENV.local.json"
[[ -f "$KEYS_FILE" ]] || die "$KEYS_FILE not found. See $GATEWAY_KEYS_DIR/api-keys.$ENV.example.json — this phase needs all three tenants (demo, acme, globex) provisioned."

api_key_for() {
  local tenant="$1"
  jq -r --arg t "$tenant" 'to_entries[] | select(.value == $t) | .key' "$KEYS_FILE" 2>/dev/null | head -n1
}

# Hammers one tenant's /v1/chat as fast as this shell can issue curls (burst exhaustion, not
# the slow per-minute refill, is what this counts -- see ratelimit.py's TokenBucketLimiter)
# until it sees a 429 or hits $2 attempts, and prints how many requests succeeded (200) before
# that. Cluster start-up jitter means the very first call or two can occasionally see a
# transient non-200/429 (e.g. a cold Ollama request still finishing, Phase 11/ADR-29) -- those
# are not counted as the tenant's burst answer either way, just retried silently up to the
# attempt budget, since this script is about the rate limiter, not upstream latency.
survival_count() {
  local tenant="$1" api_key="$2" max_attempts="$3"
  local ok=0 attempt=0 status
  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -H "Host: $HOST" -H "x-api-key: $api_key" -H 'content-type: application/json' \
      -d "{\"tenant_id\":\"$tenant\",\"prompt\":\"tenant-tiers verify\"}" "$BASE/v1/chat")"
    case "$status" in
      200) ok=$((ok + 1)) ;;
      429) printf '%s' "$ok"; return 0 ;;
      *) ;; # transient (see comment above) -- not counted, not fatal, just retried
    esac
  done
  printf '%s' "$ok"
}

log_info "Resolving API keys for demo/acme/globex from $KEYS_FILE"
demo_key="$(api_key_for demo)"
acme_key="$(api_key_for acme)"
globex_key="$(api_key_for globex)"
[[ -n "$demo_key" ]]   || die "No 'demo' tenant key in $KEYS_FILE."
[[ -n "$acme_key" ]]   || die "No 'acme' tenant key in $KEYS_FILE. Phase 14 needs all three tenants provisioned."
[[ -n "$globex_key" ]] || die "No 'globex' tenant key in $KEYS_FILE. Phase 14 needs all three tenants provisioned."

# Attempt budgets are each tenant's own configured burst + 5 -- enough headroom to definitely
# see the 429 (confirming the ceiling is real) without hammering the trial tenant hundreds of
# times for no reason. These numbers must track values-dev.yaml's GATEWAY_TENANT_LIMITS_JSON
# (acme burst 40, globex burst 5) and gateway/config.py's own default (demo's standard burst
# 20) -- if that file changes, this script's expected ordering below still holds as long as
# acme > demo > globex stays true, but these three budgets may need raising to keep seeing a
# real 429 rather than running out of attempts first.
log_info "Hammering each tenant's /v1/chat until it 429s (burst exhaustion)..."
demo_ok="$(survival_count demo "$demo_key" 25)"
log_info "demo (standard tier):   $demo_ok requests survived before 429"
acme_ok="$(survival_count acme "$acme_key" 45)"
log_info "acme (premium tier):    $acme_ok requests survived before 429"
globex_ok="$(survival_count globex "$globex_key" 10)"
log_info "globex (trial tier):    $globex_ok requests survived before 429"

[[ "$acme_ok" -gt "$demo_ok" ]] || die "Expected acme (premium) to survive MORE requests than demo (standard): acme=$acme_ok demo=$demo_ok. Check values-dev.yaml's GATEWAY_TENANT_LIMITS_JSON actually reached the gateway (kubectl -n polaris-dev describe configmap ai-gateway-config)."
[[ "$demo_ok" -gt "$globex_ok" ]] || die "Expected demo (standard) to survive MORE requests than globex (trial): demo=$demo_ok globex=$globex_ok."

log_ok "Three tenants, three real tiers: acme ($acme_ok) > demo ($demo_ok) > globex ($globex_ok)."
log_ok "TENANT TIERS VERIFIED ($ENV)"
