#!/usr/bin/env bash
# bxp-mcp build + unit tests + JSON-RPC smoke. Drives the MCP server over
# stdio: initialize / tools/list / one tool from each family (bxp_eval,
# bxp_eval_batch, bxp_validate, bxp_list_templates) and a full bxp_simulate
# run against a dataset config. The simulate step also verifies the spawn of
# the co-located bxp-cli — the shipped console/desktop bundle layout. Phase
# isolated so a broken server or simulate surfaces here, not in the desktop
# suite (which never touches bxp-mcp).
#
# Usage (from any directory):
#   bash scripts/test-05-mcp.sh    — this phase alone
#   bash scripts/test.sh           — wrapper runs every phase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-lib.sh"

SAMPLE_DIR="$MONO_ROOT/datasets/trading212_to_wealthfolio"

_zig_in() {
    local dir="$1"; shift
    (cd "$dir" && zig "$@")
}

_smoke_bxp_mcp() {
    # bxp_simulate spawns the co-located bxp-cli, so replicate the shipped
    # bundle layout (bxp-mcp + bxp-cli side by side) in a temp dir. The other
    # tools are in-process and don't need it, but one staging covers them all.
    [ -x "$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli" ] || _zig_in "$MONO_ROOT/bxp-cli" build

    local stage reqs resp
    stage=$(mktemp -d)
    reqs=$(mktemp)
    resp=$(mktemp)
    cp "$MONO_ROOT/bxp-mcp/zig-out/bin/bxp-mcp" "$stage/bxp-mcp"
    cp "$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli" "$stage/bxp-cli"

    # Build the request stream (one JSON object per line). python3 handles the
    # JSON-string encoding of the config + CSV the simulate request embeds.
    SAMPLE_DIR="$SAMPLE_DIR" python3 - >"$reqs" <<'PY'
import json, os
d = os.environ["SAMPLE_DIR"]
cfg = open(os.path.join(d, "sample.json")).read()
csv = open(os.path.join(d, "sample.csv")).read()
def call(i, name, args):
    print(json.dumps({"jsonrpc":"2.0","id":i,"method":"tools/call",
                      "params":{"name":name,"arguments":args}}))
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}))
print(json.dumps({"jsonrpc":"2.0","method":"notifications/initialized"}))  # no response
print(json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/list"}))
call(3, "bxp_eval",          {"expr":"1 + 2"})
call(4, "bxp_eval_batch",    {"headers":["P"],"fields":["7"],"exprs":["[P]","BADFN()"]})
call(5, "bxp_validate",      {"config": cfg})
call(6, "bxp_list_templates",{"config": cfg})
call(7, "bxp_simulate",      {"config": cfg, "template":"trading212_to_wealthfolio", "csv": csv})
call(8, "bxp_eval_trace",    {"expr":"ABS(-2)"})
PY

    "$stage/bxp-mcp" <"$reqs" >"$resp" || {
        echo "FAIL: bxp-mcp exited non-zero"; cat "$resp"
        rm -rf "$stage"; rm -f "$reqs" "$resp"; return 1
    }

    local rc=0
    EXPECTED_CSVX="$SAMPLE_DIR/sample.expected" python3 - "$resp" <<'PY' || rc=1
import json, os, sys
by_id = {}
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if ln:
        o = json.loads(ln)
        by_id[o.get("id")] = o

# notification produced no response line
assert None not in by_id, "notification unexpectedly got a response"

def tool_json(i):
    return json.loads(by_id[i]["result"]["content"][0]["text"])

assert by_id[1]["result"]["protocolVersion"] == "2025-06-18", by_id[1]

names = {t["name"] for t in by_id[2]["result"]["tools"]}
assert names == {"bxp_validate","bxp_eval","bxp_eval_batch","bxp_eval_trace",
                 "bxp_docs","bxp_list_templates","bxp_fetch_template",
                 "bxp_simulate"}, names

assert tool_json(3) == {"ok": True, "value": "3"}, tool_json(3)

r = tool_json(4)["results"]
assert r[0] == {"ok": True, "value": "7"}, r       # field access
assert r[1]["ok"] is False, r                       # per-expr failure flagged

assert isinstance(tool_json(5), dict), "validate did not return a JSON object"

tmpls = {t["id"] for t in tool_json(6)["templates"]}
assert "trading212_to_wealthfolio" in tmpls, tmpls

sim = tool_json(7)
assert sim["ok"] is True and sim["status"] == "ok", sim
got = sim["outputs"][0]["csv"]
want = open(os.environ["EXPECTED_CSVX"]).read()
assert got == want, "bxp_simulate output != dataset .expected"

# bxp_eval_trace — NDJSON: a per-call line for ABS, then the final sentinel
trace = by_id[8]["result"]["content"][0]["text"].strip().splitlines()
events = [json.loads(ln) for ln in trace if ln]
assert any(e.get("fn") == "ABS" for e in events), events
assert events[-1] == {"t": "final", "value": "2"}, events[-1]
PY

    rm -rf "$stage"; rm -f "$reqs" "$resp"
    return $rc
}

section "MCP"
step "$(_lab bxp-mcp 'build')"       _zig_in "$MONO_ROOT/bxp-mcp" build
step "$(_lab bxp-mcp 'unit tests')"  _zig_in "$MONO_ROOT/bxp-mcp" build test
step "$(_lab bxp-mcp 'smoke')"       _smoke_bxp_mcp
