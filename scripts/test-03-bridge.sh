#!/usr/bin/env bash
# bxp-gui-bridge unit tests. Exercises the FFI surface (writeResponse /
# writeErr, bridge_run, cwd handling, spawn-failure path,
# bridge_run_streaming + bridge_cancel) against real child processes — but
# the child is `test/test_helper.zig`, built alongside the tests, not an OS
# binary, so the phase behaves identically on Linux / macOS / Windows.
# Phase isolated from the desktop suite so a broken bridge surfaces here
# instead of inside `flutter test`.
#
# Usage (from any directory):
#   bash scripts/test-03-bridge.sh    — this phase alone
#   bash scripts/test.sh              — wrapper runs every phase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

_zig_in() {
    local dir="$1"; shift
    (cd "$dir" && zig "$@")
}

section "Bridge"
step "$(_lab bridge 'build')"      _zig_in "$MONO_ROOT/bxp-gui-bridge" build      -Doptimize=ReleaseSafe -Dcpu=baseline
step "$(_lab bridge 'unit tests')" _zig_in "$MONO_ROOT/bxp-gui-bridge" build test -Doptimize=ReleaseSafe -Dcpu=baseline
