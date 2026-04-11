#!/usr/bin/env bash
# Run all bxp unit and regression tests.
#
# Usage (from any directory):
#   bash scripts/test.sh
#
# Steps:
#   1. Unit tests — bxp-core (csv, expr, json5)
#   2. Build bxp-cli
#   3. Regression tests — for each datasets/<template>/sample.json:
#      a. Runs bxp-cli --config <sample.json>
#      b. Diffs every *.csvx against the matching *.expected
#      c. Reports PASS / FAIL per template

# enable all command debugs
# set -x

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
BXP="$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli"
DATASETS="$MONO_ROOT/datasets"

echo "Running unit tests (bxp-core)..."
(cd "$MONO_ROOT/bxp-core" && zig build test)
echo ""

echo "Building bxp-cli..."
(cd "$MONO_ROOT/bxp-cli" && zig build)
echo ""

PASS=0
FAIL=0
FAILED=()

for sample_json in "$DATASETS"/*/sample.json; do
    template=$(basename "$(dirname "$sample_json")")
    printf "  %-48s " "[$template]"

    "$BXP" --config "$sample_json" > /dev/null

    ok=true
    for expected in "$DATASETS/$template/"*.expected; do
        [[ -f "$expected" ]] || continue
        csvx="${expected%.expected}.csvx"
        if [[ ! -f "$csvx" ]]; then
            echo "FAIL (missing: $(basename "$csvx"))"
            ok=false
            break
        fi
        if ! diff -q "$csvx" "$expected" > /dev/null 2>&1; then
            echo "FAIL (diff: $(basename "$csvx"))"
            diff "$csvx" "$expected" | head -20
            ok=false
            break
        fi
    done

    if $ok; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$template")
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf "  Failed: %s\n" "${FAILED[@]}"
    exit 1
fi

echo "All tests passed."
