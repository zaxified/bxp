#!/usr/bin/env bash
# Run the full test suite. Iterates `test-NN-*.sh` siblings in numeric
# order so adding a new test phase = drop a `test-NN-foo.sh` next to
# this file and it picks up automatically.
#
# Usage (from any directory):
#   bash scripts/test.sh              — runs all phases
#
# Each phase is independently runnable: `bash scripts/test-01-console.sh`.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
for phase in "$SCRIPT_DIR"/test-[0-9][0-9]-*.sh; do
    bash "$phase" "$@"
done
