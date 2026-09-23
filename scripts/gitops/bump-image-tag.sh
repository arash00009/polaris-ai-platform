#!/usr/bin/env bash
# scripts/gitops/bump-image-tag.sh — Phase 8: write the current image tag into one environment's
# environments/<env>/image.yaml fragment in a local polaris-gitops checkout, and optionally
# commit and push it.
#
# This is the manual equivalent of what a CI "image promotion" job would do automatically. It is
# deliberately NOT wired into .github/workflows/ci.yml this phase — ADR-26 explains why: changing
# the already-green Phase 6 pipeline (ADR-24) to also push into a second repository is a real risk
# to something already verified working, so it is left as a named next step instead of an
# untested addition made under this phase's scope. Run this by hand after 'make image-build &&
# make image-push' — the same two steps every helm-apply-* target has always required (see
# docs/troubleshooting.md's "Tag ... is not in the local registry" row).
#
# Usage: scripts/gitops/bump-image-tag.sh <dev|staging|prod> [GITOPS_DIR] [--push]
#   GITOPS_DIR   path to a polaris-gitops checkout (default: a sibling of this repository)
#   --push       also `git commit` and `git push` the change there. Without it, the file is
#                written and left for you to review with `git diff` before pushing yourself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

APP_DIR="app/ai_service"
IMAGE_REPO="polaris/ai-service"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
ENVIRONMENTS=(dev staging prod)

# Deliberately duplicated from scripts/deploy/helm.sh (itself duplicated from scripts/build/
# image.sh / scripts/deploy/app.sh) rather than shared — a change here must never alter a
# previous phase's already-verified script (ADR-22).
app_version() { awk -F'"' '/^version = / {print $2; exit}' "$APP_DIR/pyproject.toml"; }
app_revision() {
  local rev
  rev="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
  [[ -n "$rev" ]] || { printf 'unknown'; return; }
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then rev="$rev-dirty"; fi
  printf '%s' "$rev"
}

VERSION="$(app_version)"
REVISION="$(app_revision)"
TAG="$VERSION-$REVISION"

REG_NAME="$(awk '/create:/{f=1} f && /name:/{print $2; exit}' "$CLUSTER_CONFIG")"
[[ -n "$REG_NAME" ]] || die "Could not read the registry name from $CLUSTER_CONFIG"
IMAGE_REPOSITORY="$REG_NAME:5000/$IMAGE_REPO"

need_env() {
  local env="${1:-}"
  [[ -n "$env" ]] || die "Missing environment. Usage: $0 <dev|staging|prod> [GITOPS_DIR] [--push]"
  for e in "${ENVIRONMENTS[@]}"; do [[ "$e" == "$env" ]] && return 0; done
  die "Unknown environment '$env'. Must be one of: ${ENVIRONMENTS[*]}"
}

need_pushed() {
  have curl || die "curl not found. Run 'make doctor'."
  local tags
  tags="$(curl -fsS "http://localhost:5000/v2/$IMAGE_REPO/tags/list" 2>/dev/null || true)"
  if ! grep -q "\"$TAG\"" <<<"$tags"; then
    die "Tag $TAG is not in the local registry (localhost:5000). Run: make image-build && make image-push"
  fi
}

ENV="${1:-}"; need_env "$ENV"
shift || true
GITOPS_DIR="$ROOT/../polaris-gitops"
PUSH=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    *) GITOPS_DIR="$arg" ;;
  esac
done

IMAGE_FILE="$GITOPS_DIR/environments/$ENV/image.yaml"
[[ -f "$IMAGE_FILE" ]] || die "Not found: $IMAGE_FILE. Clone polaris-gitops next to this repository, or pass its path as the second argument."

need_pushed

log_info "bumping $ENV -> $IMAGE_REPOSITORY:$TAG in $IMAGE_FILE"
cat > "$IMAGE_FILE" <<EOF
# environments/$ENV/image.yaml — the only field this Application source contributes (see
# apps/$ENV-app.yaml): helm/ai-platform/values.yaml deliberately has no default image.tag
# (ADR-19), so Argo CD supplies it from here instead of a human running 'helm --set
# image.tag=...' by hand. Written by scripts/gitops/bump-image-tag.sh in polaris-ai-platform —
# do not hand-edit the tag without also running 'make image-build && make image-push' there, or
# Argo CD will sync to an image that does not exist in the local registry.
image:
  repository: $IMAGE_REPOSITORY
  tag: "$TAG"
EOF

log_ok "wrote $IMAGE_FILE"

if [[ "$PUSH" -eq 1 ]]; then
  git -C "$GITOPS_DIR" add "environments/$ENV/image.yaml" \
    || die "git add failed in $GITOPS_DIR"
  # Re-running this with --push when $ENV is already at $TAG (e.g. the same promotion command
  # pasted twice) must not be treated as a failure: 'git commit' exits non-zero when there is
  # nothing staged, which the old code let fall straight into the die() below with a misleading
  # "is it a clean checkout" message even though the checkout was perfectly fine -- a real bug
  # found on a real run (see docs/troubleshooting.md, Phase 8). Checking for staged changes first
  # makes the no-op case an explicit, honest log line instead.
  if git -C "$GITOPS_DIR" diff --cached --quiet -- "environments/$ENV/image.yaml"; then
    log_ok "$ENV in $GITOPS_DIR is already at $TAG — nothing to commit or push."
  else
    if ! git -C "$GITOPS_DIR" commit -m "chore($ENV): bump image tag to $TAG"; then
      die "git commit failed in $GITOPS_DIR — is it a clean checkout with a remote configured?"
    fi
    if ! git -C "$GITOPS_DIR" push; then
      die "git push failed in $GITOPS_DIR — is the remote reachable and does the repository exist on GitHub?"
    fi
    log_ok "committed and pushed. dev/staging sync automatically; prod needs an explicit manual sync — see the Phase 8 guide's 'Steg' on promotion."
  fi
else
  log_info "not pushed (pass --push to commit and push in one step). Review first: cd $GITOPS_DIR && git diff"
fi
