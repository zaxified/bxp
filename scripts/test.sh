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

# bxp-fmt's negative unit tests deliberately fire `loadFromBytes` paths
# that emit a human-readable stderr line alongside the structured
# Diagnostic. The structured assertion is what the test verifies; the
# stderr line is harmless leakage that makes the success run look like
# it failed. Capture stderr per zig invocation and only surface it when
# the command actually fails.
run_zig_quiet() {
    local err
    err=$(mktemp)
    local rc=0
    (cd "$1" && shift && zig "$@") 2>"$err" || rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -f "$err"
    else
        cat "$err" >&2
        rm -f "$err"
        exit "$rc"
    fi
}

echo "Running unit tests (bxp-core)..."
run_zig_quiet "$MONO_ROOT/bxp-core" build test
echo ""

echo "Building bxp-cli..."
run_zig_quiet "$MONO_ROOT/bxp-cli" build
echo ""

echo "Building bxp-fmt..."
run_zig_quiet "$MONO_ROOT/bxp-fmt" build
echo ""

echo "Running unit tests (bxp-fmt)..."
run_zig_quiet "$MONO_ROOT/bxp-fmt" build test
echo ""

echo "Smoke-testing bxp-fmt..."
BXP_FMT="$MONO_ROOT/bxp-fmt/zig-out/bin/bxp-fmt"
for sample_json in "$DATASETS"/*/sample.json; do
    # --config must succeed and emit valid JSON (annotated output contract).
    if ! "$BXP_FMT" --config "$sample_json" 2>/dev/null | python3 -m json.tool > /dev/null; then
        echo "FAIL: bxp-fmt --config did not produce valid JSON for $sample_json"
        exit 1
    fi
done
# --expr accepts valid syntax and rejects broken syntax.
"$BXP_FMT" --expr "IF([Qty] > 0, 'BUY', 'SELL')" > /dev/null
if "$BXP_FMT" --expr "IF([Qty" 2>/dev/null; then
    echo "FAIL: bxp-fmt --expr did not reject broken expression"
    exit 1
fi
echo "bxp-fmt OK"
echo ""

# Dart JSON5 AST library — covers tokenizer, parser, dumper, mutations,
# path navigation, value builder, and round-trip canonicalisation.
JSON5_AST="$MONO_ROOT/bxp-gui/packages/json5_ast"
if [[ -d "$JSON5_AST" ]] && command -v dart > /dev/null; then
    echo "Running unit tests (json5_ast)..."
    (cd "$JSON5_AST" && dart test) > /dev/null
    echo "json5_ast OK"
    echo ""
fi

PASS=0
FAIL=0
FAILED=()

for sample_json in "$DATASETS"/*/sample.json; do
    template=$(basename "$(dirname "$sample_json")")
    printf "  %-48s " "[$template]"

    # Datasets must run clean — exit 0, no warnings. Anything else is a
    # fixture-quality problem (filter on without an ISO range in the
    # filename, malformed range, LOOKUP without pre_pass, …) and the
    # fixture should be fixed rather than the test loop tolerating it.
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
