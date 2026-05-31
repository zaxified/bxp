# Accounting Negatives → Signed Decimals

[← all examples](../../README.md)

**What.** Normalise an accounting/bank/ERP export where negative amounts are
written in **parentheses** — `"(2,500.00)"` means `-2500` — and thousands are
comma-grouped, into a clean signed-decimal column.

**Synthetic / teaching example.** The data here is **constructed**, not sourced
— `sample.csv` is hand-written rows engineered to plant one of each amount
shape. The *failure mode* is real and documented; the rows are not. (Accounting
negatives ride in private bank/ledger exports, which have no public dataset —
so this lives in the teaching tier, not `examples/real-world/`.)

**Why interesting.** The parenthesis-for-negative convention is everywhere in
finance (it's the default "Accounting" number format in Excel), and it breaks
naive pipelines twice over: a spreadsheet re-import reads `"(2,500.00)"` as a
text label, and any `amount * 1` cast throws on both the parentheses and the
comma thousands separator. The sign silently vanishes or the row errors out.

**Failure mode documented in.** (sources for the problem class — not for the data)

- [Microsoft — Accounting number format](https://support.microsoft.com/en-us/office/format-numbers-in-cells-as-accounting-format)
  uses parentheses for negatives.
- Generic CSV-import guides repeatedly call out converting `($1,234.56)` →
  `-1234.56` before analysis.

**The trick** (see inline comments in `sample.json`):

The whole conversion is one expression on the `Amount` field:

```text
IF(STARTS_WITH(TRIM([Amount]), '('),
   0 - (REPLACE(REPLACE(REPLACE(TRIM([Amount]), '(', ''), ')', ''), ',', '') * 1),
        REPLACE(TRIM([Amount]), ',', '') * 1)
```

- `STARTS_WITH('(')` detects the parenthesised (negative) form.
- `REPLACE` strips `(`, `)` and the `,` thousands separators.
- `* 1` coerces the cleaned text to a number.
- `0 - (...)` applies the sign the parentheses stood for.
- The else branch just drops commas — handling plain positives (`"1,234.56"`)
  and rows that are *already* signed (`-100.00`) alike.

**Run it.**

```bash
bxp-cli --config ./sample.json --template accounting_negatives_clean
```

**Smoking gun.** The mixed-shape input collapses to clean signed decimals:

```text
1,234.56       →  1234.56
(2,500.00)     →  -2500
(1,234,567.89) →  -1234567.89
-100.00        →  -100
```

Every amount is now a real number ready to `SUM`, plot, or import — no manual
find-replace and no per-row sign bookkeeping.
