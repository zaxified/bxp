# Eurostat Population (bulk TSV) → Clean Per-Country Rows

[← all examples](../../README.md)

**What.** Turn one row of Eurostat's bulk `demo_pjan` download (population on 1
January) into a clean per-country row: dimensions unpacked into their own
columns, year values stripped of their quality-flag suffixes, and the `:`
missing-data marker turned into a real empty cell — all in one template.

**Why interesting.** Eurostat is the official statistical office of the EU and
its bulk TSV is the format behind thousands of research pipelines, yet every
file ships with four quirks that quietly break naive parsers: (1) it is
**tab-separated**, not comma; (2) the **first column packs five dimensions**
comma-joined into a single header cell — `freq,unit,age,sex,geo\TIME_PERIOD`,
with the row value like `A,NR,TOTAL,T,DE` — so you must split it before you can
group by country; (3) a **missing observation is the literal `:`** (often
`": "` with a trailing space), which a naive numeric cast reads as `0` or `NaN`;
(4) present values carry a **space-separated quality-flag suffix** —
`83118501 b` (break in series), `68277210 p` (provisional), `445891011 bep`
(several flags at once) — so `value * 1` throws and `cut`-based pipelines keep
the ` b` glued to the number.

**Edge cases sourced from.**

- [Eurostat bulk download / data format docs](https://wikis.ec.europa.eu/display/EUROSTATHELP/Transmission+format+of+data+and+metadata+-+SDMX)
  — the `:` not-available marker and the single-letter observation flags
  (`b` break, `e` estimated, `p` provisional, `d` definition differs, …) are
  the documented Eurostat conventions.
- The packed first-column header `dim1,dim2,…\TIME_PERIOD` is the standard
  shape of every Eurostat bulk TSV.

**A bxp quirk this example documents.** Eurostat's year headers are **bare
integers** (`2021`, `2022`). bxp reads `[2023]` as its `[N]` *positional* field
reference — "the 2023rd column" — so a purely-numeric header is **unreachable
by name**. The fix is to address the file positionally: `[1]` is the packed
dimension column, and the year columns by their position (`[2]`/`[3]`/`[4]` in
the sliced sample; `[63]`/`[64]`/`[65]` in the full file, where every year from
1960 is present). Year columns are appended at the end on each release, so the
front-counted positions stay stable.

**Data source.** [Eurostat — `demo_pjan` (Population on 1 January by age and
sex)](https://ec.europa.eu/eurostat/databrowser/view/demo_pjan/) via the
dissemination API. Free reuse with attribution (Commission Decision
2011/833/EU). (This slice: the 59 `freq=A, unit=NR, age=TOTAL, sex=T` rows —
one per geo — column-sliced to years 2021–2023.)

**Run it on the complete file.**

```bash
bash fetch-full.sh          # downloads the full demo_pjan bulk TSV into ./full/
bxp-cli --config full.json  # cleans every ~17.7k rows (all age/sex/geo combos)
```

**The trick** (see `sample.json`):

- **Unpack the dimension column** with `SPLIT_PART([1], ',', N)` — `geo` is
  part 5, `sex` part 4, `age` part 3.
- **Clean each observation** with one composable idiom:
  `NULLIF(SPLIT_PART(TRIM([n]), ' ', 1), ':')` — `TRIM` drops the trailing
  space, `SPLIT_PART(…, ' ', 1)` keeps the value and discards the flag, and
  `NULLIF(…, ':')` turns the missing-marker into an empty cell.
- **Keep the flag as data**, not noise: `SPLIT_PART(TRIM([n]), ' ', 2)` lifts
  the `b`/`p`/`bep` suffix into its own column so the break/provisional status
  survives the cleanup.

**Run it.**

```bash
bxp-cli --config ./sample.json --template eurostat_pop_tsv_clean
```

**Smoking gun.** Germany's raw 2023 cell is `83118501 b` and Andorra's is `: `.
The template turns them into:

```text
DE,TOTAL,T,83155031,83237124,83118501,b
AD,TOTAL,T,,,,
```

— a clean integer plus a preserved `b` flag for Germany, and three genuinely
empty cells for Andorra (not a misleading `0`). That drops straight into a
`GROUP BY geo` or a join on country code, with no pre-processing in Python.
