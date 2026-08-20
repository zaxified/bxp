# Messy Financial Export → Clean Transactions (combined)

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/advanced/messy-financial-export){ .md-button }

!!! abstract "What"
    Take one realistically messy brokerage/ERP transaction export and
    clean **six** things at once in a single template: US date → ISO,
    transaction-code → label, accounting negatives → signed amount, currency-symbol
    price → number + currency, percent/bps fee → fraction, and null-variant notes →
    empty.

!!! note "Synthetic / teaching example"
    The data here is **constructed**,
    not sourced — `sample.csv` is hand-written rows that pack one of every mess into
    each column. Each idiom is taught in isolation in the basic/intermediate tier;
    this is the capstone that combines them. The _problem classes_ are real; the
    rows are not.

## Why interesting

Real exports rarely have just one problem — a single CSV
mixes US dates, parenthesised negatives, currency symbols, percent/bps rates,
and a half-dozen null spellings, all in different columns. The point of this
example is that bxp handles the whole thing **declaratively in one pass**, with
no glue script orchestrating per-column cleanups.

## The tricks

Six idioms in one template; each also has an example of its own:

1. `DATE_CONVERT([TradeDate], 'MM/DD/YYYY', 'YYYY-MM-DD')`{.bxp-try}
2. transaction code → label via `REMAP` over a named map (`BUY` → `purchase`)
3. accounting negatives → signed — see
   [intermediate/accounting-negatives](../../intermediate/accounting-negatives/index.md)
4. price + currency split — see
   [intermediate/price-currency-split](../../intermediate/price-currency-split/index.md)
5. percent / bps → fraction — see
   [intermediate/percent-to-fraction](../../intermediate/percent-to-fraction/index.md)
6. null-variant notes → empty — see
   [basic/null-variants](../../basic/null-variants/index.md)

## Final result

One ragged input row —

```text
01/15/2024,BUY,AAPL,"(2,500.00)","$187.50",0.25%,
```

— comes out fully normalised, every field a clean typed value:

```text
2024-01-15,purchase,AAPL,-2500,187.5,USD,0.0025,
```

Dates sort, amounts sum, the currency is its own column, the fee is a real
fraction, and the empty note is genuinely empty — ready to load into a ledger or
analytics tool with no further cleanup.

## Sample data

Run it with `bxp-cli --config ./sample.json --template messy_financial_export`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/advanced/messy-financial-export/sample.json"
    ```

=== "sample.csv"

    ```{.csv .bxp-sample}
    --8<-- "examples/advanced/messy-financial-export/sample.csv"
    ```

=== "sample.csvx (result)"

    ```csv
    --8<-- "examples/advanced/messy-financial-export/sample.csvx"
    ```
