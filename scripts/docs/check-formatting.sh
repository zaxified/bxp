#!/usr/bin/env bash
# Documentation mermaid check — PRE-RELEASE ONLY.
#
# Deliberately NOT named `test-NN-*.sh`, so `scripts/test.sh` does not auto-run
# it: it belongs to the pre-release docs review (see memory
# `feedback_pre_release_review_order`, Krok 3).
#
# Markdown formatting is hand-maintained. prettier and markdownlint were
# dropped: both reflow / mis-lint MkDocs-specific syntax (pymdownx `!!!`
# admonitions, Material `grid cards` — whose 4-space content indent marks
# block membership) and silently break the rendered docs. The one mechanical
# check left is mermaid:
#
#   mermaid check — parses every mermaid fence (renders aren't visible to a
#   reviewer; a syntax slip ships a blank graph to GitHub).
#
# Usage (from any directory):
#   bash scripts/docs/check-formatting.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$MONO_ROOT/scripts/test-lib.sh"

cd "$MONO_ROOT"

# bun runs the mermaid parser. If bun is missing, skip loudly so a contributor
# on a stripped-down machine doesn't get a hard failure on a docs-only check.
if ! command -v bun >/dev/null 2>&1; then
    echo
    printf 'Docs check '; printf '─%.0s' {1..48}; echo
    echo "  bun       missing — install bun to enable the mermaid check"
    echo "  https://bun.sh/docs/installation"
    exit 0
fi

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

section "Docs"
step "$(_lab mermaid   'check')" _mermaid_check
