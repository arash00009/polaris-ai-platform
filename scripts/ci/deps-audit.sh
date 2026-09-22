#!/usr/bin/env bash
# scripts/ci/deps-audit.sh — audit the AI service's pinned runtime dependencies for known
# vulnerabilities with pip-audit.
#
# Scope: app/ai_service/requirements.txt only — what actually ships in the container image (see
# app/ai_service/.dockerignore, which excludes requirements-dev.txt from the build). Dev-only
# tools (pytest, ruff, ...) never run in production and are out of scope here, the same
# runtime/dev split Trivy's image scan (Phase 3) already draws.
#
# Usage: scripts/ci/deps-audit.sh
# Normally invoked through: make ci-deps-audit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

VENV=".venv-ci"
REQ="app/ai_service/requirements.txt"
REPORT_DIR="artifacts"
REPORT="$REPORT_DIR/pip-audit-report.json"
LOG="$REPORT_DIR/pip-audit.log"

have python3 || die "python3 not found. Run 'make doctor'."
[[ -f "$REQ" ]] || die "$REQ not found"

mkdir -p "$REPORT_DIR"

if [[ ! -x "$VENV/bin/pip-audit" ]]; then
  log_info "creating $VENV and installing pip-audit==${PIP_AUDIT_VERSION}"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet "pip-audit==${PIP_AUDIT_VERSION}"
fi

log_info "pip-audit $("$VENV/bin/pip-audit" --version 2>&1) auditing $REQ"

set +e
"$VENV/bin/pip-audit" -r "$REQ" --progress-spinner off --format json \
  >"$REPORT" 2>"$LOG"
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  log_ok "no known vulnerabilities in $REQ. Report: $REPORT"
else
  log_fail "pip-audit found known vulnerabilities (or failed to run) auditing $REQ:"
  cat "$LOG" >&2 || true
  if have jq && jq -e . "$REPORT" >/dev/null 2>&1; then jq . "$REPORT" >&2; else cat "$REPORT" >&2 || true; fi
  exit "$rc"
fi
