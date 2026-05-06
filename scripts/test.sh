#!/usr/bin/env bash
# Top-level test wrapper. Calls the console + desktop test scripts in
# sequence; each is independently runnable for focused iterations.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/test-console.sh" "$@"

if [ -x "$SCRIPT_DIR/test-desktop.sh" ]; then
    "$SCRIPT_DIR/test-desktop.sh" "$@"
fi
