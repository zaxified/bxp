#!/usr/bin/env bash
# Desktop-side tests: the Flutter app and the embedded json5_ast package.
#
# Runs flutter analyze + flutter test for bxp-gui plus the Dart unit tests for
# json5_ast, and builds the bridge shared library those tests load.
#
# The generated-documentation drift guard used to live here and does not any
# more: rendering the site is a GitHub Pages concern, not a product one, so it
# belongs to .github/workflows/docs.yml alongside the build that publishes it.
# See docs/dev/testing.md.
#
# Skips cleanly if Flutter is not installed (so contributors who only touch
# the console side don't need the SDK).
#
# Usage (from any directory):
#   bash scripts/test-04-desktop.sh   — this phase alone
#   bash scripts/test.sh              — wrapper runs every phase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

if ! command -v flutter >/dev/null 2>&1; then
    echo "test-04-desktop.sh: flutter SDK not found — skipping"
    exit 0
fi

GUI_ROOT="$MONO_ROOT/bxp-gui"

_flutter_in() {
    local sub="$1"; shift
    (cd "$GUI_ROOT" && flutter "$sub" "$@")
}

_dart_in() {
    local dir="$1"; shift
    (cd "$dir" && dart "$@")
}

_zig_in() {
    local dir="$1"; shift
    (cd "$dir" && zig "$@")
}

section "Desktop"
# Bridge .so is a hard dependency of expr_corpus_bridge_test.dart (cross-runner
# parity gate). Build it here so test-03 is self-contained even when the
# bridge phase (test-04) hasn't run yet — fresh checkouts otherwise hit a
# missing-library failure on the first `bash scripts/test.sh`.
step "$(_lab bridge     'build')"       _zig_in "$MONO_ROOT/bxp-gui-bridge" build -Doptimize=ReleaseSafe -Dcpu=baseline
step "$(_lab flutter    'analyze')"     _flutter_in analyze
step "$(_lab flutter    'test')"        _flutter_in test
step "$(_lab json5_ast  'dart test')"   _dart_in "$GUI_ROOT/packages/json5_ast" test
