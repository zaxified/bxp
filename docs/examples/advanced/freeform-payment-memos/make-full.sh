#!/usr/bin/env bash
# Build the 1,000,000-row memo file the "Cost — regex vs. the cheaper tools"
# section of index.md is measured on, then run both templates over it.
#
# The real-world examples pull their scale input with a `fetch-full.sh`; this is
# a teaching example, so its scale input is *generated* — same role, same
# ./full/ layout, hence the different verb in the name.
#
#   bash make-full.sh                 # writes ./full/memos.csv (~62 MB)
#   bxp-cli --config full.json        # the regex template
#   bxp-cli --config full-cheap.json  # the literal-only template
#
# The two outputs are byte-identical by construction — that is the point of the
# comparison: same answer, two prices. Diff them to confirm before believing
# any timing:
#
#   diff full/memos.csvx full/memos-cheap.csvx && echo identical
#
# Re-running is cheap: an already-generated full/memos.csv is reused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_DIR="$SCRIPT_DIR/full"
CSV="$FULL_DIR/memos.csv"
ROWS="${ROWS:-1000000}"

mkdir -p "$FULL_DIR"

if [ -f "$CSV" ]; then
    echo "already generated: $CSV ($(du -h "$CSV" | cut -f1))"
    exit 0
fi

echo "generating $ROWS memo rows …"
# Six memo shapes cycled deterministically: with an invoice, with an order ref,
# with both, and three with neither — so the regex hits and misses in roughly
# the proportion the six-row teaching slice shows. Deterministic (no RNG) so
# two machines measure the same file.
python3 - "$CSV" "$ROWS" <<'PY'
import sys
path, rows = sys.argv[1], int(sys.argv[2])
shapes = [
    ("Payment for INV-{y}-{n:04d} thank you",              "priority|cleared|eu"),
    ("SEPA credit ref order #{o} from ACME",               "normal|cleared|eu"),
    ("Card settlement no reference here",                  "normal|pending|us"),
    ("Monthly wire transfer to supplier",                  "priority|pending|eu"),
    ("Refund INV-{y}-{n:04d} order #{o} processed",        "low|cleared|us"),
    ("Misc cash adjustment",                               "low|cleared|eu"),
]
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write("TxnId,Memo,Tags\n")
    for i in range(rows):
        tpl, tags = shapes[i % len(shapes)]
        memo = tpl.format(y=2020 + (i % 5), n=i % 10000, o=10000 + (i % 90000))
        f.write(f"T{i:09d},{memo},{tags}\n")
PY

echo "ready: $CSV ($(du -h "$CSV" | cut -f1), $(($(wc -l < "$CSV") - 1)) rows)"
