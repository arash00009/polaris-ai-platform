#!/usr/bin/env bash
# scripts/demo/tenant-regression.sh — Phase 19 (ADR-40), Scenario 2: "a failure the canary gate
# cannot see, detected by observability, handled by CI/CD + GitOps."
#
# ai-gateway is a plain Deployment (ADR-39's own decision -- Phase 18's Argo Rollouts canary
# covers ai-service only), so NOTHING gates a gateway config change before it reaches 100% of
# traffic. This script deliberately regresses one real tenant's rate limit in
# helm/ai-platform/values-dev.yaml's config.GATEWAY_TENANT_LIMITS_JSON (the one environment
# gateway.enabled is true -- Phase 12), low enough that acme's own normal traffic starts getting
# real 429s, then COMMITS that change directly to this repository -- the same repository Argo
# CD's dev Application already auto-syncs from (ADR-26: "Source 1 is polaris-ai-platform's helm/
# ai-platform chart... Multi-source Helm Applications"). No polaris-gitops touch needed: this is
# exactly the class of change ADR-26 already said does not need one.
#
# --inject commits the regression (and pushes with --push). --revert runs 'git revert' on that
# exact commit (and pushes with --push) -- a real CI/CD + GitOps recovery, not a direct 'helm
# upgrade --set' shortcut like canary-demo.sh's demos use: the point of this scenario is proving
# the git-revert-through-CI/CD-through-GitOps path works, not the Rollout mechanism (which does
# not even apply here).
#
# Usage: scripts/demo/tenant-regression.sh --inject|--revert|--status [--env dev] [--push]
# Normally invoked through the make targets (make failure-demo-tenant-inject, etc.)
#
# Status: written and shellchecked in the sandbox (no cluster, no helm, no git remote access --
# same constraint as every other cluster-facing script in this project). A real commit/push/
# revert cycle against a live cluster and a real GatewayTenantRateLimited alert actually firing
# and clearing is the target-machine verification step -- see docs/failure-engineering.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

CHART_DIR="helm/ai-platform"
MARKER="Phase 19 fault injection (scripts/demo/tenant-regression.sh)"

MODE=""
ENV="dev"
PUSH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inject) MODE="inject"; shift ;;
    --revert) MODE="revert"; shift ;;
    --status) MODE="status"; shift ;;
    --env)    ENV="${2:?--env needs an environment}"; shift 2 ;;
    --push)   PUSH=1; shift ;;
    -h|--help)
      echo "Usage: $0 --inject|--revert|--status [--env dev] [--push]" >&2
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -n "$MODE" ]] || die "Must pass --inject, --revert or --status. Usage: $0 --inject|--revert|--status [--env dev] [--push]"
# Only dev has gateway.enabled: true today (Phase 12) -- see this file's header.
[[ "$ENV" == "dev" ]] || die "--env $ENV has no effect: only values-dev.yaml turns gateway.enabled on (Phase 12). Use --env dev."

VALUES_FILE="$CHART_DIR/values-$ENV.yaml"
[[ -f "$VALUES_FILE" ]] || die "Not found: $VALUES_FILE"

# Rewrites the GATEWAY_TENANT_LIMITS_JSON block in $VALUES_FILE via a small, targeted Python
# edit (reads the file, finds the exact known-good block, replaces it) rather than a general
# YAML round-trip -- the same "do not rewrite a human-maintained values file with a YAML dumper
# and lose every comment in it" reasoning this project has followed since Phase 5.
rewrite_limits() {
  local old_burst="$1" new_burst="$2"
  VALUES_FILE="$VALUES_FILE" OLD_BURST="$old_burst" NEW_BURST="$new_burst" python3 - <<'PYEOF'
import os

path = os.environ["VALUES_FILE"]
old_burst = os.environ["OLD_BURST"]
new_burst = os.environ["NEW_BURST"]

with open(path) as f:
    content = f.read()

old = f'"acme": {{"rate_limit_per_minute": 120, "rate_limit_burst": {old_burst}, "quota_per_day": 5000}}'
new = f'"acme": {{"rate_limit_per_minute": 120, "rate_limit_burst": {new_burst}, "quota_per_day": 5000}}'
if old not in content:
    raise SystemExit(
        f"Expected block not found in {path}: {old!r}. "
        "Someone else may have already changed GATEWAY_TENANT_LIMITS_JSON -- check 'git log' "
        "and 'git diff' before re-running this script."
    )
content = content.replace(old, new, 1)
with open(path, "w") as f:
    f.write(content)
print(f"rewrote {path}: acme rate_limit_burst {old_burst} -> {new_burst}")
PYEOF
}

commit_and_maybe_push() {
  local message="$1"
  git add "$VALUES_FILE"
  if git diff --cached --quiet -- "$VALUES_FILE"; then
    log_warn "Nothing staged in $VALUES_FILE -- is this already the state you expected? ('git diff $VALUES_FILE' to check)"
    return 0
  fi
  git commit -m "$message"
  if [[ "$PUSH" -eq 1 ]]; then
    git push
    log_ok "committed and pushed. polaris-dev syncs automatically (ADR-26: dev's syncPolicy.automated) -- watch for the real effect with 'make failure-demo-tenant-status' or 'kubectl -n polaris-dev get pods -l app.kubernetes.io/name=ai-gateway'."
  else
    log_info "committed locally, not pushed (pass --push to also push). Review first: git show HEAD -- $VALUES_FILE"
  fi
}

cmd_inject() {
  log_info "regressing acme's rate_limit_burst in $VALUES_FILE (120 req/min stays the same -- only burst drops, so sustained traffic degrades rather than every single request failing immediately)"
  rewrite_limits 40 1
  commit_and_maybe_push "fix(dev): tune acme rate limit burst

$MARKER: this is a DELIBERATE real regression (burst 40 -> 1), not an
actual production fix -- the commit message intentionally reads like an
innocuous tuning change, the same way a real regression usually looks
right up until it reaches production. Revert with:
  scripts/demo/tenant-regression.sh --revert --env dev --push"
}

cmd_revert() {
  local last_subject
  last_subject="$(git log -1 --format=%s -- "$VALUES_FILE" 2>/dev/null || true)"
  [[ "$last_subject" == "fix(dev): tune acme rate limit burst" ]] \
    || die "The last commit touching $VALUES_FILE ('$last_subject') does not look like this script's own injected commit. Revert it by hand with 'git revert', or check 'git log -- $VALUES_FILE' first."
  log_info "reverting the injected regression via 'git revert'"
  git revert --no-edit HEAD
  if [[ "$PUSH" -eq 1 ]]; then
    git push
    log_ok "reverted and pushed. polaris-dev syncs automatically -- the real CI/CD + GitOps recovery this scenario exists to prove. Confirm with 'make failure-demo-tenant-status' (the alert should clear within a few minutes once traffic resumes succeeding)."
  else
    log_info "reverted locally, not pushed (pass --push to also push)."
  fi
}

cmd_status() {
  log_info "current acme limits in $VALUES_FILE:"
  grep -A1 "GATEWAY_TENANT_LIMITS_JSON" "$VALUES_FILE" || true
  echo
  "$SCRIPT_DIR/../bootstrap/observability.sh" alerts-status
}

case "$MODE" in
  inject) cmd_inject ;;
  revert) cmd_revert ;;
  status) cmd_status ;;
esac
