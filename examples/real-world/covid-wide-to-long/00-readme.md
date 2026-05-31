# JHU COVID-19 Wide → Long (unpivot)

[← all examples](../../README.md)

**What.** Reshape the Johns Hopkins COVID-19 confirmed-cases time series from
its native **wide** layout (one column per day) into **long/tidy** rows
(one row per country-date), using a single template.

**Why interesting.** The JHU CSSE time series was the most-analysed dataset of
the pandemic, and it ships in the shape analysts least want: each day is its
own column (`1/22/20`, `1/23/20`, … out to `3/9/23`), so the file is ~1147
columns wide and every plotting/grouping tool first has to **melt** it to long
form. Unpivoting is normally a `pandas.melt` / `tidyr::pivot_longer` step — but
bxp does it declaratively, in the template, with no code: one input row fans
out to many output rows via multi-row `row_rules`.

**Edge cases sourced from.**

- [pandas `melt` / wide-to-long](https://pandas.pydata.org/docs/user_guide/reshaping.html)
  and [tidyr `pivot_longer`](https://tidyr.tidyverse.org/articles/pivot.html)
  exist precisely because wide time-series need reshaping before analysis
- country names embed commas (`"Korea, South"`), so the file is double-quoted

**Data source.** [JHU CSSE COVID-19 Data Repository](https://github.com/CSSEGISandData/COVID-19)
— `time_series_covid19_confirmed_global.csv` (archived March 2023). CC BY 4.0.
(this slice: 23 countries × the first day + two year-end snapshot columns.)

**Run it on the complete file.**

```bash
bash fetch-full.sh          # downloads the full ~1147-column series into ./full/
bxp-cli --config full.json  # unpivots all ~289 country/region rows → ~867 long rows
```

The unpivot is the point, not raw volume (the file is only ~289 rows). Note the
full file has **1147 columns**, past bxp's 1024-column cap — bxp warns and
ignores the overflow days. The three snapshot columns this template reads (cols
5 / 349 / 714) are within range, so the reshape is unaffected; raising that cap
is a [roadmap item](../../../docs/roadmap.md).

**The trick** (see `sample.json`):

- **Unpivot via multi-row `row_rules`.** Each entry in `rows: [ … ]` emits one
  output row, pulling a different date column (`[12/31/20]`) and stamping the
  matching ISO date as a literal. Three entries → three country-date rows per
  input country. (Date columns are named with slashes; `[1/22/20]` works as a
  field reference. Inside an override you reference *fields* with `[..]`, not
  `$variables`.)

**Run it.**

```bash
bxp-cli --config ./sample.json --template covid_wide_to_long
```

**Smoking gun.** `sample.csvx` turns one `Afghanistan` row holding
`0 | 52330 | 158084` across three columns into three tidy rows:

```text
Afghanistan,2020-01-22,0
Afghanistan,2020-12-31,52330
Afghanistan,2021-12-31,158084
```

That long shape drops straight into a `GROUP BY date` or a time-series plot —
no melt step, no Python. To add more snapshots, add more `rows` entries; to
unpivot *every* day you would loop the columns, which is the natural feature
boundary (and the reason day-per-column files want this reshape in the first
place).
