# Messy Financial Export → Clean Transactions (combined)

[← all examples](../../README.md)

**What.** Take one realistically messy brokerage/ERP transaction export and
clean **six** things at once in a single template: US date → ISO,
transaction-code → label, accounting negatives → signed amount, currency-symbol
price → number + currency, percent/bps fee → fraction, and null-variant notes →
empty.

**Synthetic / teaching example (advanced).** The data here is **constructed**,
not sourced — `sample.csv` is hand-written rows that pack one of every mess into
each column. Each idiom is taught in isolation in the basic/intermediate tier;
this is the capstone that combines them. The *problem classes* are real; the
rows are not.

**Why interesting.** Real exports rarely have just one problem — a single CSV
mixes US dates, parenthesised negatives, currency symbols, percent/bps rates,
and a half-dozen null spellings, all in different columns. The point of this
example is that bxp handles the whole thing **declaratively in one pass**, with
no glue script orchestrating per-column cleanups.

**The idioms combined** (each has its own example — see links):

1. `DATE_CONVERT([TradeDate], 'MM/DD/YYYY', 'YYYY-MM-DD')`
2. transaction code → label via a `ticker_map` (`BUY` → `purchase`)
3. accounting negatives → signed — see
   [intermediate/accounting-negatives](../../intermediate/accounting-negatives/00-readme.md)
4. price + currency split — see
   [intermediate/price-currency-split](../../intermediate/price-currency-split/00-readme.md)
5. percent / bps → fraction — see
   [intermediate/percent-to-fraction](../../intermediate/percent-to-fraction/00-readme.md)
6. null-variant notes → empty — see
   [basic/null-variants](../../basic/null-variants/00-readme.md)

**Smoking gun.** One ragged input row —

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
