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
#   bash scripts/test-02-datasets.sh   — this phase alone
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
    "$BXP" --config "$sample_json" > /dev/null
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
    # Optional trace snapshot diff. When a *.expected.trace.ndjson sits next
    # to the dataset, re-run with --trace and structurally compare each
    # NDJSON line (via jq -S so semantically-equivalent JSON with different
    # key ordering doesn't fail the diff). This protects the trace protocol
    # from accidental drift without locking byte-exact output. Skipped when
    # `jq` is missing so the suite still runs on minimal CI images.
    for expected_trace in "$DATASETS/$template/"*.expected.trace.ndjson; do
        [[ -f "$expected_trace" ]] || continue
        if ! command -v jq > /dev/null 2>&1; then
            echo "skip (no jq): $(basename "$expected_trace")"
            continue
        fi
        local actual_trace
        actual_trace="$(mktemp)"
        "$BXP" --trace --config "$sample_json" > "$actual_trace"
        # Normalise both sides through jq -cS (compact + sort keys) so the
        # diff catches structural drift but not whitespace / key-order noise.
        # Also redact path/config string values — those vary with the
        # invocation cwd (relative vs absolute path the caller passed),
        # which has nothing to do with the trace protocol contract.
        local norm_expected norm_actual
        norm_expected="$(mktemp)"
        norm_actual="$(mktemp)"
        jq -cS '.path? = "REDACTED" | .config? = "REDACTED"' < "$expected_trace" > "$norm_expected"
        jq -cS '.path? = "REDACTED" | .config? = "REDACTED"' < "$actual_trace" > "$norm_actual"
        if ! diff -q "$norm_expected" "$norm_actual" > /dev/null 2>&1; then
            echo "trace diff: $(basename "$expected_trace")"
            diff "$norm_expected" "$norm_actual" | head -20
            rm -f "$actual_trace" "$norm_expected" "$norm_actual"
            return 1
        fi
        rm -f "$actual_trace" "$norm_expected" "$norm_actual"
    done
    # Binary --trace=bin smoke. Verifies the stream starts with the BXTB
    # magic + schema version 1 and the producer doesn't crash. Byte-exact
    # diff is intentionally NOT done — file_start frames carry cwd-dependent
    # absolute paths; layout regression is covered by inline tests in
    # bxp-core/src/btrace.zig. This step just confirms the new producer
    # still emits a parseable stream for every dataset.
    local actual_bin
    actual_bin="$(mktemp)"
    "$BXP" --trace=bin --config "$sample_json" > "$actual_bin"
    local size
    size=$(stat -c '%s' "$actual_bin")
    if [[ "$size" -lt 8 ]]; then
        echo "bin trace too small ($size bytes)"
        rm -f "$actual_bin"
        return 1
    fi
    local magic
    magic=$(head -c 8 "$actual_bin" | od -An -tx1 | tr -d ' \n')
    if [[ "$magic" != "4258544201000000" ]]; then
        echo "bin trace: bad magic/version (got $magic, want 4258544201000000)"
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
