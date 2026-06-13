# Chicago Business Licenses → Analytics Schema

[← all examples](../../README.md)

**What.** Turn the City of Chicago's raw Business Licenses export into a
readable analytics CSV: cryptic status/type codes decoded to plain English,
ISO dates, and an explicit marker for the (very common) missing application
date.

**Why interesting.** It's a real, actively-maintained municipal dataset whose
two most important columns are **opaque codes**: `LICENSE STATUS` is `AAI` /
`AAC` / `REV` / `REA` and `APPLICATION TYPE` is `ISSUE` / `RENEW` / `C_LOC` /
`C_CAPA` / `C_EXPA` / `C_SBA`. A naive import leaves them as-is — you cannot
tell a cancelled licence from a revoked one without keeping the data dictionary
open in another tab. On top of that, **~84% of rows have a blank
`APPLICATION CREATED DATE`** (only fresh applications carry one), which reads as
a data-loss bug unless the gap is made explicit. The fix is exactly what a
lookup table + a sentinel are for.

**Edge cases sourced from.** All code meanings are quoted verbatim from the
dataset's own description on the City of Chicago data portal:

- **LICENSE STATUS** — `AAI` = licence issued, `AAC` = cancelled during its
  term, `REV` = revoked, `REA` = revocation appealed.
- **APPLICATION TYPE** — `ISSUE` = initial application, `RENEW` = renewal,
  `C_LOC` = change of location, `C_CAPA` = change of capacity, `C_EXPA` =
  liquor-area expansion, `C_SBA` = change of business activity.

**Data source.** [City of Chicago — Business Licenses (`r5kz-chrr`)](https://data.cityofchicago.org/Community-Economic-Development/Business-Licenses/r5kz-chrr)
(this slice: 223 rows pulled via the Socrata API, selected to include all four
status codes). Public domain (City of Chicago).

**Run it at full scale.** The committed `sample.csv` is a 223-row slice; the
real register is the complete licence history from 2002 to today. Pull it and
run the same template against the whole thing:

```bash
bash fetch-full.sh          # downloads ./full/chicago_licenses.csv (~1.2M rows)
bxp-cli --config full.json  # processes the whole register
```

Measured on the reference machine (ReleaseFast, 8 cores):

| metric                  | value                                       |
| ----------------------- | ------------------------------------------- |
| input / output          | 1,197,482 rows (1:1) / 194 MB → 121 MB      |
| wall time               | ~4.2 s                                      |
| peak RSS                | ~19 MB (flat)                               |
| `issued`                | 1,117,686                                   |
| `cancelled_during_term` | 78,329                                      |
| `revoked`               | 1,453                                       |
| `revocation_appealed`   | 13                                          |
| `applied = <not-on-file>` | **918,458 (76%)**                         |

Two things the full run surfaces that the slice can't:

- **1,453 revoked + 78,329 cancelled licences** decoded out of the cryptic
  `REV`/`AAC` codes — a compliance query can finally filter on a readable label.
- **One row carries an undocumented `INQ` status** (the dataset description
  lists only `AAI/AAC/REV/REA`). `REMAP` leaves an unmapped code **visible and
  unchanged** rather than blanking it, so the gap surfaces instead of silently
  vanishing — a forward-safe lookup, not a silent drop.

**The tricks** (see inline comments in `sample.json`):

0. **Quoted commas** — `csv_text_quote_in: "double"`; legal/DBA names embed commas.
1. **DBA fallback** — `COALESCE([doing_business_as_name], [legal_name])` so the
   business is never blank.
2. **Status code → label** — `REMAP([license_status], 'license_status_label')`
   over a named map built from the documented `AAI/AAC/REV/REA` meanings.
3. **Application type → label** — a `CASE` multi-branch (a second controlled
   vocabulary kept inline to show `CASE`; it could equally be a second named
   map). `CASE` matches the code against value/label pairs with the raw code as
   the fallback — one call in place of a six-deep nested `IF`.
4. **ISO date trim + missing-date sentinel** — `DATE_CONVERT(..., 'YYYY-MM-DD[T]hh:mm:ss', 'YYYY-MM-DD')`
   keeps the date part; `IF([application_created_date] = '', '<not-on-file>', …)`
   turns the 84%-blank column into an explicit marker.

**Run it.**

```bash
bxp-cli --config ./sample.json --template chicago_licenses_to_analytics
```

**Smoking gun.** Sort `sample.csvx` by `status`. The `revoked` and
`cancelled_during_term` blocks are now obvious at a glance — in the raw file
they were `REV` and `AAC`, indistinguishable to anyone without the data
dictionary, and a compliance query filtering on the literal string `"cancelled"`
would have returned **zero rows**.
