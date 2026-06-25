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
(this slice: first 500 titles).

## At full scale

The committed `sample.csv` is a 500-row slice that
shows the quirks; the real file is ~12.5M rows. Pull it and run the same
template against the whole thing:

```bash
bash fetch-full.sh          # downloads + extracts ./full/title.basics.tsv (~1 GB)
bxp-cli --config full.json  # processes all 12.5M rows
```

Measured on the reference machine (ReleaseFast, 8 cores):

| metric    | value                                   |
| --------- | --------------------------------------- |
| input     | 12,533,197 rows / 1.1 GB TSV            |
| output    | 12,533,197 rows / 1.1 GB CSV (1:1)      |
| wall time | ~24.5 s                                 |
| peak RSS  | ~26 MB (flat — does not grow with rows) |

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
     off RFC-4180 quote handling, so a `"` in a title is plain data. BXP
     defaults the input quote to `"`; with lazy-quote handling it no longer
     merges rows even then — every row is kept and the 2 lines with an
     unbalanced `"` get a warning (older RFC-4180 tools silently drop ~256k
     rows). `none` is preferred for a known-unquoted format: same result,
     no warning. This is invisible on the 500-row slice (no quoted titles
     in it) — see the scale note above.
1. **`\N` null marker** — `IF([X] = '\N', '', [X])` rewritten three times
   (startYear, endYear, runtimeMinutes) plus once for the whole `genres`
   field.
2. **Multi-value genre cell** — `SPLIT_PART([genres], ',', 1)` peels the
   first genre into its own `primary_genre` column while `all_genres`
   keeps the full list for filtering.

## Run it

```bash
bxp-cli --config ./sample.json --template imdb_titles_to_catalog
```

## Final result

Before the fix in TRICK 2 was applied, exactly one row in
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

**Full-scale &amp; binary files** (run it on the complete dataset): [`fetch-full.sh`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/imdb-title-basics/fetch-full.sh) · [`full.json`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/imdb-title-basics/full.json).
