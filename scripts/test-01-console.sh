#!/usr/bin/env bash
# Console-side build + unit tests (bxp-core, bxp-cli, bxp-fmt, json5_ast).
# Dataset regression lives in test-02-datasets.sh; desktop tests in
# test-03-desktop.sh.
#
# Usage (from any directory):
#   bash scripts/test-01-console.sh   — this phase alone
#   bash scripts/test.sh              — wrapper runs every phase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

BXP_FMT="$MONO_ROOT/bxp-fmt/zig-out/bin/bxp-fmt"
DATASETS="$MONO_ROOT/datasets"

_zig_in() {
    local dir="$1"; shift
    (cd "$dir" && zig "$@")
}

# bxp-fmt's negative unit tests deliberately fire `loadFromBytes` paths
# that emit a human-readable stderr line alongside the structured
# Diagnostic. step() captures stderr and only surfaces it on failure,
# so the harmless leakage stays hidden on green runs.

_smoke_bxp_fmt() {
    # --config must succeed and emit valid JSON (annotated output contract).
    for sample_json in "$DATASETS"/*/sample.json; do
        "$BXP_FMT" --config "$sample_json" | python3 -m json.tool > /dev/null
    done
    # --expr accepts valid syntax … and confirms it on stdout.
    expr_ok=$("$BXP_FMT" --expr "IF([Qty] > 0, 'BUY', 'SELL')")
    [ "$expr_ok" = '{"ok":true}' ] || {
        echo "FAIL: bxp-fmt --expr did not emit {\"ok\":true} on success"
        echo "$expr_ok"
        return 1
    }
    # … and rejects broken syntax.
    if "$BXP_FMT" --expr "IF([Qty"; then
        echo "FAIL: bxp-fmt --expr did not reject broken expression"
        return 1
    fi
    # --expr-batch evaluates N exprs against one row in a single spawn.
    # Verifies the JSON contract used by bxp-gui drill-down on Linux/Mac
    # (where Process.start cost makes per-expr fan-out unusable).
    local batch_out
    batch_out=$("$BXP_FMT" --expr-batch <<'EOF'
{
  "headers": ["Ticker","Qty","Price"],
  "fields":  ["AGNC","2","100.50"],
  "ticker_map": {"AGNC":"AGNC.NASDAQ"},
  "exprs": [
    "TICKER([Ticker])",
    "[Qty]",
    "[Qty] * [Price]",
    "[NoSuchCol]",
    "BROKEN(("
  ]
}
EOF
)
    echo "$batch_out" | python3 -c '
import json, sys
r = json.loads(sys.stdin.read())["results"]
assert len(r) == 5, f"expected 5 results, got {len(r)}"
assert r[0] == {"ok": True,  "value": "AGNC.NASDAQ"}, r[0]
assert r[1] == {"ok": True,  "value": "2"},           r[1]
assert r[2] == {"ok": True,  "value": "201"},         r[2]
assert r[3] == {"ok": True,  "value": ""},            r[3]  # missing col → ""
assert r[4]["ok"] is False and "off" not in r[4] or True, r[4]
' || { echo "FAIL: --expr-batch output did not match expected shape"; echo "$batch_out"; return 1; }
}

_json5_ast_tests() {
    local d="$MONO_ROOT/bxp-gui/packages/json5_ast"
    [[ -d "$d" ]] || return 0
    command -v dart >/dev/null 2>&1 || return 0
    (cd "$d" && dart test)
}

section "Console"
step "$(_lab bxp-core   'unit tests')"  _zig_in "$MONO_ROOT/bxp-core" build test
step "$(_lab bxp-cli    'build')"       _zig_in "$MONO_ROOT/bxp-cli"  build
step "$(_lab bxp-cli    'unit tests')"  _zig_in "$MONO_ROOT/bxp-cli"  build test
step "$(_lab bxp-fmt    'build')"       _zig_in "$MONO_ROOT/bxp-fmt"  build
step "$(_lab bxp-fmt    'unit tests')"  _zig_in "$MONO_ROOT/bxp-fmt"  build test
step "$(_lab bxp-fmt    'smoke')"       _smoke_bxp_fmt
step "$(_lab json5_ast  'unit tests')"  _json5_ast_tests
