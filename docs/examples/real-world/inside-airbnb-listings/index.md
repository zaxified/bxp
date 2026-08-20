# Inside Airbnb NYC Listings → Analytics Schema

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/inside-airbnb-listings){ .md-button }

!!! abstract "What"
    Reshape Inside Airbnb's public NYC scrape into an analytics CSV with short room-type codes, a regulatory-status column, and a visible sentinel for the redacted price field.

## Why interesting

Inside Airbnb is the de-facto open dataset for short-term-rental regulation research, and it ships with three real-world pain points: (1) the `visualisations/listings.csv` endpoint redacts the `price` column entirely yet ships it as an empty field rather than removing the column, (2) listing names contain raw commas inside double quotes (`"Perfect for Your Parents, With Garden"`) so a naive split-on-comma parser silently shifts every column rightward, (3) NYC's Local Law 18 (2023) introduced short-term-rental registration and the `license` column is one of three states (`""`, `"Exempt"`, or `"OSE-STRREG-NNNNNNN"`) — most listings are still unregistered.

**Edge cases sourced from.**

- <https://insideairbnb.com/data-policies/> — explains the price redaction
  in the `visualisations` slice
- <https://www.nyc.gov/site/specialenforcement/registration-law/registration-law.page>
  — NYC Local Law 18 short-term rental registration; explains the `license`
  field semantics

**Data source.** [Inside Airbnb — New York City, 2026-02-13 scrape](https://data.insideairbnb.com/united-states/ny/new-york-city/2026-02-13/visualisations/listings.csv)
(this slice: 12 real listings hand-picked so that each room type meets each of
the three regulatory states, plus the two comma-inside-quotes names and one
never-reviewed listing).

## At full scale

The committed `sample.csv` is a 12-row teaching slice; the
real scrape is the full current NYC listing set. Pull it and run the same
template against the whole thing:

```bash
bash fetch-full.sh          # downloads ./full/listings.csv (~6 MB)
bxp-cli --config full.json  # processes every NYC listing
```

Measured on the reference machine (ReleaseFast, 8 cores):

| metric         | value                                                |
| -------------- | ---------------------------------------------------- |
| input          | 36,445 listings (RFC-4180 records), no column shift  |
| output         | 36,616 rows — 154 listings split, see below          |
| wall time      | ~0.07 s                                              |
| peak RSS       | ~17 MB                                               |
| `unlicensed`   | 31,645 rows (**86%**)                                |
| `exempt`       | 2,686 rows                                           |
| `registered`   | 2,285 rows                                           |
| price redacted | 36,471 rows (**every real listing** — the endpoint strips every price; the other 145 rows are the split fragments below, whose columns are shifted) |

!!! note "Why the two row counts differ"

    Both numbers are right, they just count different things. **36,445** is what
    a strict RFC-4180 parser sees: it treats a newline inside a quoted field as
    part of the value and keeps reading. **36,616** is what bxp emits, because
    a newline **always** ends a record here — lazy-quote semantics, a deliberate
    design decision, not a parsing bug (see *Not planned* in the
    [roadmap](../../../dev/roadmap.md)). 154 listings on this scrape carry a
    newline inside their quoted description — most span two lines, a few up to
    six — so they arrive as 171 extra rows, and the run says so: `308 row(s)
    had an unbalanced quote — treated as literal text`. Their columns are
    shifted, so 145 of them show a stray value in `price_usd` and 144 fall into
    the `unlicensed` bucket by default — a 0.5% skew that does not move the
    headline rate. If you need those descriptions rejoined, strip the newlines
    before the conversion.

**86% of the full 36k listings are `unlicensed`** — Local Law 18's enforcement
gap, straight out of the `reg_status` column the template derives. The
quoted-comma names (e.g. `Perfect for Your Parents, With Garden & Patio`)
stay intact in a single field, exactly as TRICK 0 promises — commas are handled
by the quoting rules; only newlines break a record.

## The tricks

See inline comments in `sample.json`:

0. **CSV double-quote escaping** — `csv_text_quote_in: "double"` so names
   like `"Maison des Sirenes1,bohemian, luminous apartment"` don't shift
   every following column.
1. **room_type enum** — `Entire home/apt` / `Private room` / `Hotel room` /
   `Shared room` → short codes via `REMAP()` + a named map.
2. **Redacted price sentinel** — `COALESCE([price], '<price-redacted>')`{.bxp-try} so
   the gap is visible in every row instead of silently empty.
3. **last_review empty == "never reviewed"** — kept as empty on purpose;
   not every absent value is an error.
4. **Three-state regulatory column** — a `CASE` map over `[license]` derives
   `unlicensed` / `exempt` / `registered`.

## Final result

Three raw shapes of the `license` column become one column you can filter on,
and the redacted price stops looking like a value that happens to be missing:

```text
raw license                →  reg_status    price
""                         →  unlicensed    <price-redacted>
"Exempt"                   →  exempt        <price-redacted>
"OSE-STRREG-0006194"       →  registered    <price-redacted>
```

`"Perfect for Your Parents, With Garden & Patio"` also survives as **one**
field — the comma inside the quotes does not shift every column to its right.

A downstream tool with no per-field validation sees only "license is a string"
and never flags the missing-value pattern; here `WHERE reg_status =
'unlicensed'` is the whole compliance query.

!!! tip "Trace it in the GUI"
    Open `sample.csvx` and sort by `reg_status`, then click a `price_usd` cell:
    the trace pane shows `COALESCE` falling through to the sentinel, which is
    what distinguishes "the endpoint redacts this" from "this listing is free".

## Sample data

Run it with `bxp-cli --config ./sample.json --template airbnb_listings_to_analytics`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/real-world/inside-airbnb-listings/sample.json"
    ```

=== "sample.csv"

    ```{.csv .bxp-sample}
    --8<-- "examples/real-world/inside-airbnb-listings/sample.csv"
    ```

=== "sample.csvx (result)"

    ```csv
    --8<-- "examples/real-world/inside-airbnb-listings/sample.csvx"
    ```

**Full-scale &amp; binary files** (run it on the complete dataset): [`fetch-full.sh`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/inside-airbnb-listings/fetch-full.sh) · [`full.json`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/inside-airbnb-listings/full.json).
