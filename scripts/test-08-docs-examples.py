#!/usr/bin/env python3
"""Checker behind scripts/test-08-docs-examples.sh — see that script's header.

Everything here is derived from the pages and their example directories; there
is no list of expressions to keep in sync. Adding a `{.bxp-try}` mark anywhere
brings it under the gate automatically.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.environ.get("MONO_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MCP = os.environ["BXP_MCP"]
DOCS = os.path.join(ROOT, "docs")
EXAMPLES = os.path.join(DOCS, "examples")

# Inline `expr`{.bxp-try} spans, and the fenced display-block form.
INLINE_RE = re.compile(r"`([^`\n]+(?:\n[^`\n]*)?)`\{\.bxp-try\}")
FENCE_RE = re.compile(r"^```\{[^}]*\.bxp-try[^}]*\}\s*\n(.*?)^```", re.M | re.S)
SAMPLE_RE = re.compile(r'```\{\.csv \.bxp-sample([^}]*)\}\s*\n\s*--8<--\s+"([^"]+)"')
SCRIPT_SAMPLE_RE = re.compile(
    r'<script[^>]*class="bxp-sample"([^>]*)>\s*--8<--\s+"([^"]+)"', re.S)
DELIM_ATTR_RE = re.compile(r'data-delim="([^"]*)"')

# Named-map form: exactly two arguments, the second a string literal. The first
# argument may itself contain calls, so match a balanced-ish prefix rather than
# a naive `[^,]*`.
NAMED_MAP_RE = re.compile(
    r"\b(REMAP|REPLACE)\s*\(\s*(?:[^,()']|'[^']*'|\([^()]*\))*,\s*'[^']*'\s*\)",
    re.I)


def strip_json5(src):
    """JSON5 -> JSON, enough for the hand-written example configs. Callers
    validate with json.loads, so anything this cannot handle is reported, never
    silently mangled."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'":
            q, j, buf = c, i + 1, ['"']
            while j < n and src[j] != q:
                if src[j] == "\\":
                    buf.append(src[j:j + 2]); j += 2; continue
                buf.append('\\"' if src[j] == '"' else src[j]); j += 1
            buf.append('"'); out.append("".join(buf)); i = j + 1; continue
        if src.startswith("//", i):
            i = src.find("\n", i)
            if i < 0:
                break
            continue
        if src.startswith("/*", i):
            i = src.find("*/", i) + 2; continue
        out.append(c); i += 1
    text = "".join(out)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    text = re.sub(r"([{,]\s*)([A-Za-z_$][\w$]*)(\s*:)", r'\1"\2"\3', text)
    return text


def parse_csv(text, delim):
    """Mirrors bxp's lazy-quotes rule: a '\\n' always ends a record."""
    records, field, record, in_q = [], "", [], False
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\r":
            i += 1; continue
        if c == "\n":
            record.append(field); records.append(record)
            field, record, in_q = "", [], False
            i += 1; continue
        if in_q:
            if c == '"':
                if i + 1 < len(text) and text[i + 1] == '"':
                    field += '"'; i += 2; continue
                in_q = False; i += 1; continue
            field += c; i += 1; continue
        if c == '"' and field == "":
            in_q = True; i += 1; continue
        if c == delim:
            record.append(field); field = ""; i += 1; continue
        field += c; i += 1
    if field != "" or record:
        record.append(field); records.append(record)
    return [r for r in records if len(r) > 1 or r[0] != ""]


def page_dirs():
    for tier in sorted(os.listdir(EXAMPLES)):
        td = os.path.join(EXAMPLES, tier)
        if not os.path.isdir(td):
            continue
        for name in sorted(os.listdir(td)):
            page = os.path.join(td, name, "index.md")
            if os.path.isfile(page):
                yield f"{tier}/{name}", page


def declared_delimiters(cfg_path):
    if not os.path.isfile(cfg_path):
        return set(), None
    try:
        doc = json.loads(strip_json5(open(cfg_path, encoding="utf-8").read()))
    except Exception as e:
        return set(), str(e)
    return {t.get("csv_delimiter_in") for t in (doc.get("conversion_templates") or {}).values()
            if t.get("csv_delimiter_in")}, None


def collect(rel, page):
    src = open(page, encoding="utf-8").read()
    exprs = [re.sub(r"\s*\n\s*", " ", m.group(1)).strip() for m in INLINE_RE.finditer(src)]
    exprs += [re.sub(r"\n\s*", " ", m.group(1)).strip() for m in FENCE_RE.finditer(src)]

    attrs = data = None
    m = SAMPLE_RE.search(src) or SCRIPT_SAMPLE_RE.search(src)
    if m:
        attrs = m.group(1)
        path = os.path.join(DOCS, m.group(2))
        if os.path.isfile(path):
            data = open(path, encoding="utf-8").read()
    delim = ","
    if attrs:
        d = DELIM_ATTR_RE.search(attrs)
        if d:
            delim = "\t" if d.group(1) == "\\t" else d.group(1)
    return exprs, data, delim, attrs is not None


def eval_batches(batches):
    """One bxp-mcp invocation for every (headers, fields, exprs) batch."""
    reqs = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"capabilities": {}}}),
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"})]
    for n, (h, f, e) in enumerate(batches):
        reqs.append(json.dumps({
            "jsonrpc": "2.0", "id": 100 + n, "method": "tools/call",
            "params": {"name": "bxp_eval_batch",
                       "arguments": {"headers": h, "fields": f, "exprs": e}}}))
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
    out = []
    for n in range(len(batches)):
        msg = by_id.get(100 + n)
        if msg is None:
            sys.exit(f"    no response for batch {n}\n{p.stderr[:2000]}")
        out.append(json.loads(msg["result"]["content"][0]["text"])["results"])
    return out


def main():
    failures = []
    marked_pages = 0
    total_exprs = 0
    batches, index = [], []

    for rel, page in page_dirs():
        exprs, data, delim, has_sample = collect(rel, page)
        cfg = os.path.join(os.path.dirname(page), "sample.json")

        # 1. delimiter declaration must match the config
        declared, err = declared_delimiters(cfg)
        if err:
            failures.append(f"{rel}: sample.json did not parse ({err})")
        elif has_sample and len(declared) == 1:
            want = declared.pop()
            if want != delim:
                failures.append(
                    f"{rel}: sample fence declares data-delim {delim!r} but "
                    f"sample.json declares csv_delimiter_in {want!r}")

        if not exprs:
            continue
        marked_pages += 1
        total_exprs += len(exprs)

        # 2. named-map form cannot be honestly evaluated without a maps registry
        for e in exprs:
            if NAMED_MAP_RE.search(e):
                failures.append(
                    f"{rel}: marked expression uses the named-map form, which "
                    f"passes its input through unchanged here — {e[:70]}")

        # 3. queue the expression against this page's own rows
        if data is None:
            batches.append(([], [], exprs))
            index.append((rel, exprs, 1))
            continue
        recs = parse_csv(data.rstrip("\n"), delim)
        if len(recs) < 2:
            failures.append(f"{rel}: sample has no data rows under delimiter {delim!r}")
            continue
        headers = [h.strip() for h in recs[0]]
        rows = recs[1:]
        for fields in rows:
            batches.append((headers, fields, exprs))
        index.append((rel, exprs, len(rows)))

    if batches:
        results = eval_batches(batches)
        at = 0
        for rel, exprs, nrows in index:
            per = [results[at + r] for r in range(nrows)]
            at += nrows
            for i, e in enumerate(exprs):
                errs = [row[i] for row in per if not row[i].get("ok")]
                if errs:
                    d = errs[0].get("detail") or errs[0].get("error")
                    failures.append(f"{rel}: {e[:60]} -> {d}")
                elif all(row[i].get("value", "") == "" for row in per):
                    failures.append(f"{rel}: {e[:60]} -> empty on every row")

    print(f"    pages with clickable expressions ... {marked_pages}")
    print(f"    expressions checked ............... {total_exprs}")
    if failures:
        print(f"\n  FAILURES: {len(failures)}")
        for f in failures:
            print(f"    {f}")
        sys.exit(len(failures))
    print("    every marked expression works against its own sample.")


if __name__ == "__main__":
    main()
