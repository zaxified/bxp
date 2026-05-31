# BXP Examples

Two kinds of example live here:

- **Real-world use cases** — real, publicly available datasets, each with a
  cited source describing a genuine data problem. The committed `sample.csv` is
  a small real slice; `fetch-full.sh` pulls the complete file for a scale run.
- **Teaching examples** — small, synthetic, constructed inputs that isolate one
  engine feature at a time. The data is fabricated on purpose.

Open a per-example readme for the full story, or copy the command to run it.

## Real-world use cases

Real public datasets — each readme cites its source and the documented problem it solves.

### JHU COVID-19 Wide → Long (unpivot)

**What.** Reshape the Johns Hopkins COVID-19 confirmed-cases time series from

**Why interesting.** The JHU CSSE time series was the most-analysed dataset of

📄 [real-world/covid-wide-to-long/00-readme.md](real-world/covid-wide-to-long/00-readme.md)

```bash
bxp-cli --config ./real-world/covid-wide-to-long/sample.json --template covid_wide_to_long
```

### French DVF Real-Estate → Analytics Schema

**What.** Reshape France's official "Demandes de valeurs foncières" (DVF) raw

**Why interesting.** DVF is the canonical open dataset for French property

📄 [real-world/french-dvf-realestate/00-readme.md](real-world/french-dvf-realestate/00-readme.md)

```bash
bxp-cli --config ./real-world/french-dvf-realestate/sample.json --template dvf_realestate_to_analytics
```

### Chicago Business Licenses → Analytics Schema

**What.** Turn the City of Chicago's raw Business Licenses export into a

**Why interesting.** It's a real, actively-maintained municipal dataset whose

📄 [real-world/chicago-business-licenses/00-readme.md](real-world/chicago-business-licenses/00-readme.md)

```bash
bxp-cli --config ./real-world/chicago-business-licenses/sample.json --template chicago_licenses_to_analytics
```

### IMDb Title Basics → Catalog Row

**What.** Reshape IMDb's public `title.basics.tsv` into a CSV catalogue row with normalised null markers, exploded genres, and a boolean `adult` column.

**Why interesting.** IMDb's public non-commercial datasets are the canonical reference for film research, and they ship with four idiosyncrasies that silently corrupt every downstream pipeline that assumes "standard CSV": (1) the file is tab-separated, not comma-separated, so `cut -d,` and auto-detecting tools mis-parse every row; (2) missing values are encoded as the literal two-character string `\N` instead of an empty cell, so a naive type cast on `runtimeMinutes` returns `NaN` half the time; (3) `genres` is itself a comma-separated list embedded inside one TSV field; (4) the TSV is **unquoted** yet thousands of titles contain a literal `"` character (`"Giliap"`, `Mujeres ... "nervios"`), so any RFC-4180 parser that assumes `"` opens a quoted field silently swallows every line up to the next `"` — dropping ~256k of the 12.5M rows with no error.

📄 [real-world/imdb-title-basics/00-readme.md](real-world/imdb-title-basics/00-readme.md)

```bash
bxp-cli --config ./real-world/imdb-title-basics/sample.json --template imdb_titles_to_catalog
```

### Inside Airbnb NYC Listings → Analytics Schema

**What.** Reshape Inside Airbnb's public NYC scrape into an analytics CSV with short room-type codes, a regulatory-status column, and a visible sentinel for the redacted price field.

**Why interesting.** Inside Airbnb is the de-facto open dataset for short-term-rental regulation research, and it ships with three real-world pain points: (1) the `visualisations/listings.csv` endpoint redacts the `price` column entirely yet ships it as an empty field rather than removing the column, (2) listing names contain raw commas inside double quotes (`"Perfect for Your Parents, With Garden"`) so a naive split-on-comma parser silently shifts every column rightward, (3) NYC's Local Law 18 (2023) introduced short-term-rental registration and the `license` column is one of three states (`""`, `"Exempt"`, or `"OSE-STRREG-NNNNNNN"`) — most listings are still unregistered.

📄 [real-world/inside-airbnb-listings/00-readme.md](real-world/inside-airbnb-listings/00-readme.md)

```bash
bxp-cli --config ./real-world/inside-airbnb-listings/sample.json --template airbnb_listings_to_analytics
```

### NOAA GHCN Daily → Metric Units

**What.** Convert NOAA Global Historical Climatology Network daily records into a CSV with proper SI units (°C and mm) and a per-row consistency flag.

**Why interesting.** GHCN is the most widely cited open climate dataset in the world (10k+ stations, daily back to 1763 for some) and it ships with a unit convention that silently 10×-amplifies every reading for anyone who doesn't read the documentation: temperatures are stored as integer **tenths of degrees Celsius**, precipitation as **tenths of millimetres**, both left-padded with whitespace into a fixed-width column. A row showing `TMAX="   50"` is 5.0°C, not 50°C — climate-research repos on GitHub repeatedly ship this bug.

📄 [real-world/noaa-ghcn-daily/00-readme.md](real-world/noaa-ghcn-daily/00-readme.md)

```bash
bxp-cli --config ./real-world/noaa-ghcn-daily/sample.json --template noaa_daily_to_metric
```

### NYC Yellow Taxi Trips → Analytics Schema

**What.** Convert raw NYC TLC Yellow Taxi trip records into an analytics-ready CSV with ISO timestamps, human-readable payment types, and a per-row data quality flag.

**Why interesting.** NYC TLC publishes monthly Yellow Taxi CSVs containing ~10M rows per month, publicly cited in hundreds of analytics tutorials, and they ship with two silent data-quality landmines that wreck naive aggregations: trips with `passenger_count = 0` (driver-only / no fare) and trips with `fare_amount < 0` (refund/reversal posted as a negative row).

📄 [real-world/nyc-taxi-trips/00-readme.md](real-world/nyc-taxi-trips/00-readme.md)

```bash
bxp-cli --config ./real-world/nyc-taxi-trips/sample.json --template nyc_taxi_to_analytics
```

## Teaching examples (synthetic)

Constructed, minimal inputs that isolate one feature. The data is fabricated, not sourced.

### HubSpot Contacts → Salesforce Lead

**What.** Convert a HubSpot Contacts CSV export into a Salesforce Lead Import CSV.

**Why interesting.** Real CRM migrations take 2–8 weeks because picklist mismatches, mixed date formats and trailing whitespace fail _silently_ — the import succeeds row by row, then Salesforce rejects half of them after the fact.

📄 [intermediate/hubspot-to-salesforce/00-readme.md](intermediate/hubspot-to-salesforce/00-readme.md)

```bash
bxp-cli --config ./intermediate/hubspot-to-salesforce/sample.json --template hubspot_to_sfdc_lead
```
