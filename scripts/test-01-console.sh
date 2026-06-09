#!/usr/bin/env bash
# Console-side build + unit tests (bxp-core, bxp-cli, json5_ast).
# Dataset regression lives in test-02-datasets.sh; desktop tests in
# test-03-desktop.sh. The stateless inspect surface that bxp-fmt used to
# expose (config annotation, expr validation, expr-batch, docs, templates)
# now lives in bxp-core/inspect.zig — its unit tests run in the bxp-core
# phase below, and the agent-facing smoke of the same core runs in
# test-05-mcp.sh (bxp_validate / bxp_validate_expr / bxp_eval_batch).
#
# Usage (from any directory):
#   bash scripts/test-01-console.sh   — this phase alone
#   bash scripts/test.sh              — wrapper runs every phase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

_zig_in() {
    local dir="$1"; shift
    (cd "$dir" && zig "$@")
}

_json5_ast_tests() {
    local d="$MONO_ROOT/bxp-gui/packages/json5_ast"
    [[ -d "$d" ]] || return 0
    command -v dart >/dev/null 2>&1 || return 0
    (cd "$d" && dart test)
}

section "Console"
step "$(_lab bxp-core   'unit tests')"  _zig_in "$MONO_ROOT/bxp-core" build test
step "$(_lab bxp-cli    'build')"       _zig_in "$MONO_ROOT/bxp-cli"  build
step "$(_lab bxp-cli    'unit tests')"  _zig_in "$MONO_ROOT/bxp-cli"  build test
step "$(_lab json5_ast  'unit tests')"  _json5_ast_tests
# Drift guard: the two shipped readmes are generated from resources/readme.src.md
# (scripts/gen-readme.sh). Fail if a committed variant is out of sync with a
# fresh generation — i.e. someone edited a generated readme instead of the source.
step "$(_lab readmes    'src sync')"    bash "$SCRIPT_DIR/gen-readme.sh" --check
