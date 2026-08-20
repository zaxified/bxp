#!/usr/bin/env python3
"""Compare the wasm and native expression evaluators over the shared corpus.

Driven by scripts/docs/check-wasm-parity.sh, which guarantees the two runners exist
and picks the JavaScript runtime. See that script's header for why this gate
exists and why it is not a test-NN phase.

Both runners are handed the same headers/fields/exprs batch request, so any
difference is a difference in the engine, not in the harness:

  native — bxp-mcp's `bxp_eval_batch` tool over JSON-RPC on stdio, exactly the
           surface an agent drives
  wasm   — docs/assets/wasm/bxp-eval.wasm through a throwaway JS driver, exactly
           the surface docs/assets/javascripts/playground.js drives

NOW() and RAND() are nondeterministic by construction; they are compared on the
`ok` flag only, never on the value.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
# The corpus is a TEST fixture, so it stays with the test phases in scripts/;
# only the docs-support tooling lives down here in scripts/docs/.
CORPUS = os.path.join(ROOT, "scripts", "test-06-expr-corpus.txt")
MCP = os.path.join(ROOT, "bxp-mcp", "zig-out", "bin", "bxp-mcp")
WASM = os.path.join(ROOT, "docs", "assets", "wasm", "bxp-eval.wasm")
JS = os.environ.get("BXP_JS", "node")

# One fixed row covering the header names the corpus references. Values are
# deliberately varied in shape (numbers, dates, blanks, accented text, grouped
# numbers) so the comparison exercises coercion paths, not just passthrough.
HEADERS = ["A", "B", "C", "D", "E", "Action", "Amount", "Available", "Column Name",
           "Comment", "Currency", "Currency conversion fee",
           "Currency (Currency conversion fee)", "Currency (Total)", "Date",
           "Description", "Fee", "Fees", "ID", "ISIN", "Key", "No. of shares",
           "Note", "Item", "Price", "Ticker", "Time", "Total", "Type",
           "Quantity", "Price / share", "Exchange rate", "Result", "Name",
           "Symbol", "Value", "x", "y", "z"]
FIELDS = ["10", "3", "abc", "2026-08-19", "", "Market buy", "1,234.56", "7",
          "hdr", "note text", "USD", "0.15", "EUR", "USD", "2026-08-19",
          "Ceramic mug", "1.50", "2.00", "ID-42", "US0378331005", "k1", "12.5",
          "a note", "Ceramic mug", "$12.99", "AAPL", "12:34:56", "1234.00",
          "BUY", "3", "170.25", "23.5", "ok", "Příliš žluťoučký", "AAPL", "42",
          "Příliš žluťoučký kůň", "-5", "0"]
assert len(HEADERS) == len(FIELDS), (len(HEADERS), len(FIELDS))

NONDET = ("NOW(", "RAND(")

DRIVER = r"""
// Throwaway driver: request JSON in, response JSON out, same call sequence the
// docs playground makes.
const fs = require('fs');
const crypto = require('crypto');
const bytes = fs.readFileSync(process.argv[2]);
let mem;
WebAssembly.instantiate(bytes, {
  env: {
    js_now_ms: () => Date.now(),
    js_random_bytes: (ptr, len) =>
      crypto.webcrypto.getRandomValues(new Uint8Array(mem.buffer, ptr, len)),
  },
}).then(({ instance }) => {
  const ex = instance.exports;
  mem = ex.memory;
  const body = new TextEncoder().encode(fs.readFileSync(process.argv[3], 'utf8'));
  const p = ex.bxp_input_alloc(body.length);
  if (p === 0) { console.error('input alloc failed'); process.exit(1); }
  new Uint8Array(mem.buffer, p, body.length).set(body);
  const rc = ex.bxp_eval_batch(body.length);
  const out = new TextDecoder().decode(
    new Uint8Array(mem.buffer, ex.bxp_result_ptr(), ex.bxp_result_len()));
  if (rc !== 0) { console.error('bxp error: ' + out); process.exit(1); }
  process.stdout.write(out);
}).catch((e) => { console.error(String(e)); process.exit(1); });
"""


def load_corpus():
    out = []
    with open(CORPUS, encoding="utf-8") as fh:
        for line in fh:
            if not line.startswith("expr\t"):
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) >= 3 and cols[2].strip():
                out.append(cols[2])
    return out


def run_native(exprs):
    reqs = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"capabilities": {}}}),
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"})]
    chunks = [exprs[i:i + 25] for i in range(0, len(exprs), 25)]
    for n, ch in enumerate(chunks):
        reqs.append(json.dumps({
            "jsonrpc": "2.0", "id": 100 + n, "method": "tools/call",
            "params": {"name": "bxp_eval_batch",
                       "arguments": {"headers": HEADERS, "fields": FIELDS, "exprs": ch}}}))
    p = subprocess.run([MCP], input="\n".join(reqs) + "\n",
                       capture_output=True, text=True, timeout=300)
    by_id = {}
    for line in p.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(msg.get("id"), int) and msg["id"] >= 100:
            by_id[msg["id"]] = msg
    results = []
    for n in range(len(chunks)):
        msg = by_id.get(100 + n)
        if msg is None:
            sys.exit(f"native runner: no response for chunk {n}\n{p.stderr[:2000]}")
        results.extend(json.loads(msg["result"]["content"][0]["text"])["results"])
    return results


def run_wasm(exprs):
    with tempfile.TemporaryDirectory() as tmp:
        drv = os.path.join(tmp, "driver.cjs")
        req = os.path.join(tmp, "request.json")
        with open(drv, "w", encoding="utf-8") as fh:
            fh.write(DRIVER)
        with open(req, "w", encoding="utf-8") as fh:
            json.dump({"headers": HEADERS, "fields": FIELDS, "exprs": exprs}, fh)
        p = subprocess.run([JS, drv, WASM, req], capture_output=True, text=True, timeout=300)
        if p.returncode != 0:
            sys.exit(f"wasm runner failed:\n{p.stderr[:4000]}")
        return json.loads(p.stdout)["results"]


def main():
    exprs = load_corpus()
    if not exprs:
        sys.exit("corpus is empty — expected expr rows in test-06-expr-corpus.txt")
    native = run_native(exprs)
    wasm = run_wasm(exprs)
    if len(native) != len(exprs) or len(wasm) != len(exprs):
        sys.exit(f"length mismatch: native={len(native)} wasm={len(wasm)} exprs={len(exprs)}")

    mismatches, skipped = [], 0
    for e, n, w in zip(exprs, native, wasm):
        if any(t in e for t in NONDET):
            skipped += 1
            if n.get("ok") != w.get("ok"):
                mismatches.append((e, n, w))
            continue
        if n != w:
            mismatches.append((e, n, w))

    total = len(exprs)
    print(f"    corpus expressions ............ {total}")
    print(f"    byte-identical ................ {total - skipped - len(mismatches)}")
    print(f"    nondeterministic (ok-flag) .... {skipped}")
    if mismatches:
        print(f"\n  MISMATCHES: {len(mismatches)}")
        for e, n, w in mismatches[:40]:
            print(f"    expr:   {e}")
            print(f"      native: {json.dumps(n, ensure_ascii=False)}")
            print(f"      wasm:   {json.dumps(w, ensure_ascii=False)}")
        sys.exit(1)
    print("    wasm and native agree on every case.")


if __name__ == "__main__":
    main()
