#!/usr/bin/env bash
# bxp-gui-bridge unit tests. Exercises the FFI surface (writeResponse /
# writeErr, bridge_run with /bin/true, /bin/false, /bin/echo, cwd handling,
# spawn-failure path, bridge_run_streaming + bridge_cancel) via real child
# processes. Phase isolated from the desktop suite so a broken bridge
# surfaces here instead of inside `flutter test`.
#
# Usage (from any directory):
#   bash scripts/test-04-bridge.sh    — this phase alone
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
step "$(_lab bridge 'build')"      _zig_in "$MONO_ROOT/bxp-gui-bridge" build
step "$(_lab bridge 'unit tests')" _zig_in "$MONO_ROOT/bxp-gui-bridge" build test
