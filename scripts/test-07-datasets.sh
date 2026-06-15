#!/usr/bin/env bash
# Dataset regression: run bxp-cli against every datasets/<template>/sample.json
# and diff every generated *.csvx against the matching *.expected fixture.
#
# Datasets are user-facing demonstration material — they must run clean
# (exit 0, no warnings). A new warning firing on a fixture is a fixture-
# quality bug, not a tolerable corner case; fix the fixture (rename, config
# tweak), do not loosen the test.
#
# Usage (from any directory):
#   bash scripts/test-07-datasets.sh   — this phase alone
#   bash scripts/test.sh               — wrapper runs every phase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

BXP="$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli"
DATASETS="$MONO_ROOT/datasets"

_run_dataset() {
    local template="$1"
    local sample_json="$2"
    # Enforce the phase contract directly: a dataset must run clean
    # (exit 0, no warnings). bxp-cli exits 2 on warnings / 1 on error, so
    # both halves are checked — the exit code AND empty stderr. Without
    # this guard the run sits mid-function and `step`'s `|| rc=$?` wrapper
    # disables `set -e`, so a warning-but-identical-output fixture would
    # pass green (the "fixture rot" the header rejects).
    local stderr_file rc
    stderr_file="$(mktemp)"
    "$BXP" --config "$sample_json" > /dev/null 2> "$stderr_file" || {
        rc=$?
        echo "exit $rc (warnings/error)"
        cat "$stderr_file"
        rm -f "$stderr_file"
        return 1
    }
    if [[ -s "$stderr_file" ]]; then
        echo "non-empty stderr (warnings):"
        cat "$stderr_file"
        rm -f "$stderr_file"
        return 1
    fi
    rm -f "$stderr_file"
    for expected in "$DATASETS/$template/"*.expected; do
        [[ -f "$expected" ]] || continue
        local csvx="${expected%.expected}.csvx"
        if [[ ! -f "$csvx" ]]; then
            echo "missing: $(basename "$csvx")"
            return 1
        fi
        if ! diff -q "$csvx" "$expected" > /dev/null 2>&1; then
            echo "diff: $(basename "$csvx")"
            diff "$csvx" "$expected" | head -20
            return 1
        fi
    done
    # Binary --trace smoke. Verifies the stream starts with the BXTB
    # magic and the producer doesn't crash. Byte-exact diff is intentionally
    # NOT done — file_start frames carry cwd-dependent absolute paths;
    # layout regression is covered by inline tests in bxp-core/src/btrace.zig.
    # This step just confirms the producer still emits a parseable stream
    # for every dataset.
    local actual_bin
    actual_bin="$(mktemp)"
    "$BXP" --trace --config "$sample_json" > "$actual_bin"
    local size
    size=$(stat -c '%s' "$actual_bin")
    if [[ "$size" -lt 4 ]]; then
        echo "bin trace too small ($size bytes)"
        rm -f "$actual_bin"
        return 1
    fi
    local magic
    magic=$(head -c 4 "$actual_bin" | od -An -tx1 | tr -d ' \n')
    if [[ "$magic" != "42585442" ]]; then
        echo "bin trace: bad magic (got $magic, want 42585442)"
        rm -f "$actual_bin"
        return 1
    fi
    rm -f "$actual_bin"
}

section "Datasets"
count=0
for sample_json in "$DATASETS"/*/sample.json; do
    template=$(basename "$(dirname "$sample_json")")
    step "$template" _run_dataset "$template" "$sample_json"
    count=$((count + 1))
done
printf '  %d/%d passed\n' "$count" "$count"
