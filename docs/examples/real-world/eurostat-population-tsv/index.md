# Eurostat Population (bulk TSV) → Clean Per-Country Rows

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/eurostat-population-tsv){ .md-button }

!!! abstract "What"
    Turn one row of Eurostat's bulk `demo_pjan` download (population on 1
    January) into a clean per-country row: dimensions unpacked into their own
    columns, year values stripped of their quality-flag suffixes, and the `:`
    missing-data marker turned into a real empty cell — all in one template.

## Why interesting

Eurostat is the official statistical office of the EU and its bulk TSV is the
format behind thousands of research pipelines, yet every file ships with four
quirks that quietly break naive parsers: (1) it is **tab-separated**, not comma;
(2) the **first column packs five dimensions** comma-joined into a single header
cell — `freq,unit,age,sex,geo\TIME_PERIOD`, with the row value like
`A,NR,TOTAL,T,DE` — so you must split it before you can group by country; (3) a
**missing observation is the literal `:`** (often `": "` with a trailing space),
which a naive numeric cast reads as `0` or `NaN`; (4) present values carry a
**space-separated quality-flag suffix** — `83118501 b` (break in series),
`68277210 p` (provisional), `445891011 bep` (several flags at once) — so
`value * 1` throws and `cut`-based pipelines keep the `b` glued to the number.

**Edge cases sourced from.**

- [Eurostat bulk download / data format docs](https://wikis.ec.europa.eu/display/EUROSTATHELP/Transmission+format+of+data+and+metadata+-+SDMX)
  — the `:` not-available marker and the single-letter observation flags
  (`b` break, `e` estimated, `p` provisional, `d` definition differs, …) are
  the documented Eurostat conventions.
- The packed first-column header `dim1,dim2,…\TIME_PERIOD` is the standard
  shape of every Eurostat bulk TSV.

## Addressing the columns

`[Name]` in bxp is always a lookup **by header name** — there is no `[N]`
positional form, and headers are trimmed before matching, so Eurostat's
`2023 ` header (bare integer, trailing space) is in fact reachable as
`[2023]`, and even the packed first column answers to
`[freq,unit,age,sex,geo\TIME_PERIOD]`.

This template addresses the file **positionally** instead, with the `FIELDS(n)`
accessor: `FIELDS(1)` is the packed dimension column, and the year columns are
`FIELDS(2)`/`FIELDS(3)`/`FIELDS(4)` in the sliced sample and
`FIELDS(63)`/`FIELDS(64)`/`FIELDS(65)` in the full file, where every year from
1960 is present. Positional access keeps `sample.json` and `full.json` the same
shape — the only thing that changes between them is the index — and new year
columns are appended at the end on each release, so the front-counted positions
stay stable. Either style works here; pick by-name when the header is stable and
descriptive, `FIELDS(n)` when the file is really a positional record.

**Data source.** [Eurostat — `demo_pjan` (Population on 1 January by age and
sex)](https://ec.europa.eu/eurostat/databrowser/view/demo_pjan/) via the
dissemination API. Free reuse with attribution (Commission Decision
2011/833/EU). (This slice: the 59 `freq=A, unit=NR, age=TOTAL, sex=T` rows —
one per geo — column-sliced to years 2021–2023.)

## At full scale

```bash
bash fetch-full.sh          # downloads the full demo_pjan bulk TSV into ./full/
bxp-cli --config full.json  # cleans every ~17.7k rows (all age/sex/geo combos)
```

## The trick

(see `sample.json`):

- **Unpack the dimension column** with `SPLIT_PART(FIELDS(1), ',', N)` — `geo`
  is part 5, `sex` part 4, `age` part 3.
- **Clean each observation** with one composable idiom:
  `NULLIF(SPLIT_PART(TRIM(FIELDS(n)), ' ', 1), ':')` — `TRIM` drops the trailing
  space, `SPLIT_PART(…, ' ', 1)` keeps the value and discards the flag, and
  `NULLIF(…, ':')` turns the missing-marker into an empty cell.
- **Keep the flag as data**, not noise: `SPLIT_PART(TRIM(FIELDS(n)), ' ', 2)` lifts
  the `b`/`p`/`bep` suffix into its own column so the break/provisional status
  survives the cleanup.

## Final result

Germany's raw 2023 cell is `83118501 b` and Andorra's is `: `. The template
turns them into:

```text
DE,TOTAL,T,83155031,83237124,83118501,b
AD,TOTAL,T,,,,
```

— a clean integer plus a preserved `b` flag for Germany, and three genuinely
empty cells for Andorra (not a misleading `0`). That drops straight into a
`GROUP BY geo` or a join on country code, with no pre-processing in Python.

## Sample data

Run it with `bxp-cli --config ./sample.json --template eurostat_pop_tsv_clean`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/real-world/eurostat-population-tsv/sample.json"
    ```

=== "sample.csv"

    ```csv
    --8<-- "examples/real-world/eurostat-population-tsv/sample.csv"
    ```

**Full-scale &amp; binary files** (run it on the complete dataset): [`fetch-full.sh`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/eurostat-population-tsv/fetch-full.sh) · [`full.json`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/eurostat-population-tsv/full.json).
