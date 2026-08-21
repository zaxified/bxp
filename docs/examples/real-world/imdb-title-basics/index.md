# IMDb Title Basics → Catalog Row

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/imdb-title-basics){ .md-button }

!!! abstract "What"
    Reshape IMDb's public `title.basics.tsv` into a CSV catalogue row with normalised null markers, exploded genres, and a boolean `adult` column.

## Why interesting

IMDb's public non-commercial datasets are the canonical reference for film research, and they ship with four idiosyncrasies that silently corrupt every downstream pipeline that assumes "standard CSV": (1) the file is tab-separated, not comma-separated, so `cut -d,` and auto-detecting tools mis-parse every row; (2) missing values are encoded as the literal two-character string `\N` instead of an empty cell, so a naive type cast on `runtimeMinutes` returns `NaN` half the time; (3) `genres` is itself a comma-separated list embedded inside one TSV field; (4) the TSV is **unquoted** yet thousands of titles contain a literal `"` character (`"Giliap"`, `Mujeres ... "nervios"`), so any RFC-4180 parser that assumes `"` opens a quoted field silently swallows every line up to the next `"` — dropping ~256k of the 12.5M rows with no error.

**Edge cases sourced from.**

- <https://developer.imdb.com/non-commercial-datasets/> — official IMDb
  non-commercial dataset reference; documents `\N` and the TSV format
- <https://stackoverflow.com/questions/60655099/how-to-process-the-imdb-tsv-files-in-python>
  — community thread on the `\N` pitfall

**Data source.** [IMDb Non-Commercial Datasets — `title.basics.tsv.gz`](https://datasets.imdbws.com/title.basics.tsv.gz)
(this slice: 10 real titles hand-picked so that every quirk is visible in one
short table — a `\N` genre, a `\N` runtime, real `endYear` values, an adult
title, and two titles carrying a literal `"`).

## At full scale

The committed `sample.csv` is a 10-row teaching slice; the real file is ~12.5M
rows. Pull it and run the same template against the whole thing:

```bash
bash fetch-full.sh          # downloads + extracts ./full/title.basics.tsv (~1 GB)
bxp-cli --config full.json  # processes all 12.5M rows
```

Measured on the reference machine (ReleaseFast, 8 cores):

| metric    | value                                   |
| --------- | --------------------------------------- |
| input     | 12,533,197 rows / 1.1 GB TSV            |
| output    | 12,533,197 rows / 1.1 GB CSV (1:1)      |
| wall time | ~21.4 s                                 |
| peak RSS  | ~29 MB (flat — does not grow with rows) |

The 1:1 row count: `csv_text_quote_in:"none"` declares the TSV unquoted, so a
stray `"` in a title is plain data. Even with default `"` quoting left on,
bxp's lazy-quote handling now keeps all 12,533,197 rows and emits a warning on
the 2 lines carrying an unbalanced `"` — it no longer silently merges them
(older RFC-4180 tools drop ~256k rows here). `none` is still the right call:
same 1:1 result with no spurious warning. `full/` is gitignored — the download
stays local.

## The tricks

(see inline comments in `sample.json`):

0. **TSV not CSV** — `csv_delimiter_in: "\t"` switches the parser to tab
   delimiting; output stays CSV for downstream tools.
   - **Unquoted TSV with literal `"`** — `csv_text_quote_in: "none"` turns
     off RFC-4180 quote handling, so a `"` in a title is plain data. The slice
     carries two such titles, `"Giliap"` and `L'homme du "Picardie"`; the
     output re-quotes them properly for CSV consumers. BXP defaults the input
     quote to `"`; with lazy-quote handling it no longer merges rows even then
     — every row is kept and the lines with an unbalanced `"` get a warning
     (older RFC-4180 tools silently drop ~256k rows). `none` is preferred for a
     known-unquoted format: same result, no warning.
1. **`\N` null marker** — `NULLIF([X], '\N')` on startYear, endYear and
   runtimeMinutes, plus once for the whole `genres` field. `NULLIF` is built
   for sentinels, so each guard names its field once instead of three times.
2. **Multi-value genre cell** — `SPLIT_PART([genres], ',', 1)` peels the
   first genre into its own `primary_genre` column while `all_genres`
   keeps the full list for filtering.

## Final result

Every `\N` becomes a genuine empty cell, the genre list gains a sortable first
element, and a `"` in a title survives into properly quoted CSV:

```text
raw                                          →  converted
Bohemios          genres=\N                  →  primary_genre=(empty)  all_genres=(empty)
The German …      endYear=1945  runtime=\N   →  end_year=1945          runtime_min=(empty)
Kate & Leopold    genres=Comedy,Fantasy,…    →  primary_genre=Comedy   all_genres="Comedy,Fantasy,Romance"
Bacchanales 69    isAdult=1                  →  adult=true
"Giliap"                                     →  title="Giliap"  (re-quoted for CSV)
```

The `\N` guard is the one that bites hardest. Without it `SPLIT_PART('\N', ',', 1)`{.bxp-try}
returns the literal `\N` as a perfectly plausible "primary genre" — the run
still reports `errors:0`, `warnings:0`, and a backslash-N sits in the catalogue
forever. `Bohemios` (1905) is that row.

## Sample data

Run it with `bxp-cli --config ./sample.json --template imdb_titles_to_catalog`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/real-world/imdb-title-basics/sample.json"
    ```

=== "sample.csv"

    ```csv
    --8<-- "examples/real-world/imdb-title-basics/sample.csv"
    ```

=== "sample.csvx (result)"

    ```csv
    --8<-- "examples/real-world/imdb-title-basics/sample.csvx"
    ```

**Full-scale &amp; binary files** (run it on the complete dataset): [`fetch-full.sh`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/imdb-title-basics/fetch-full.sh) · [`full.json`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/imdb-title-basics/full.json).

