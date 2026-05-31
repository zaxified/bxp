# Vintage Harmonisation (one source, format drifted over time)

[← all examples](../../README.md)

**What.** Fold several **vintages of the same source** — a broker export whose
column names, date format and number format changed over the years — into one
consistent table.

**Synthetic / teaching example.** The data here is **constructed**, not sourced.
`trades_2022_legacy.csv` (Date/Ticker/Amount, ISO dates, plain numbers) and
`trades_2024_current.csv` (trade_date/symbol/value, `DD.MM.YYYY`, `"1 250,50"`).
The *problem class* — exports that quietly change shape between versions — is
universal; the rows are not.

**Why interesting.** Long-lived data is never one schema. A bank renames a
column, switches `MM/DD` to `DD.MM`, starts grouping thousands — and every old
file is now incompatible with every new one. Analysts keep a pile of
one-off cleanup scripts per era. One template, written against *both* layouts,
collapses the whole archive into a single normalised table.

**Problem class documented in.** (sources for the problem class — not for the data)

- Schema/format drift over time is the core motivation for "schema evolution"
  handling in every data-lake format (Parquet/Avro/Delta) and the reason ETL
  jobs carry per-vintage mapping tables.

**The trick** (see inline comments in `sample.json`):

A column absent from a file reads as `""`, so one template can target *every*
vintage's column name and pick whichever is present:

- date — `IF(LEN([Date]) > 0, [Date], DATE_CONVERT([trade_date], 'DD.MM.YYYY', …))`
  (legacy is already ISO; convert only the current vintage).
- ticker — `COALESCE([Ticker], [symbol])` (a pure rename).
- amount — pick by presence, normalise the EU `"1 250,50"` to a number.

`combined_output: true` then stacks all vintages into one
`1-vintage_harmonise-combined.csvx`.

**Run it.**

```bash
bxp-cli --config ./sample.json --template vintage_harmonise
```

**Smoking gun.** 2022 and 2024 files, three different format quirks, become one
clean table — ISO dates, canonical tickers, numeric amounts:

```text
date,ticker,amount
2022-06-15,AAPL,1000.5
2022-07-01,MSFT,2500
2024-03-15,AAPL,1250.5
2024-04-02,NVDA,3980
```
