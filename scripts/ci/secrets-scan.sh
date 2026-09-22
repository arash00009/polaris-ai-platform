#!/usr/bin/env bash
# scripts/ci/secrets-scan.sh — scan the repository for committed secrets with gitleaks.
#
# Usage: scripts/ci/secrets-scan.sh
# Normally invoked through: make ci-secrets-scan
#
# gitleaks is installed the same way as k3d/kubectl/helm (make tools-install), so this script
# only runs it — it does not install anything itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

REPORT_DIR="artifacts"
REPORT="$REPORT_DIR/gitleaks-report.json"

have gitleaks || die "gitleaks not found. Run: make tools-install (pins \$GITLEAKS_VERSION via versions.env)"

mkdir -p "$REPORT_DIR"

# A full git checkout (the target machine, or a GitHub Actions runner with fetch-depth: 0 or the
# default single-branch clone) lets gitleaks scan the committed history too, so a secret that was
# added and later removed in a follow-up commit is still caught. This repository is not itself a
# git checkout in the sandbox it was developed in (see docs/troubleshooting.md); --no-git there
# falls back to a working-tree-only scan so the script still runs end to end.
GIT_ARGS=()
if [[ -d "$ROOT/.git" ]]; then
  log_info "gitleaks $(gitleaks version 2>/dev/null) scanning the working tree and git history"
else
  log_warn "no .git directory here; scanning the working tree only (history not scannable in this environment)"
  GIT_ARGS=(--no-git)
fi

set +e
gitleaks detect --source "$ROOT" "${GIT_ARGS[@]}" --redact \
  --report-format json --report-path "$REPORT" -v
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  log_ok "no leaks found"
else
  n="$(jq 'length' "$REPORT" 2>/dev/null || echo '?')"
  log_fail "gitleaks found $n potential leak(s). Values are redacted; see $REPORT for file/line/rule."
  exit "$rc"
fi
