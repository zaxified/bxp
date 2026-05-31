#!/usr/bin/env bash
# Documentation formatting fix + lint — PRE-RELEASE ONLY.
#
# Deliberately NOT named `test-NN-*.sh`, so `scripts/test.sh` does not auto-run
# it: formatting is not a routine correctness gate. It belongs to the pre-release
# docs review (see memory `feedback_pre_release_review_order`, Krok 3).
#
# Three steps, in order:
#   1. prettier --write  — AUTO-FIXES formatting across owned .md/.json/.jsonc
#      /.yml/.yaml (notably realigns markdown tables). Ignores from
#      `.prettierignore`. This is the fixer, not a check — run it, commit the
#      result; nothing to hand-fix.
#   2. markdownlint-cli2 — verifies markdown semantics (`.markdownlint-cli2.jsonc`).
#   3. mermaid check     — parses every mermaid fence (renders aren't visible to
#      a reviewer; a syntax slip ships a blank graph to GitHub).
#
# Usage (from any directory):
#   bash scripts/check-formatting.sh

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

_prettier_fix() {
    bunx prettier --write "**/*.{md,json,jsonc,yml,yaml}"
}

_markdownlint_check() {
    bunx markdownlint-cli2 "**/*.md"
}

_mermaid_check() {
    local dir="$SCRIPT_DIR/mermaid-check"
    # Lazy install on first run — keeps the dep out of the way for
    # contributors who never touch docs.
    if [ ! -d "$dir/node_modules" ]; then
        (cd "$dir" && bun install --silent)
    fi
    # Filter to tracked .md files that actually contain a mermaid fence
    # — fast path so we don't spin up the parser for every markdown
    # file in the repo.
    local files
    files=$(git ls-files '*.md' | xargs grep -l '^```mermaid' 2>/dev/null || true)
    if [ -z "$files" ]; then
        echo "no mermaid blocks tracked"
        return 0
    fi
    # shellcheck disable=SC2086
    bun "$dir/check.mjs" $files
}

section "Format"
step "$(_lab prettier 'write')" _prettier_fix
step "$(_lab lint-md   'check')" _markdownlint_check
step "$(_lab mermaid   'check')" _mermaid_check
