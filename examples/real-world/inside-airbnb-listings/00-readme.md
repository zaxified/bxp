# Inside Airbnb NYC Listings → Analytics Schema

[← all examples](../../README.md)

**What.** Reshape Inside Airbnb's public NYC scrape into an analytics CSV with short room-type codes, a regulatory-status column, and a visible sentinel for the redacted price field.

**Why interesting.** Inside Airbnb is the de-facto open dataset for short-term-rental regulation research, and it ships with three real-world pain points: (1) the `visualisations/listings.csv` endpoint redacts the `price` column entirely yet ships it as an empty field rather than removing the column, (2) listing names contain raw commas inside double quotes (`"Perfect for Your Parents, With Garden"`) so a naive split-on-comma parser silently shifts every column rightward, (3) NYC's Local Law 18 (2023) introduced short-term-rental registration and the `license` column is one of three states (`""`, `"Exempt"`, or `"OSE-STRREG-NNNNNNN"`) — most listings are still unregistered.

**Edge cases sourced from.**

- <https://insideairbnb.com/data-policies/> — explains the price redaction
  in the `visualisations` slice
- <https://www.nyc.gov/site/specialenforcement/registration-law/registration-law.page>
  — NYC Local Law 18 short-term rental registration; explains the `license`
  field semantics

**Data source.** [Inside Airbnb — New York City, 2026-02-13 scrape](https://data.insideairbnb.com/united-states/ny/new-york-city/2026-02-13/visualisations/listings.csv)
(this slice: first 300 listings).

**The tricks** (see inline comments in `sample.json`):

0. **CSV double-quote escaping** — `csv_text_quote_in: "double"` so names
   like `"Maison des Sirenes1,bohemian, luminous apartment"` don't shift
   every following column.
1. **room_type enum** — `Entire home/apt` / `Private room` / `Hotel room` /
   `Shared room` → short codes via `TICKER()` + `ticker_map`.
2. **Redacted price sentinel** — `COALESCE([price], '<price-redacted>')` so
   the gap is visible in every row instead of silently empty.
3. **last_review empty == "never reviewed"** — kept as empty on purpose;
   not every absent value is an error.
4. **Three-state regulatory column** — `IF` chain over `[license]` derives
   `unlicensed` / `exempt` / `registered`.

**Smoking gun.** Run the conversion and look at the `reg_status` histogram.
In this 300-row real-data slice from February 2026:

- **251 listings (84%) are `unlicensed`** — still operating without the
  NYC-mandated registration two and a half years after Local Law 18 took
  effect
- 21 are `exempt` (hotels, certain owner-occupied)
- 28 are `registered`

Open `sample.csvx` in the GUI and sort by `reg_status`. The 251-row
`unlicensed` block is the regulatory enforcement gap visible at a glance —
a downstream tool with no per-field validation would just see "license is a
string" and never flag the missing-value pattern.
