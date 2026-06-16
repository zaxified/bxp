#!/usr/bin/env bash
# Console-side build + unit tests (bxp-core, bxp-cli, json5_ast).
# Dataset regression lives in test-07-datasets.sh; desktop tests in
# test-04-desktop.sh. The stateless inspect surface that bxp-fmt used to
# expose (config annotation, expr validation, expr-batch, docs, templates)
# now lives in bxp-core/inspect.zig — its unit tests run in the bxp-core
# phase below, and the agent-facing smoke of the same core runs in
# test-02-mcp.sh (bxp_validate / bxp_validate_expr / bxp_eval_batch).
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

# Build mode: ReleaseSafe across the ENTIRE suite — one optimize mode for the
# whole gate. Rationale: mixing modes widens the error surface (the optimizer
# and safety config differ per mode, so a mode-specific codegen bug can hide in
# the gaps — the 0.15.2 Debug-mode bridge SEGV was exactly such a gap). A test
# gate should minimise that surface, so EVERY phase passes -Doptimize=ReleaseSafe
# explicitly — including the bridge phases (test-03 / test-04). Until Zig 0.16
# the bridge's build.zig force-rewrote Debug→ReleaseSafe, so its phases came out
# ReleaseSafe even without the flag; 0.16 dropped that override (build.zig now
# honours -Doptimize), so the flag must be passed there too or the .dll reverts
# to Debug — a cache miss against this phase's ReleaseSafe core AND an untested
# Debug bridge under the Dart FFI tests. It keeps every runtime
# safety check (overflow / bounds / null / @intCast / unreachable → panic →
# test FAIL), so a passing test still proves UB-freedom. Cost: test binaries
# are slower to compile cold (cached after); accepted for the consistency.
# Release archives are the single deliberate exception (ReleaseSmall, for size —
# explicit -Doptimize override in release-01).
section "Console"
step "$(_lab bxp-core   'unit tests')"  _zig_in "$MONO_ROOT/bxp-core" build test -Doptimize=ReleaseSafe
step "$(_lab bxp-cli    'build')"       _zig_in "$MONO_ROOT/bxp-cli"  build      -Doptimize=ReleaseSafe
step "$(_lab bxp-cli    'unit tests')"  _zig_in "$MONO_ROOT/bxp-cli"  build test -Doptimize=ReleaseSafe
step "$(_lab json5_ast  'unit tests')"  _json5_ast_tests
# Drift guard: the two shipped readmes are generated from resources/readme.src.md
# (scripts/gen-readme.sh). Fail if a committed variant is out of sync with a
# fresh generation — i.e. someone edited a generated readme instead of the source.
step "$(_lab readmes    'src sync')"    bash "$SCRIPT_DIR/gen-readme.sh" --check
