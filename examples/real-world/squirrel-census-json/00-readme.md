# NYC Squirrel Census (JSON API) → Flat CSV

[← all examples](../../README.md)

**What.** Flatten the 2018 NYC Central Park Squirrel Census — published as a
**JSON array** by a REST/Socrata API — into a tidy CSV, taking the union of keys
across heterogeneous records, coercing native JSON booleans to text, skipping a
nested geo object, and parsing a separator-less date, all in one template.

**Why interesting.** A huge share of public data now ships as a **JSON array of
objects from an API**, not as a CSV — and turning that into a spreadsheet-ready
CSV is the daily `jq`/pandas chore bxp removes. This famous dataset packs four
real JSON-shaped problems into one file: (1) **heterogeneous records** — most
sightings omit `primary_fur_color` and `location`, so the objects don't share a
key set and a naive `keys()` on the first record loses columns; (2) **native
JSON booleans** (`"running": false`) that a CSV needs as text, not as a
language-specific literal; (3) a **nested object** `geocoded_column: { type,
coordinates }` that has no flat CSV representation; (4) a date stored as the
**separator-less digit blob** `"10142018"`. bxp reads the array directly: it
scans once for the **union of keys** (first-seen order), materialises one record
at a time, and collapses absent keys to empty cells.

**Edge cases sourced from.**

- [Socrata / SODA JSON API](https://dev.socrata.com/docs/endpoints.html) returns
  a top-level array of objects with per-record optional fields and nested
  `geocoded_column` location objects — the standard shape of NYC/US open-data
  APIs.
- The census `date` field is `MMDDYYYY` with no separators (`"10142018"`).

**Data source.** [NYC Open Data — 2018 Central Park Squirrel Census
(`vfnx-vebw`)](https://data.cityofnewyork.us/Environment/2018-Central-Park-Squirrel-Census-Squirrel-Data/vfnx-vebw).
Public domain. (This slice: the first 40 sightings; two of them omit
`primary_fur_color`/`location`, demonstrating the heterogeneity.)

**Run it on the complete file.**

```bash
bash fetch-full.sh          # downloads all ~3,023 sightings as JSON into ./full/
bxp-cli --config full.json  # flattens every sighting → CSV
```

**The trick** (see `sample.json`):

- **Declare JSON input** with `file_type_in: "json"`. bxp scans the whole array
  once, takes the **union of keys** as the column set, and streams one record at
  a time — keys absent from a record become `""`.
- **Skip the nested object.** `geocoded_column` flattens to `""` (bxp doesn't
  descend into nested `{}`/`[]`), so the template reads the flat fields the API
  also provides: the lon/lat (`x`/`y`) and the `hectare` grid cell. The
  coordinates pass through with **every significant digit intact** — bxp copies
  numeric-looking strings verbatim, it doesn't round them to a fixed precision.
- **Parse the blob date** with `DATE_CONVERT([date], 'MMDDYYYY', 'YYYY-MM-DD')`.
- **Coerce booleans**: `[running]` etc. arrive as JSON `false`/`true` and land
  as the text `false`/`true`.

**Smoking gun.** The first two sightings have no `primary_fur_color` or
`location` keys at all; the third does. bxp lines them up under one schema:

```text
squirrel_id,date,shift,lat,lon,hectare,fur_color,location,running,eating,foraging
37F-PM-1014-03,2018-10-14,PM,40.7940823884086,-73.9561344937861,37F,,,false,false,false
11B-PM-1014-08,2018-10-14,PM,40.775533619083,-73.9742811484852,11B,Gray,Above Ground,false,false,false
```

— missing fields are genuinely empty (not a misaligned shift), the digit-blob
date is ISO, and the booleans are plain text. That CSV opens straight in a
spreadsheet, with no `jq` and no per-record key bookkeeping.
