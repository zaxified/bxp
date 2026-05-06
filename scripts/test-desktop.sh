#!/usr/bin/env bash
# Run desktop-side tests: flutter analyze + flutter test for bxp-gui plus
# Dart unit tests for the embedded json5_ast package. Skips cleanly if
# Flutter is not installed (so contributors who only touch the console
# side don't need the SDK).
#
# Usage (from any directory):
#   bash scripts/test-desktop.sh         — desktop suite alone
#   bash scripts/test.sh                 — wrapper runs both halves

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"

if ! command -v flutter >/dev/null 2>&1; then
    echo "test-desktop.sh: flutter SDK not found — skipping"
    exit 0
fi

cd "$MONO_ROOT/bxp-gui"

echo "Running flutter analyze..."
flutter analyze

echo "Running flutter test..."
flutter test

echo "Running json5_ast dart tests..."
(cd packages/json5_ast && dart test)

echo "All desktop tests passed."
