#!/usr/bin/env bash
# scripts/demo/break-image-tag.sh — Phase 19 (ADR-40), Scenario 3: "a failure the Rollout's own
# AnalysisTemplate cannot see either, detected by observability, handled by CI/CD + GitOps."
#
# Writes a deliberately nonexistent image tag into polaris-gitops' environments/<env>/image.yaml
# (the exact file scripts/gitops/bump-image-tag.sh normally writes a REAL, already-pushed tag
# into -- ADR-26). Argo CD syncs it like any other change; the new canary ReplicaSet's pods can
# never pull the image, so they never become Ready, so the Rollout's AnalysisTemplate (Phase 18)
# never even starts analysing -- zero traffic ever reaches those pods, so there is no success-
# rate/latency signal to query in the first place. This is a real, different gap from Scenario
# 1/2: not a bad canary the Rollout's own analysis catches, and not a plain Deployment the
# canary never covered -- a canary that is simply stuck, which looks identical to "a slow,
# healthy rollout" to anything that only watches ai_requests_total/ai_chat_duration_seconds.
# AIServiceCrashLooping (alerting-rules.yaml) is the signal that actually distinguishes the two.
#
# Recovery deliberately reuses scripts/gitops/bump-image-tag.sh as-is -- no new revert logic:
# that script already writes back the real, current, already-pushed tag and refuses to write
# one that is not in the registry (ADR-26's own "need_pushed" guard), which is exactly undoing
# this script's fault injection. See this script's own final log line.
#
# Usage: scripts/demo/break-image-tag.sh <dev|staging|prod> [GITOPS_DIR] [--push]
# Recovery:  scripts/gitops/bump-image-tag.sh <dev|staging|prod> [GITOPS_DIR] --push
# Normally invoked through: make failure-demo-image-break ARGS="--env staging"
#
# Status: written and shellchecked in the sandbox (no cluster, no git remote access). A real
# ImagePullBackOff, a real AIServiceCrashLooping alert firing, and a real recovery via
# bump-image-tag.sh are the target-machine verification step -- see docs/failure-engineering.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

ENVIRONMENTS=(dev staging prod)
MARKER="Phase 19 fault injection (scripts/demo/break-image-tag.sh)"

ENV="${1:-}"
[[ -n "$ENV" ]] || die "Usage: $0 <dev|staging|prod> [GITOPS_DIR] [--push]"
found=0
for e in "${ENVIRONMENTS[@]}"; do [[ "$e" == "$ENV" ]] && found=1; done
[[ "$found" -eq 1 ]] || die "Unknown environment '$ENV'. Must be one of: ${ENVIRONMENTS[*]}"
shift

GITOPS_DIR="$ROOT/../polaris-gitops"
PUSH=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    *) GITOPS_DIR="$arg" ;;
  esac
done

IMAGE_FILE="$GITOPS_DIR/environments/$ENV/image.yaml"
[[ -f "$IMAGE_FILE" ]] || die "Not found: $IMAGE_FILE. This environment must already have a real tag bumped in at least once (scripts/gitops/bump-image-tag.sh) before this script can break it."

CURRENT_TAG="$(awk -F'"' '/^  tag:/ {print $2; exit}' "$IMAGE_FILE")"
[[ -n "$CURRENT_TAG" ]] || die "Could not find an 'image: / tag: \"...\"' line in $IMAGE_FILE -- is it in the format scripts/gitops/bump-image-tag.sh writes?"
BROKEN_TAG="${CURRENT_TAG}-phase19-fault-injected-does-not-exist"

log_info "breaking $ENV's ai-service image tag in $IMAGE_FILE: $CURRENT_TAG -> $BROKEN_TAG (deliberately not in any registry)"
# Replaces only the FIRST 'tag: "..."' line -- image.tag is always written before any gateway
# block by bump-image-tag.sh (see its own header), so this never touches gateway.image.tag even
# when it is present.
python3 - "$IMAGE_FILE" "$BROKEN_TAG" <<'PYEOF'
import re
import sys

path, broken_tag = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
new_content, count = re.subn(
    r'(\n  tag: ")[^"]*(")', rf'\g<1>{broken_tag}\g<2>', content, count=1
)
if count != 1:
    raise SystemExit(f"Could not find exactly one 'tag: \"...\"' line to replace in {path}")
with open(path, "w") as f:
    f.write(new_content)
PYEOF

git -C "$GITOPS_DIR" add "environments/$ENV/image.yaml"
if git -C "$GITOPS_DIR" diff --cached --quiet -- "environments/$ENV/image.yaml"; then
  die "Nothing staged after the edit -- something went wrong; check $IMAGE_FILE by hand."
fi
git -C "$GITOPS_DIR" commit -m "chore($ENV): bump image tag to $BROKEN_TAG

$MARKER: this tag does NOT exist in the registry on purpose. Recover with:
  scripts/gitops/bump-image-tag.sh $ENV $GITOPS_DIR --push"

if [[ "$PUSH" -eq 1 ]]; then
  git -C "$GITOPS_DIR" push
  log_ok "committed and pushed. Argo CD syncs this within its poll interval; the new canary ReplicaSet's pod(s) should start reporting ImagePullBackOff shortly after. Watch with: kubectl-argo-rollouts -n polaris-$ENV get rollout ai-service --watch, or ./scripts/bootstrap/observability.sh alerts-status (make obs-alerts-status) once AIServiceCrashLooping has had its 2m 'for' window."
else
  log_info "committed locally in $GITOPS_DIR, not pushed (pass --push to also push). Review first: git -C $GITOPS_DIR show HEAD"
fi

log_info "Recover: scripts/gitops/bump-image-tag.sh $ENV $GITOPS_DIR --push (writes back the real, already-pushed tag -- no new revert logic needed, see this script's header)"
