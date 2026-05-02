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

echo "Building bxp-fmt..."
(cd "$MONO_ROOT/bxp-fmt" && zig build)
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

# ── Annotated JSON regression + CST round-trip identity ─────────────────
# Verifies bxp-fmt --config annotated output (comments + errors preserved)
# AND that bxp-gui's CstSave.emit produces a byte-identical file when no
# edits are applied. release.sh depends on test.sh, so any drift here
# blocks a release.
ANNOT_DIR="$DATASETS/_annotated_fixtures"
if [[ -d "$ANNOT_DIR" ]]; then
    echo "Annotated JSON regression..."
    EXPECTED="$ANNOT_DIR/sample.expected.json"
    if [[ ! -f "$EXPECTED" ]]; then
        echo "FAIL: missing $EXPECTED"
        exit 1
    fi
    # bxp-fmt exits 1 when the config carries $err_ markers — for our
    # fixture that is expected (no conversion_templates defined). Capture
    # exit code separately so `set -e` doesn't abort the run.
    RAW_ANNOT=$("$BXP_FMT" --config "$ANNOT_DIR/sample.json5" 2>/dev/null || true)
    # Strip $span_* / $spans_* keys (volatile byte offsets) before diffing.
    NORM_ACTUAL=$(echo "$RAW_ANNOT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
META_PREFIXES = ("$meta_", "$elem_meta_")
def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if not any(k.startswith(p) for p in META_PREFIXES)}
    if isinstance(o, list):
        return [strip(x) for x in o]
    return o
print(json.dumps(strip(d), indent=2))
')
    if ! diff <(echo "$NORM_ACTUAL") "$EXPECTED" > /dev/null; then
        echo "FAIL: bxp-fmt annotated output drift"
        diff <(echo "$NORM_ACTUAL") "$EXPECTED" | head -40
        exit 1
    fi
    echo "Annotated JSON OK"

    # AST round-trip identity: parse → dump → parse must recover the same
    # tree (modulo first-save canonicalisation). Phase 5e moved this from
    # the old CST byte-patcher (deleted) to the standalone AST library
    # smoke runner.
    if command -v dart > /dev/null; then
        echo "AST round-trip identity..."
        if ! (cd "$MONO_ROOT/bxp-gui/tool/json_ast_proto" && \
              dart run bin/round_trip.dart) > /dev/null 2>&1; then
            echo "FAIL: AST round-trip failed"
            (cd "$MONO_ROOT/bxp-gui/tool/json_ast_proto" && \
              dart run bin/round_trip.dart) | head -20
            exit 1
        fi
        echo "AST round-trip OK"
    else
        echo "AST round-trip skipped (dart not on PATH)"
    fi
    echo ""
fi

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
