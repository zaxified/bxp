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

# Per-phase wall-clock budgets (seconds). Catches hangs (e.g. a parser
# infinite-loop regression in the corpus phase) without killing legitimately
# slow phases like the Flutter desktop tests. Unbudgeted phases get no timeout.
#
# A plain `case` function, NOT a `declare -A` associative array: macOS ships
# bash 3.2 (no associative arrays), where `declare -A` evaluates the `.sh` key
# as arithmetic, errors, and the whole gate silently no-ops to a false green
# ("All passed 0.0s", zero phases run). bash 3.2 portability is mandatory here.
phase_budget() {
    case "$1" in
        # Recycles the Console phase's ReleaseSafe bxp-cli (cache hit), then runs
        # a handful of synthetic-input points; a cold standalone build pushes up.
        test-05-bench-guard.sh) echo 180 ;;
        test-06-expr-corpus.sh) echo 60 ;;
        *)                      echo "" ;;
    esac
}

shopt -s nullglob
ran=0
for phase in "$SCRIPT_DIR"/test-[0-9][0-9]-*.sh; do
    ran=$((ran + 1))
    budget="$(phase_budget "$(basename "$phase")")"
    if [[ -n "$budget" ]] && command -v timeout >/dev/null 2>&1; then
        timeout "$budget" bash "$phase" "$@"
    else
        bash "$phase" "$@"
    fi
done

# Guard against a silent no-op (the bash 3.2 / empty-glob class of failure):
# if the gate matched zero phases, fail loudly instead of a vacuous success.
if [[ "$ran" -eq 0 ]]; then
    echo "test.sh: no test-NN-*.sh phases matched in $SCRIPT_DIR — refusing to pass" >&2
    exit 1
fi

summary
