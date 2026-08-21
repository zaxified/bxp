#!/usr/bin/env bash
# Docs example-page gate: the clickable expressions must actually work.
#
# Example pages mark expressions runnable in the browser scratchpad
# (docs/assets/javascripts/playground.js). A mark that errors, or that answers
# empty on every row, is worse than plain prose — it invites a reader to click
# and then shows them something broken. This asserts that cannot ship.
#
# Three checks, all driven off the pages themselves:
#
#   1. delimiter    a page whose sample.json declares a non-comma
#                   `csv_delimiter_in` must repeat it as `data-delim` on the
#                   marked sample fence, or every `[Column]` silently reads "".
#   2. maps         no marked expression may use the NAMED form of REMAP /
#                   REPLACE. The panel has no `maps` registry, so the named form
#                   returns its input unchanged — which looks like a successful
#                   remap. A wrong answer that looks right is the one failure
#                   mode worth a gate of its own.
#   3. expressions  every marked expression, evaluated against its own page's
#                   sample rows, must error on none and produce a real value on
#                   at least one. Blank on the first row alone is fine — that is
#                   exactly what the panel's "show all" is there to reveal.
#
# The evaluator is bxp-mcp's `bxp_eval_batch` (JSON-RPC over stdio), same as
# test-06 — so this phase needs no JavaScript runtime. What it does NOT cover is
# the browser glue; the wasm/native agreement has its own gate,
# scripts/docs/check-wasm-parity.sh, which needs node and runs in the docs workflow.
#
# Exit code = number of failures (0 = green).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

BXP_MCP="$MONO_ROOT/bxp-mcp/zig-out/bin/bxp-mcp"

# Built on demand for standalone runs; under scripts/test.sh the MCP phase
# (test-02) already built it earlier in numeric order, so this is a no-op there.
if [[ ! -x "$BXP_MCP" ]]; then
    (cd "$MONO_ROOT/bxp-mcp" && zig build -Doptimize=ReleaseSafe -Dcpu=baseline) || {
        echo "ERROR: bxp-mcp build failed. Run: cd bxp-mcp && zig build" >&2
        exit 2
    }
fi

section "Docs examples"

t0=$(_now)
out=$(mktemp)
rc=0
MONO_ROOT="$MONO_ROOT" BXP_MCP="$BXP_MCP" python3 "$SCRIPT_DIR/test-08-docs-examples.py" >"$out" 2>&1 || rc=$?
t1=$(_now)
dur=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')

if [[ $rc -eq 0 ]]; then
    # The checker's last line is "stats<TAB>exprs<TAB>pages"; the counts belong
    # in the label, the way test-06 carries its corpus count, so the phase emits
    # one result row like every other suite.
    IFS=$'\t' read -r _ exprs pages < <(grep '^stats	' "$out")
    rm -f "$out"
    status_line "docs examples (${exprs} expr, ${pages} pages)" OK "$dur"
else
    cat "$out" >&2
    rm -f "$out"
    status_line "docs examples" FAIL "$dur" >&2
fi
exit $rc
