# Accounting Negatives → Signed Decimals

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/intermediate/accounting-negatives){ .md-button }

!!! abstract "What"
    Normalise an accounting/bank/ERP export where negative amounts are
    written in **parentheses** — `"(2,500.00)"` means `-2500` — and thousands are
    comma-grouped, into a clean signed-decimal column.

!!! note "Synthetic / teaching example"
    The data here is **constructed**, not sourced
    — `sample.csv` is hand-written rows engineered to plant one of each amount
    shape. The _failure mode_ is real and documented; the rows are not. (Accounting
    negatives ride in private bank/ledger exports, which have no public dataset —
    so this lives in the teaching tier, not `examples/real-world/`.)

## Why interesting

The parenthesis-for-negative convention is everywhere in
finance (it's the default "Accounting" number format in Excel), and it breaks
naive pipelines twice over: a spreadsheet re-import reads `"(2,500.00)"` as a
text label, and any `amount * 1` cast throws on both the parentheses and the
comma thousands separator. The sign silently vanishes or the row errors out.

**Failure mode documented in.** (sources for the problem class — not for the data)

- [Microsoft — Accounting number format](https://support.microsoft.com/en-us/office/format-numbers-in-cells-as-accounting-format)
  uses parentheses for negatives.
- Generic CSV-import guides repeatedly call out converting `($1,234.56)` →
  `-1234.56` before analysis.

## The trick

(see inline comments in `sample.json`)

The whole conversion is one expression on the `Amount` field:

```{.text .bxp-try}
IF(STARTS_WITH(TRIM([Amount]), '('),
   0 - (REPLACE(REPLACE(REPLACE(TRIM([Amount]), '(', ''), ')', ''), ',', '') * 1),
        REPLACE(TRIM([Amount]), ',', '') * 1)
```

- `STARTS_WITH('(')` detects the parenthesised (negative) form.
- `REPLACE` strips `(`, `)` and the `,` thousands separators.
- `* 1` coerces the cleaned text to a number.
- `0 - (...)` applies the sign the parentheses stood for.
- The else branch just drops commas — handling plain positives (`"1,234.56"`)
  and rows that are _already_ signed (`-100.00`) alike.

## Final result

The mixed-shape input collapses to clean signed decimals:

```text
1,234.56       →  1234.56
(2,500.00)     →  -2500
(1,234,567.89) →  -1234567.89
-100.00        →  -100
```

Every amount is now a real number ready to `SUM`, plot, or import — no manual
find-replace and no per-row sign bookkeeping.

## Sample data

Run it with `bxp-cli --config ./sample.json --template accounting_negatives_clean`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/intermediate/accounting-negatives/sample.json"
    ```

=== "sample.csv"

    ```{.csv .bxp-sample}
    --8<-- "examples/intermediate/accounting-negatives/sample.csv"
    ```
