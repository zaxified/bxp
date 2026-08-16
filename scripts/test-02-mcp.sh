#!/usr/bin/env bash
# bxp-mcp build + unit tests + JSON-RPC smoke. Drives the MCP server over
# stdio: initialize / tools/list / one tool from each family (bxp_eval,
# bxp_eval_batch, bxp_validate, bxp_list_templates) and a full bxp_simulate
# run against a dataset config. The simulate step also verifies the spawn of
# the co-located bxp-cli — the shipped console/desktop bundle layout. Phase
# isolated so a broken server or simulate surfaces here, not in the desktop
# suite (which never touches bxp-mcp).
#
# Division of responsibility since the transport became the external zig-libs
# `mcp` module: that module owns the JSON-RPC framing and has its own 89 tests
# upstream, so this script does NOT re-test the protocol for its own sake. What
# it guards is **bxp's surface driven through that module** — our nine tools,
# our catalog, our isError / structuredContent contract, our registration state
# — plus the wiring seams where a mistake here would not show up upstream: that
# our binary routes the error paths at all, and that a malformed line does not
# take the session down with it.
#
# Usage (from any directory):
#   bash scripts/test-02-mcp.sh    — this phase alone
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
    [ -x "$MONO_ROOT/bxp-cli/zig-out/bin/bxp-cli" ] || _zig_in "$MONO_ROOT/bxp-cli" build -Doptimize=ReleaseSafe -Dcpu=baseline

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
# Authoring-time validator: a literal SPLIT_PART index of 0 is a static lint
# finding (always yields ""), so validate flags it where eval would run it to "".
call(13, "bxp_validate_expr", {"expr":"SPLIT_PART('a/b', '/', 0)"})
call(14, "bxp_validate_expr", {"expr":"UPPER('hi')"})
call(4, "bxp_eval_batch",    {"headers":["P"],"fields":["7"],"exprs":["[P]","BADFN()"]})
call(5, "bxp_validate",      {"config": cfg})
call(6, "bxp_list_templates",{"config": cfg})
call(7, "bxp_simulate",      {"config": cfg, "template":"trading212_to_wealthfolio", "csv": csv})
call(8, "bxp_eval_trace",    {"expr":"ABS(-2)"})
# Version negotiation: client asking for an older supported revision gets it echoed back.
print(json.dumps({"jsonrpc":"2.0","id":9,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}))
# Progress: a request carrying a progressToken opts into notifications/progress.
print(json.dumps({"jsonrpc":"2.0","id":10,"method":"tools/call",
                  "params":{"name":"bxp_simulate","_meta":{"progressToken":"p10"},
                            "arguments":{"config":cfg,"template":"trading212_to_wealthfolio","csv":csv}}}))
# Tool failure (missing required arg) → isError:true, no structuredContent.
call(11, "bxp_eval", {})
# eval_trace on a function-free expr is a single sentinel line — still NDJSON by
# tool identity, so it must NOT expose structuredContent.
call(12, "bxp_eval_trace", {"expr":"1 + 2"})
# A request-only method without an id is a stray notification — no response.
print(json.dumps({"jsonrpc":"2.0","method":"tools/list"}))

# ── wiring seams (100-series) ───────────────────────────────────────────────
# Not a re-test of the mcp module's framing (89 tests upstream). These check
# the seams that are ours: that this binary routes each error path, that our
# catalog is the thing rejecting an unknown tool, that we registered no
# resources/prompts, and — the one that matters most on a long-lived stdio
# session — that garbage on the wire does not kill the server.
print("{ this is not json")                                       # -32700
print("[]")                                                       # -32600, batching unsupported
print("")                                                         # blank line: ignored entirely
print(json.dumps({"jsonrpc":"2.0","id":100}))                     # -32600 missing method
print(json.dumps({"jsonrpc":"2.0","id":101,"method":"no/such"}))  # -32601
print(json.dumps({"jsonrpc":"2.0","method":"no/such"}))           # same, id-less: silent
# tools/call argument validation, all -32602.
print(json.dumps({"jsonrpc":"2.0","id":102,"method":"tools/call"}))
print(json.dumps({"jsonrpc":"2.0","id":103,"method":"tools/call","params":[]}))
print(json.dumps({"jsonrpc":"2.0","id":104,"method":"tools/call","params":{}}))
# An unknown tool name is OUR catalog answering, not the transport.
call(105, "bxp_not_a_tool", {})
# `arguments` absent entirely (not just empty) must reach the handler's own
# missing-arg path, not fault before it.
print(json.dumps({"jsonrpc":"2.0","id":106,"method":"tools/call",
                  "params":{"name":"bxp_eval"}}))
# A non-string argument is "missing" to strArg — the handler must say so
# rather than coerce it.
call(107, "bxp_eval", {"expr": 5})
# We register no resources and no prompts; the module still serves both
# methods, so the empty catalogs are our registration state showing through.
print(json.dumps({"jsonrpc":"2.0","id":108,"method":"resources/list"}))
print(json.dumps({"jsonrpc":"2.0","id":109,"method":"prompts/list"}))
# An id the transport cannot echo verbatim is refused outright rather than
# served — one of the two quieter wire changes the mcp migration brought.
print(json.dumps({"jsonrpc":"2.0","id":{"a":1},"method":"ping"}))
# A response-shaped line (id + result, no method) is something a client should
# have received, not a request. It draws no output at all — the other one.
print(json.dumps({"jsonrpc":"2.0","id":111,"result":{}}))
# The session survived all of the above: a real tool call still answers.
call(110, "bxp_eval", {"expr":"UPPER('ok')"})
PY

    "$stage/bxp-mcp" <"$reqs" >"$resp" || {
        echo "FAIL: bxp-mcp exited non-zero"; cat "$resp"
        rm -f "$stage/bxp-mcp" "$stage/bxp-cli"; rmdir "$stage"; rm -f "$reqs" "$resp"; return 1
    }

    local rc=0
    EXPECTED_CSVX="$SAMPLE_DIR/sample.expected" python3 - "$resp" <<'PY' || rc=1
import json, os, sys
by_id = {}
progress_notes = []
null_id = []          # responses carrying id:null — see the count assert below
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if ln:
        o = json.loads(ln)
        if o.get("method") == "notifications/progress":
            progress_notes.append(o["params"])
            continue
        if o.get("id") is None:
            null_id.append(o)
            continue
        by_id[o["id"]] = o

# Exactly three id:null responses are legal — the two malformed lines and the
# non-scalar-id request, none of which has an id that can be echoed. The count
# is also what proves no notification was answered: a stray reply to
# `notifications/initialized` or an id-less `tools/list` would land here as a
# fourth.
assert len(null_id) == 3, [o.get("error") for o in null_id]
assert null_id[0]["error"]["code"] == -32700, null_id[0]   # not JSON
assert null_id[1]["error"]["code"] == -32600, null_id[1]   # batch array
assert null_id[2]["error"]["code"] == -32600, null_id[2]   # non-scalar id

def tool_json(i):
    return json.loads(by_id[i]["result"]["content"][0]["text"])

# No protocolVersion requested → server answers with its latest.
assert by_id[1]["result"]["protocolVersion"] == "2025-11-25", by_id[1]
# Negotiation: an older supported revision is echoed back verbatim.
assert by_id[9]["result"]["protocolVersion"] == "2025-06-18", by_id[9]

names = {t["name"] for t in by_id[2]["result"]["tools"]}
assert names == {"bxp_validate","bxp_validate_expr","bxp_eval","bxp_eval_batch",
                 "bxp_eval_trace","bxp_docs","bxp_list_templates",
                 "bxp_fetch_template","bxp_simulate"}, names

assert tool_json(3) == {"ok": True, "value": "3"}, tool_json(3)

# bxp_validate_expr — authoring verdict: the literal-0 SPLIT_PART is flagged
# (domain {ok:false}, isError stays false); a sound expression passes.
v = tool_json(13)
assert v["ok"] is False and v["error"] == "SplitPartBadIndex", v
assert by_id[13]["result"]["isError"] is False, by_id[13]
assert by_id[13]["result"]["structuredContent"]["ok"] is False, by_id[13]
assert tool_json(14) == {"ok": True}, tool_json(14)

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
# BXTB sidecar trace folded into the report (5b-i): per-row counts + samples.
tr = sim["trace"]
assert tr["available"] is True, tr
assert tr["source_rows"] > 0 and tr["written_rows"] > 0, tr
assert tr["output_rows"]["count"] == tr["written_rows"], tr
# Record counts exclude the header row, so they line up with the BXTB trace.
assert sim["input"]["records"] == tr["source_rows"], (sim["input"]["records"], tr["source_rows"])
assert sim["output_records"] == tr["written_rows"], (sim["output_records"], tr["written_rows"])
for key in ("filtered", "row_errors", "output_rows"):
    assert isinstance(tr[key]["count"], int) and isinstance(tr[key]["sample"], list), (key, tr)
# An object-returning tool also exposes structuredContent (5a); NDJSON does not.
assert by_id[7]["result"].get("structuredContent", {}).get("status") == "ok", by_id[7]["result"].keys()
assert "structuredContent" not in by_id[8]["result"], "NDJSON tool must stay text-only"

# Progress (5b-ii): the progressToken'd call streamed notifications/progress
# before its result, ending at progress == total; no-token calls stay silent.
p10 = [n for n in progress_notes if n["progressToken"] == "p10"]
assert len(p10) >= 1, progress_notes
assert p10[-1]["progress"] == p10[-1]["total"], p10[-1]
assert all(n["progressToken"] == "p10" for n in progress_notes), "only the p10 call should emit progress"
assert by_id[10]["result"]["structuredContent"]["status"] == "ok", by_id[10]

# bxp_eval_trace — NDJSON: a per-call line for ABS, then the final sentinel
trace = by_id[8]["result"]["content"][0]["text"].strip().splitlines()
events = [json.loads(ln) for ln in trace if ln]
assert any(e.get("fn") == "ABS" for e in events), events
assert events[-1] == {"t": "final", "value": "2"}, events[-1]

# A tool failure sets isError:true (so the agent notices) and carries no
# structuredContent; a domain {"ok":false} answer would keep isError:false.
assert by_id[11]["result"]["isError"] is True, by_id[11]
assert "structuredContent" not in by_id[11]["result"], by_id[11]
# eval_trace stays text-only even when the expression has no function calls
# (single sentinel line) — structuredContent is gated by tool identity, not shape.
assert by_id[12]["result"].get("isError") is False, by_id[12]
assert "structuredContent" not in by_id[12]["result"], "single-line eval_trace must stay text-only"

# ── wiring seams (100-series) ───────────────────────────────────────────────
def code(i):
    assert "error" in by_id[i], (i, by_id[i])
    return by_id[i]["error"]["code"]

assert code(100) == -32600, by_id[100]          # missing method
assert code(101) == -32601, by_id[101]          # unknown method
assert code(102) == -32602, by_id[102]          # tools/call, no params
assert code(103) == -32602, by_id[103]          # params not an object
assert code(104) == -32602, by_id[104]          # no tool name
# Unknown tool is -32602 (bad params on a valid method), NOT -32601: the method
# exists, the name in it does not. Our catalog is what decides.
assert code(105) == -32602, by_id[105]
# (The id-less `no/such` twin must stay silent — covered by the null_id count
# at the top, which is where a stray reply to any notification would surface.)

# `arguments` absent, and a non-string argument, both reach the handler and come
# back as its own tool failure — not a transport error, not a coerced value.
for i in (106, 107):
    assert "error" not in by_id[i], (i, by_id[i])
    assert by_id[i]["result"]["isError"] is True, by_id[i]
    assert by_id[i]["result"]["content"][0]["text"] == "error: missing 'expr'", by_id[i]

# bxp registers no resources and no prompts: the module serves both methods,
# the catalogs are empty because that is our registration state.
assert by_id[108]["result"]["resources"] == [], by_id[108]
assert by_id[109]["result"]["prompts"] == [], by_id[109]

# The non-scalar-id request is refused rather than served — its `-32600 Invalid
# request id` is the third null_id entry asserted at the top, since an object id
# is precisely what cannot be echoed back.
# A response-shaped line draws nothing at all: answering a response would itself
# be a protocol violation, so it is dropped the way a notification is.
assert 111 not in by_id, by_id.get(111)

# The session survived every malformed line above — a long-lived stdio server
# must not be killable by one bad request.
assert tool_json(110) == {"ok": True, "value": "OK"}, tool_json(110)
PY

    rm -f "$stage/bxp-mcp" "$stage/bxp-cli"; rmdir "$stage"; rm -f "$reqs" "$resp"
    return $rc
}

section "MCP"
step "$(_lab bxp-mcp 'build')"       _zig_in "$MONO_ROOT/bxp-mcp" build      -Doptimize=ReleaseSafe -Dcpu=baseline
step "$(_lab bxp-mcp 'unit tests')"  _zig_in "$MONO_ROOT/bxp-mcp" build test -Doptimize=ReleaseSafe -Dcpu=baseline
step "$(_lab bxp-mcp 'smoke')"       _smoke_bxp_mcp
