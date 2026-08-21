#!/usr/bin/env bash
# Expression corpus regression gate.
#
# Walks scripts/test-06-expr-corpus.txt line by line and validates each case
# through the bxp-mcp server's bxp_validate_expr tool (JSON-RPC 2.0 over stdio,
# one tools/call per case in a single server invocation), asserting:
#   expected=ok  → result .ok == true
#   expected=err → result .ok == false AND (reason empty OR .error == reason)
#
# bxp_validate_expr is the authoring-time validator (runtime eval + the static
# FnArgDoc lint that flags literal mistakes like SPLIT_PART(…, 0)) — the same
# bxp-core/inspect.validateExpr the GUI bridge's bridge_eval_expr calls. The
# corpus encodes that *validation* verdict (not the lenient runtime value), so
# bxp_eval would be the wrong runner here. The Dart side has a parallel
# cross-runner gate (bxp-gui/test/expr_corpus_bridge_test.dart) walking the same
# corpus through bridge_eval_expr — this gate adds the MCP transport.
#
# Output mirrors test-lib.sh step() format with an extra "(N/N passed)" footer.
# Exit code = number of failed cases (0 = green).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

BXP_MCP="$MONO_ROOT/bxp-mcp/zig-out/bin/bxp-mcp"
CORPUS="$SCRIPT_DIR/test-06-expr-corpus.txt"

# Build bxp-mcp on demand for standalone runs. Under scripts/test.sh the MCP
# phase (test-02) already built it earlier in numeric order, so this is a no-op
# there. ReleaseSafe to match the rest of the suite (single optimize mode).
if [[ ! -x "$BXP_MCP" ]]; then
    (cd "$MONO_ROOT/bxp-mcp" && zig build -Doptimize=ReleaseSafe -Dcpu=baseline) || {
        echo "ERROR: bxp-mcp build failed. Run: cd bxp-mcp && zig build" >&2
        exit 2
    }
fi
if [[ ! -f "$CORPUS" ]]; then
    echo "ERROR: corpus file not found: $CORPUS" >&2
    exit 2
fi

section "Expression corpus"

t0=$(_now)

reqs=$(mktemp)
resp=$(mktemp)

# Build the JSON-RPC request stream: initialize + one bxp_validate_expr tools/call
# per corpus case (id = 1-based case index). python3 handles JSON-string encoding
# of expressions that contain quotes/backslashes.
CORPUS="$CORPUS" python3 - >"$reqs" <<'PY'
import json, os
print(json.dumps({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"capabilities":{}}}))
print(json.dumps({"jsonrpc":"2.0","method":"notifications/initialized"}))  # no response
i = 0
for ln in open(os.environ["CORPUS"]):
    parts = ln.rstrip("\n").split("\t")
    if len(parts) < 3 or parts[0] != "expr":
        continue
    i += 1
    print(json.dumps({"jsonrpc":"2.0","id":i,"method":"tools/call",
                      "params":{"name":"bxp_validate_expr","arguments":{"expr":parts[2]}}}))
PY

if ! "$BXP_MCP" <"$reqs" >"$resp"; then
    echo "FAIL: bxp-mcp exited non-zero"
    cat "$resp"
    rm -f "$reqs" "$resp"
    exit 2
fi

# Parse responses by id and check each case. Emits a tab-separated summary line
# "passed<TAB>total<TAB>failed" followed by one "F<TAB><detail>" line per failure.
summary=$(CORPUS="$CORPUS" python3 - "$resp" <<'PY'
import json, os, sys
by_id = {}
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if not ln:
        continue
    o = json.loads(ln)
    if o.get("id") is not None:
        by_id[o["id"]] = o

passed = failed = total = 0
failures = []
i = 0
for ln in open(os.environ["CORPUS"]):
    parts = ln.rstrip("\n").split("\t")
    if len(parts) < 3 or parts[0] != "expr":
        continue
    i += 1
    total += 1
    expected = parts[1]
    expr_text = parts[2]
    reason = parts[3] if len(parts) > 3 else ""

    resp = by_id.get(i)
    if resp is None:
        failed += 1; failures.append(f"no-response: '{expr_text}'"); continue
    try:
        d = json.loads(resp["result"]["content"][0]["text"])
    except Exception as e:
        failed += 1; failures.append(f"bad-response: '{expr_text}' → {e}"); continue

    ok = d.get("ok")
    if expected == "ok":
        if ok is True:
            passed += 1
        else:
            failed += 1; failures.append(f"ok-expected: '{expr_text}' → {d}")
    elif expected == "err":
        if ok is not False:
            failed += 1; failures.append(f"err-expected: '{expr_text}' → ok={ok}")
        elif reason and d.get("error") != reason:
            failed += 1; failures.append(f"err-mismatch: '{expr_text}' → .error='{d.get('error')}' want '{reason}'")
        else:
            passed += 1
    else:
        failed += 1; failures.append(f"bad-kind: '{expected}' for '{expr_text}'")

print(f"{passed}\t{total}\t{failed}")
for f in failures:
    print("F\t" + f)
PY
)
parse_rc=$?

rm -f "$reqs" "$resp"

if [[ $parse_rc -ne 0 || -z "$summary" ]]; then
    echo "FAIL: corpus response parsing failed"
    exit 2
fi

# First line: passed/total/failed counts. Remaining "F<TAB>..." lines: failures.
head_line=$(printf '%s\n' "$summary" | head -1)
IFS=$'\t' read -r passed total failed <<<"$head_line"

t1=$(_now)
dur=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')

# The count goes in the label so the OK column lands at the same place as every
# other step and the whole line stays inside the 60-char visual width set by
# section().
label="corpus (${passed}/${total})"

if (( failed == 0 )); then
    status_line "$label" OK "$dur"
    exit 0
fi

status_line "$label" FAIL "$dur"
echo
echo "  Failures:"
printf '%s\n' "$summary" | while IFS=$'\t' read -r tag detail; do
    [[ "$tag" == "F" ]] && echo "    - $detail"
done
echo
exit "$failed"
