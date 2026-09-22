#!/usr/bin/env bash
# scripts/ci/workflow-lint.sh — validate .github/workflows/*.yml two ways:
#   yamllint   — YAML style and syntax (indentation, trailing spaces, document structure)
#   actionlint — GitHub-Actions-specific correctness (unknown inputs/contexts, invalid
#                expressions, and shellcheck run against every `run:` block)
#
# Usage: scripts/ci/workflow-lint.sh
# Normally invoked through: make ci-workflow-lint
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_versions
ROOT="$(repo_root)"
cd "$ROOT"

WORKFLOW_DIR=".github/workflows"
VENV=".venv-ci"

[[ -d "$WORKFLOW_DIR" ]] || die "$WORKFLOW_DIR not found"
have actionlint || die "actionlint not found. Run: make tools-install (pins \$ACTIONLINT_VERSION via versions.env)"
have python3 || die "python3 not found. Run 'make doctor'."

if [[ ! -x "$VENV/bin/yamllint" ]]; then
  log_info "creating $VENV and installing yamllint==${YAMLLINT_VERSION}"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet "yamllint==${YAMLLINT_VERSION}"
fi

log_info "yamllint $("$VENV/bin/yamllint" --version 2>&1) checking $WORKFLOW_DIR"
if "$VENV/bin/yamllint" -c .yamllint.yml "$WORKFLOW_DIR"; then
  log_ok "yamllint: no issues"
else
  die "yamllint found issues in $WORKFLOW_DIR (see above)"
fi

log_info "actionlint $(actionlint -version 2>&1 | head -n1) checking $WORKFLOW_DIR (shellcheck runs on every 'run:' block automatically)"
if actionlint "$WORKFLOW_DIR"/*.yml; then
  log_ok "actionlint: no issues"
else
  die "actionlint found issues in $WORKFLOW_DIR (see above)"
fi
