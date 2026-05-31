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
source "$SCRIPT_DIR/test-lib.sh"
export BXP_TEST_T0="$(_now)"

# Per-phase wall-clock budgets. Catches hangs (e.g. parser infinite-loop
# regression in the corpus phase) without killing legitimately slow
# phases like Flutter desktop tests. Lookup falls back to no timeout.
declare -A PHASE_BUDGET=(
    [test-06-expr-corpus.sh]=60
    # Cold ReleaseFast build (~50s) + two timed runs; warm zig cache ~1s.
    [test-07-bench-guard.sh]=180
)

shopt -s nullglob
for phase in "$SCRIPT_DIR"/test-[0-9][0-9]-*.sh; do
    budget="${PHASE_BUDGET[$(basename "$phase")]:-}"
    if [[ -n "$budget" ]] && command -v timeout >/dev/null 2>&1; then
        timeout "$budget" bash "$phase" "$@"
    else
        bash "$phase" "$@"
    fi
done

summary
