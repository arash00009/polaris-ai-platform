#!/usr/bin/env bash
# scripts/verify/cosign-verify.sh — Phase 15 session 2 / ADR-35: proves a published GHCR image
# actually carries a real, verifiable Cosign keyless signature from THIS project's own CI
# workflow identity — not just that `cosign sign` ran without error in a CI log Darya cannot see
# from here. This is the target-machine-side half of verifying signing actually works; Kyverno
# (scripts/bootstrap/kyverno.sh) is the separate, in-cluster half (ADR-36).
#
# Usage: scripts/verify/cosign-verify.sh <image-ref-or-digest>
#   e.g. scripts/verify/cosign-verify.sh ghcr.io/<owner>/<repo>/ai-service@sha256:<the digest
#        printed as GHCR_IMAGE_DIGEST= by a real CI publish job run, or by a local
#        `make image-publish` run>
# Normally invoked through `make cosign-verify DIGEST=...`.
#
# Deliberately duplicates image.sh's own ghcr_owner_repo()-shaped owner/repo resolution rather
# than sourcing it — ADR-22's reasoning: a later change to one already-verified script must
# never alter another's behaviour by accident.
#
# Status: written and shellchecked in the sandbox — there is no cosign binary and no real signed
# image here to verify against. The target-machine verification step for this script is
# necessarily sequenced AFTER a real GitHub Actions run of the updated ci.yml has actually
# published and signed an image (unlike every previous phase's target-machine step, this one
# cannot happen on Darya's local k3d workflow alone — see ADR-35's own Context).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

IMAGE_REF="${1:-}"
[[ -n "$IMAGE_REF" ]] \
  || die "Usage: $0 <image-ref-or-digest> (the GHCR_IMAGE_DIGEST= value a real publish job or 'make image-publish' printed; see docs/security/image-signing.md)"

have cosign || die "cosign not found. Run 'make tools-install' (or: scripts/bootstrap/install-tools.sh --only cosign)."

owner_repo_from_origin() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' <<<"$url"
}

OWNER_REPO="${GITHUB_REPOSITORY:-$(owner_repo_from_origin)}"
[[ -n "$OWNER_REPO" && "$OWNER_REPO" == */* ]] \
  || die "Could not determine the GitHub owner/repo. Set GITHUB_REPOSITORY=owner/repo, or run inside a checkout with a GitHub 'origin' remote."

# Keyless verification needs the exact workflow identity cosign signed as, per ADR-35's Decision:
# this repo's own .github/workflows/ci.yml, running on main. A PR run (no id-token: write there —
# only the publish job has it, and publish only runs on a push to main) or a different workflow
# file would sign under a different subject and correctly fail verification against this one.
IDENTITY="https://github.com/${OWNER_REPO}/.github/workflows/ci.yml@refs/heads/main"
ISSUER="https://token.actions.githubusercontent.com"

log_info "verifying $IMAGE_REF was signed by $IDENTITY (issuer: $ISSUER)"
cosign verify \
  --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" \
  "$IMAGE_REF"
log_ok "signature verified: $IMAGE_REF"
