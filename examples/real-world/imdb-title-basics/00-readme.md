# IMDb Title Basics → Catalog Row

[← all examples](../../README.md)

**What.** Reshape IMDb's public `title.basics.tsv` into a CSV catalogue row with normalised null markers, exploded genres, and a boolean `adult` column.

**Why interesting.** IMDb's public non-commercial datasets are the canonical reference for film research, and they ship with three idiosyncrasies that silently corrupt every downstream pipeline that assumes "standard CSV": (1) the file is tab-separated, not comma-separated, so `cut -d,` and auto-detecting tools mis-parse every row; (2) missing values are encoded as the literal two-character string `\N` instead of an empty cell, so a naive type cast on `runtimeMinutes` returns `NaN` half the time; (3) `genres` is itself a comma-separated list embedded inside one TSV field.

**Edge cases sourced from.**

- <https://developer.imdb.com/non-commercial-datasets/> — official IMDb
  non-commercial dataset reference; documents `\N` and the TSV format
- <https://stackoverflow.com/questions/60655099/how-to-process-the-imdb-tsv-files-in-python>
  — community thread on the `\N` pitfall

**Data source.** [IMDb Non-Commercial Datasets — `title.basics.tsv.gz`](https://datasets.imdbws.com/title.basics.tsv.gz)
(this slice: first 500 titles).

**The tricks** (see inline comments in `sample.json`):

0. **TSV not CSV** — `csv_delimiter_in: "\t"` switches the parser to tab
   delimiting; output stays CSV for downstream tools.
1. **`\N` null marker** — `IF([X] = '\N', '', [X])` rewritten three times
   (startYear, endYear, runtimeMinutes) plus once for the whole `genres`
   field.
2. **Multi-value genre cell** — `SPLIT_PART([genres], ',', 1)` peels the
   first genre into its own `primary_genre` column while `all_genres`
   keeps the full list for filtering.

**Smoking gun.** Before the fix in TRICK 2 was applied, exactly one row in
this 500-title slice — `tt0000502` (`Bohemios`, 1905 Spanish film) — had
`genres = '\N'`. The first version of `sample.json` handled `\N` for
year/runtime but not for genres, so `SPLIT_PART('\N', ',', 1)` happily
returned `'\N'` as the "primary genre" and the literal backslash-N leaked
into the catalogue.

Open `sample.csv` row 501 (or `sample.csvx` row 501) in the GUI, click the
`primary_genre` cell: the trace pane shows the IF branch that now correctly
returns `''` for the null-genre row. Without that branch, the smoking gun
was completely invisible — `errors:0`, `warnings:0`, but one row in your
catalogue had `\N` as its genre forever.
