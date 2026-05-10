#!/usr/bin/env bash
# Formatting + markdown-lint check.
#
# Runs prettier --check and markdownlint-cli2 across owned .md/.json/.jsonc
# /.yml/.yaml files. Ignores are read from `.prettierignore` and the project
# `.markdownlint-cli2.jsonc`. Phase fails if any file would change under
# prettier --write or any markdownlint rule fires — encourages contributors
# (and Claude) to run `bunx prettier --write` + fix lint issues before commit.
#
# Usage (from any directory):
#   bash scripts/test-05-format.sh   — this phase alone
#   bash scripts/test.sh             — wrapper runs every phase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

cd "$MONO_ROOT"

# bunx is the entry point — it resolves `prettier` / `markdownlint-cli2`
# through Bun's package cache, no global install required. If bun is
# missing, skip the phase loudly so a contributor on a stripped-down
# machine doesn't get a hard failure on what's really a lint suite.
if ! command -v bunx >/dev/null 2>&1; then
    echo
    printf 'Format suite '; printf '─%.0s' {1..48}; echo
    echo "  bun       missing — install bun to enable format/lint checks"
    echo "  https://bun.sh/docs/installation"
    exit 0
fi

_prettier_check() {
    bunx prettier --check "**/*.{md,json,jsonc,yml,yaml}"
}

_markdownlint_check() {
    bunx markdownlint-cli2 "**/*.md"
}

section "Format"
step "$(_lab prettier 'check')" _prettier_check
step "$(_lab lint-md   'check')" _markdownlint_check
