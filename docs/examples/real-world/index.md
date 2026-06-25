# Real-world use cases

Real public datasets — each page cites its source and the documented problem it solves.

<div class="grid cards" markdown>

-   **[Chicago Business Licenses → Analytics Schema](chicago-business-licenses/index.md)**

    Turn the City of Chicago's raw Business Licenses export into a readable analytics CSV: cryptic status/type codes decoded to plain English, ISO dates, and an explicit marker for the (very common) missing application date.

-   **[JHU COVID-19 Wide → Long (unpivot)](covid-wide-to-long/index.md)**

    Reshape the Johns Hopkins COVID-19 confirmed-cases time series from its native **wide** layout (one column per day) into **long/tidy** rows (one row per country-date), using a single template.

-   **[Eurostat Population (bulk TSV) → Clean Per-Country Rows](eurostat-population-tsv/index.md)**

    Turn one row of Eurostat's bulk `demo_pjan` download (population on 1 January) into a clean per-country row: dimensions unpacked into their own columns, year values stripped of their quality-flag suffixes, and the `:` missing-data marker turned into a real empty cell — all in one template.

-   **[French DVF Real-Estate → Analytics Schema](french-dvf-realestate/index.md)**

    Reshape France's official "Demandes de valeurs foncières" (DVF) raw real-estate transaction export into a clean analytics CSV with ISO dates, proper euro amounts, and a repaired postal code.

-   **[GTFS Stops → Self-Join (pre_pass + LOOKUP)](gtfs-stops-selfjoin/index.md)**

    Enrich every NYC-subway platform row with its parent **station name** — a value that lives on a _different row of the same file_ — using bxp's `pre_pass` + `LOOKUP`.

-   **[HL7 v2 ADT Feed → Patient Roster](hl7-adt-patient-roster/index.md)**

    Pull a flat patient roster (MRN, name, birth date, sex) out of a feed of HL7 v2 **ADT** messages — keeping only the `PID` segments, splitting the `^`-delimited name components, and reformatting the birth date — with no HL7 parser library.

-   **[IMDb Title Basics → Catalog Row](imdb-title-basics/index.md)**

    Reshape IMDb's public `title.basics.tsv` into a CSV catalogue row with normalised null markers, exploded genres, and a boolean `adult` column.

-   **[Inside Airbnb NYC Listings → Analytics Schema](inside-airbnb-listings/index.md)**

    Reshape Inside Airbnb's public NYC scrape into an analytics CSV with short room-type codes, a regulatory-status column, and a visible sentinel for the redacted price field.

-   **[OpenNGC Sexagesimal Coordinates → Decimal Degrees](ngc-sexagesimal-coords/index.md)**

    Convert the celestial coordinates in the OpenNGC deep-sky catalogue from **sexagesimal** form — right ascension as `HH:MM:SS.s` (hours) and declination as `±DD:MM:SS.s` — into **decimal degrees**, the form plotting libraries, GIS tools and cross-match services expect.

-   **[NOAA GHCN Daily → Metric Units](noaa-ghcn-daily/index.md)**

    Convert NOAA Global Historical Climatology Network daily records into a CSV with proper SI units (°C and mm) and a per-row consistency flag.

-   **[NYC Yellow Taxi Trips → Analytics Schema](nyc-taxi-trips/index.md)**

    Convert raw NYC TLC Yellow Taxi trip records into an analytics-ready CSV with ISO timestamps, human-readable payment types, and a per-row data quality flag.

-   **[RÚIAN address points — a zipped CSV-per-municipality export](ruian-address-points/index.md)**

    The Czech state address register (RÚIAN) is published as a single ZIP holding one Windows-1250, semicolon-delimited CSV per municipality, all under a `CSV/` folder inside the archive.

-   **[NYC Squirrel Census (JSON API) → Flat CSV](squirrel-census-json/index.md)**

    Flatten the 2018 NYC Central Park Squirrel Census — published as a **JSON array** by a REST/Socrata API — into a tidy CSV, taking the union of keys across heterogeneous records, coercing native JSON booleans to text, skipping a nested geo object, and parsing a separator-less date, all in one template.

-   **[US Treasury Yield Curve (wide → long) + tenor mapping](treasury-yield-curve/index.md)**

    Melt the US Treasury's daily par-yield-curve CSV from its native **wide** layout (one column per maturity — `1 Mo`, `2 Yr`, … `30 Yr`) into **long/tidy** rows (one row per date-tenor), converting the US date to ISO and mapping each maturity label to its length in months — all in one template.

</div>
