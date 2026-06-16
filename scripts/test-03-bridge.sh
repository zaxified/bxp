#!/usr/bin/env bash
# bxp-gui-bridge unit tests. Exercises the FFI surface (writeResponse /
# writeErr, bridge_run with /bin/true, /bin/false, /bin/echo, cwd handling,
# spawn-failure path, bridge_run_streaming + bridge_cancel) via real child
# processes. Phase isolated from the desktop suite so a broken bridge
# surfaces here instead of inside `flutter test`.
#
# Usage (from any directory):
#   bash scripts/test-03-bridge.sh    — this phase alone
#   bash scripts/test.sh              — wrapper runs every phase
#
# ── Linux/macOS pre-release proxy smoke ─────────────────────────────────
# Before tagging a release that includes the cross-platform bridge build,
# verify the subprocess proxy path works on Linux (and macOS, when
# available) by manually running:
#
#   cd bxp-gui
#   BXP_FORCE_BRIDGE_PROXY=1 flutter run -d linux
#
# Then in the GUI: open a sample config, run a dry-run, and verify NDJSON
# events stream into the UI via the bridge (file list populates, per-row
# counters update, exit code surfaces normally). The env-var gate routes
# `_runOneShot` / `_runCliTrace` through `bridge_run` / `bridge_run_streaming`
# instead of the default `Process.start` path — same code path Windows
# always takes. Default Linux/macOS behaviour (no env var) stays on
# Process.start, so end users never see the smoke routing.
#
# This step is manual because the existing `flutter test` corpus is pure
# logic (no FFI path coverage) and there's no automated way to validate
# end-to-end GUI behaviour without a display server + sample data wired
# up. Drop the smoke ritual + the `BXP_FORCE_BRIDGE_PROXY` env gate in
# `bxp_process_client.dart` once production traffic has exercised the
# cross-platform proxy build for at least one release cycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

_zig_in() {
    local dir="$1"; shift
    (cd "$dir" && zig "$@")
}

section "Bridge"
step "$(_lab bridge 'build')"      _zig_in "$MONO_ROOT/bxp-gui-bridge" build      -Doptimize=ReleaseSafe
step "$(_lab bridge 'unit tests')" _zig_in "$MONO_ROOT/bxp-gui-bridge" build test -Doptimize=ReleaseSafe
