#!/usr/bin/env python3
# Synthetic .xlsx generator for profiling bxp-core/src/xlsx.zig ingest.
#
# Produces a single-sheet workbook with a controllable shape so we can
# separate the two memory hotspots the v0.4.0 roadmap suspects:
#   - sharedStrings.xml  (random-index-access table, sized by --vocab)
#   - worksheets/sheet1.xml  (sequential row stream, sized by --rows)
#
# Header is row 1; columns: Date, Symbol, Type, Volume, Sale value.
# Date/Symbol/Type are shared strings (reference the sharedStrings table);
# Volume/Sale value are inline numbers. A small string vocabulary referenced
# across many rows mirrors a real broker export (limited symbols, many trades).
#
# Usage: gen-xlsx.py OUT.xlsx --rows N [--vocab V] [--symbols S]
#
# Streams every part to disk (no giant in-Python string) so we can emit
# multi-GB workbooks without the generator itself OOMing.

import argparse
import datetime
import struct
import sys
import zipfile

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
HEADER = ["Date", "Symbol", "Type", "Volume", "Sale value"]


def build_vocabulary(vocab, symbols):
    # Index 0..len(HEADER)-1  -> header labels (referenced by the header row).
    # Then a pool of date strings + a symbol pool + the two Type literals.
    # `vocab` is the *total* unique string count target; we pad with synthetic
    # date strings to reach it (dates dominate sharedStrings in real exports).
    strings = list(HEADER)
    types = ["BUY", "SELL"]
    sym_pool = [f"SYM{i:05d}.US" for i in range(symbols)]
    strings += types
    strings += sym_pool
    # Pad with distinct ISO date strings up to the vocab target.
    base = datetime.date(2000, 1, 1)
    i = 0
    while len(strings) < vocab:
        d = base + datetime.timedelta(days=i)
        strings.append(d.isoformat() + "T09:30:00")
        i += 1
    # Index maps.
    idx = {s: n for n, s in enumerate(strings)}
    type_idx = [idx[t] for t in types]
    sym_idx = [idx[s] for s in sym_pool]
    date_idx = [n for n, s in enumerate(strings) if s.endswith("T09:30:00")]
    if not date_idx:  # vocab too small to hold any padding dates
        date_idx = [idx[HEADER[0]]]
    return strings, type_idx, sym_idx, date_idx


def gen_shared_strings(path, strings):
    with open(path, "wb") as f:
        w = f.write
        w(b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
        w(f'<sst xmlns="{NS}" count="{len(strings)}" uniqueCount="{len(strings)}">'.encode())
        for s in strings:
            w(b"<si><t>")
            w(s.encode("utf-8"))
            w(b"</t></si>")
        w(b"</sst>")


def gen_sheet(path, rows, type_idx, sym_idx, date_idx):
    # Column letters for our 5 columns: A..E.
    def s_cell(col, row, sidx):
        return f'<c r="{col}{row}" t="s"><v>{sidx}</v></c>'

    def n_cell(col, row, num):
        return f'<c r="{col}{row}"><v>{num}</v></c>'

    nv, ns, nd = len(type_idx), len(sym_idx), len(date_idx)
    with open(path, "wb") as f:
        w = f.write
        w(b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
        w(f'<worksheet xmlns="{NS}"><sheetData>'.encode())
        # Header row (row 1): all five labels as shared strings (indices 0..4).
        hdr = "".join(s_cell(c, 1, i) for i, c in enumerate("ABCDE"))
        w(f'<row r="1">{hdr}</row>'.encode())
        for r in range(2, rows + 2):
            k = r - 2
            di = date_idx[k % nd]
            si = sym_idx[k % ns]
            ti = type_idx[k % nv]
            vol = 1 + (k % 1000)
            sale = round(10.0 + (k % 100000) * 0.07, 2)
            cells = (
                s_cell("A", r, di)
                + s_cell("B", r, si)
                + s_cell("C", r, ti)
                + n_cell("D", r, vol)
                + n_cell("E", r, sale)
            )
            w(f'<row r="{r}">{cells}</row>'.encode())
        w(b"</sheetData></worksheet>")


ROOT_RELS = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    "</Relationships>"
)


def sheet_name(k, n):
    # One sheet keeps the historical name "DATA" (xlsx-bench.json references it);
    # multi-sheet workbooks get "DATA1".."DATAN" for the fan-out config.
    return "DATA" if n == 1 else f"DATA{k}"


def content_types(n):
    parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
        '<Default Extension="xml" ContentType="application/xml"/>',
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>',
    ]
    for k in range(1, n + 1):
        parts.append(
            f'<Override PartName="/xl/worksheets/sheet{k}.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        )
    parts.append("</Types>")
    return "".join(parts)


def workbook(n):
    sheets = "".join(
        f'<sheet name="{sheet_name(k, n)}" sheetId="{k}" r:id="rId{k}"/>'
        for k in range(1, n + 1)
    )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        f'<workbook xmlns="{NS}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        f"<sheets>{sheets}</sheets></workbook>"
    )


def workbook_rels(n):
    # Worksheets rId1..rIdN, then sharedStrings rId{N+1}.
    parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    ]
    for k in range(1, n + 1):
        parts.append(
            f'<Relationship Id="rId{k}" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
            f'Target="worksheets/sheet{k}.xml"/>'
        )
    parts.append(
        f'<Relationship Id="rId{n + 1}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" '
        'Target="sharedStrings.xml"/>'
    )
    parts.append("</Relationships>")
    return "".join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--rows", type=int, default=100_000)
    ap.add_argument("--sheets", type=int, default=1,
                    help="number of worksheets, all sharing one sharedStrings table")
    ap.add_argument("--vocab", type=int, default=5000)
    ap.add_argument("--symbols", type=int, default=200)
    ap.add_argument("--tmp", default="/tmp/xlsx-bench-parts")
    args = ap.parse_args()
    n = args.sheets

    import os

    os.makedirs(args.tmp, exist_ok=True)
    ss_path = os.path.join(args.tmp, "sharedStrings.xml")

    strings, type_idx, sym_idx, date_idx = build_vocabulary(args.vocab, args.symbols)
    gen_shared_strings(ss_path, strings)
    ss_sz = os.path.getsize(ss_path)

    # All sheets are identical in shape; the shared-strings table is parsed once
    # and the per-sheet worksheet stream is what the fan-out parallelises.
    sheet_paths = []
    for k in range(1, n + 1):
        sp = os.path.join(args.tmp, f"sheet{k}.xml")
        gen_sheet(sp, args.rows, type_idx, sym_idx, date_idx)
        sheet_paths.append(sp)
    sheet_sz = os.path.getsize(sheet_paths[0])

    with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.writestr("[Content_Types].xml", content_types(n))
        z.writestr("_rels/.rels", ROOT_RELS)
        z.writestr("xl/workbook.xml", workbook(n))
        z.writestr("xl/_rels/workbook.xml.rels", workbook_rels(n))
        z.write(ss_path, "xl/sharedStrings.xml")
        for k, sp in enumerate(sheet_paths, start=1):
            z.write(sp, f"xl/worksheets/sheet{k}.xml")

    out_sz = os.path.getsize(args.out)
    os.remove(ss_path)
    for sp in sheet_paths:
        os.remove(sp)
    print(
        f"{args.out}: sheets={n} rows/sheet={args.rows} vocab={len(strings)} "
        f"| sharedStrings={ss_sz/1e6:.1f}MB sheet={sheet_sz/1e6:.1f}MB "
        f"uncompressed_total={(ss_sz+sheet_sz*n)/1e6:.1f}MB "
        f"| zip_on_disk={out_sz/1e6:.1f}MB",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
