# Examples

Runnable demonstrations of one data problem each — config, input, and the
exact transformation. Open any card for the full story; the **View on
GitHub** button on each page links the complete files to run it yourself.

## Real-world use cases

Real public datasets — each page cites its source and the documented problem it solves.

<div class="grid cards" markdown>

-   **[Chicago Business Licenses → Analytics Schema](real-world/chicago-business-licenses/index.md)**

    Turn the City of Chicago's raw Business Licenses export into a readable analytics CSV: cryptic status/type codes decoded to plain English, ISO dates, and an explicit marker for the (very common) missing application date.

-   **[JHU COVID-19 Wide → Long (unpivot)](real-world/covid-wide-to-long/index.md)**

    Reshape the Johns Hopkins COVID-19 confirmed-cases time series from its native **wide** layout (one column per day) into **long/tidy** rows (one row per country-date), using a single template.

-   **[Eurostat Population (bulk TSV) → Clean Per-Country Rows](real-world/eurostat-population-tsv/index.md)**

    Turn one row of Eurostat's bulk `demo_pjan` download (population on 1 January) into a clean per-country row: dimensions unpacked into their own columns, year values stripped of their quality-flag suffixes, and the `:` missing-data marker turned into a real empty cell — all in one template.

-   **[French DVF Real-Estate → Analytics Schema](real-world/french-dvf-realestate/index.md)**

    Reshape France's official "Demandes de valeurs foncières" (DVF) raw real-estate transaction export into a clean analytics CSV with ISO dates, proper euro amounts, and a repaired postal code.

-   **[GTFS Stops → Self-Join (pre_pass + LOOKUP)](real-world/gtfs-stops-selfjoin/index.md)**

    Enrich every NYC-subway platform row with its parent **station name** — a value that lives on a _different row of the same file_ — using bxp's `pre_pass` + `LOOKUP`.

-   **[HL7 v2 ADT Feed → Patient Roster](real-world/hl7-adt-patient-roster/index.md)**

    Pull a flat patient roster (MRN, name, birth date, sex) out of a feed of HL7 v2 **ADT** messages — keeping only the `PID` segments, splitting the `^`-delimited name components, and reformatting the birth date — with no HL7 parser library.

-   **[IMDb Title Basics → Catalog Row](real-world/imdb-title-basics/index.md)**

    Reshape IMDb's public `title.basics.tsv` into a CSV catalogue row with normalised null markers, exploded genres, and a boolean `adult` column.

-   **[Inside Airbnb NYC Listings → Analytics Schema](real-world/inside-airbnb-listings/index.md)**

    Reshape Inside Airbnb's public NYC scrape into an analytics CSV with short room-type codes, a regulatory-status column, and a visible sentinel for the redacted price field.

-   **[OpenNGC Sexagesimal Coordinates → Decimal Degrees](real-world/ngc-sexagesimal-coords/index.md)**

    Convert the celestial coordinates in the OpenNGC deep-sky catalogue from **sexagesimal** form — right ascension as `HH:MM:SS.s` (hours) and declination as `±DD:MM:SS.s` — into **decimal degrees**, the form plotting libraries, GIS tools and cross-match services expect.

-   **[NOAA GHCN Daily → Metric Units](real-world/noaa-ghcn-daily/index.md)**

    Convert NOAA Global Historical Climatology Network daily records into a CSV with proper SI units (°C and mm) and a per-row consistency flag.

-   **[NYC Yellow Taxi Trips → Analytics Schema](real-world/nyc-taxi-trips/index.md)**

    Convert raw NYC TLC Yellow Taxi trip records into an analytics-ready CSV with ISO timestamps, human-readable payment types, and a per-row data quality flag.

-   **[RÚIAN address points — a zipped CSV-per-municipality export](real-world/ruian-address-points/index.md)**

    The Czech state address register (RÚIAN) is published as a single ZIP holding one Windows-1250, semicolon-delimited CSV per municipality, all under a `CSV/` folder inside the archive.

-   **[NYC Squirrel Census (JSON API) → Flat CSV](real-world/squirrel-census-json/index.md)**

    Flatten the 2018 NYC Central Park Squirrel Census — published as a **JSON array** by a REST/Socrata API — into a tidy CSV, taking the union of keys across heterogeneous records, coercing native JSON booleans to text, skipping a nested geo object, and parsing a separator-less date, all in one template.

-   **[US Treasury Yield Curve (wide → long) + tenor mapping](real-world/treasury-yield-curve/index.md)**

    Melt the US Treasury's daily par-yield-curve CSV from its native **wide** layout (one column per maturity — `1 Mo`, `2 Yr`, … `30 Yr`) into **long/tidy** rows (one row per date-tenor), converting the US date to ISO and mapping each maturity label to its length in months — all in one template.

</div>

## Teaching — basic

Synthetic, minimal inputs that isolate one engine feature at a time.

<div class="grid cards" markdown>

-   **[Null Variants → Empty](basic/null-variants/index.md)**

    Fold every "no value" spelling — `NULL`, `NA`, `N/A`, `n/a`, `None`, `"-"` — into a single genuine empty cell, while leaving real values untouched.

-   **[Space-Grouped Thousands → Number](basic/space-thousands/index.md)**

    Parse the continental-European number format — space-grouped thousands with a **comma** decimal, `"1 234 567,89"` = `1234567.89` — into a clean numeric value.

-   **[Units-in-Cell → Number + Unit](basic/units-in-cell/index.md)**

    Split a measurement column that glues a number to its unit — `5.0 kg`, `250 g`, `1.5 L`, `12 pcs` — into a clean numeric `amount` and a separate `unit` column.

</div>

## Teaching — intermediate

Synthetic examples combining a few features.

<div class="grid cards" markdown>

-   **[Accounting Negatives → Signed Decimals](intermediate/accounting-negatives/index.md)**

    Normalise an accounting/bank/ERP export where negative amounts are written in **parentheses** — `"(2,500.00)"` means `-2500` — and thousands are comma-grouped, into a clean signed-decimal column.

-   **[Boolean Variants → Canonical true/false](intermediate/boolean-variants/index.md)**

    Fold boolean columns written every which way — `Yes`/`No`, `Y`/`N`, `1`/`0`, `true`/`false`, `TRUE`/`T`/`F`, mixed case — into a canonical `true`/`false`, with blanks and unrecognised junk left empty.

-   **[Fan-In Many Files → One Table (`combined_output`)](intermediate/fan-in-files/index.md)**

    Stack a folder of same-shape exports — one CSV per day/month — into a single combined table, in deterministic order, with no manual `cat` and no repeated header rows.

-   **[HubSpot Contacts → Salesforce Lead](intermediate/hubspot-to-salesforce/index.md)**

    Convert a HubSpot Contacts CSV export into a Salesforce Lead Import CSV.

-   **[JSON Union → One CSV (heterogeneous keys)](intermediate/json-union/index.md)**

    Merge several JSON exports whose objects carry **different key sets** into a single CSV with every column, where a key a record never had collapses to an empty cell.

-   **[Percent / Basis Points → Decimal Fraction](intermediate/percent-to-fraction/index.md)**

    Normalise a `Rate` column that mixes percent (`2.5%`), basis points (`25 bps`) and the odd already-decimal legacy value (`0.03`) into one consistent decimal fraction.

-   **[Price + Currency Split](intermediate/price-currency-split/index.md)**

    Split a single mixed-notation `Price` column — `$12.99`, `50.00 EUR`, `€3.50`, `1,234.00 USD` — into a clean numeric `price` and a separate `currency` code, using bxp's `PRICE_VALUE` / `PRICE_CURRENCY` builtins.

</div>

## Teaching — advanced

Synthetic multi-pass pipelines, joins, and capstones.

<div class="grid cards" markdown>

-   **[Free-Text Payment Memos → Structured References](advanced/freeform-payment-memos/index.md)**

    Pull the structured tokens a downstream ledger needs — an invoice number, an order reference, a has-any-reference flag — out of **free-text** payment memos, where each token sits at a _variable_ position inside an otherwise human-written sentence.

-   **[Messy Financial Export → Clean Transactions (combined)](advanced/messy-financial-export/index.md)**

    Take one realistically messy brokerage/ERP transaction export and clean **six** things at once in a single template: US date → ISO, transaction-code → label, accounting negatives → signed amount, currency-symbol price → number + currency, percent/bps fee → fraction, and null-variant notes → empty.

-   **[Mixed-Format Bridge (CSV batch + JSON batch → one dataset)](advanced/mixed-format-bridge/index.md)**

    Combine records that arrive in **two different file formats** — an old CSV batch and a new JSON batch of the same kind of data — into one unified table.

-   **[Multi-Stage ETL — chained two-hop JOIN + DST timezone (capstone)](advanced/multi-stage-etl/index.md)**

    A transitive (two-hop) JOIN that no single pass can do — order → product → category → name — chained across passes, while normalising three different date formats and bridging CSV ↔ JSON, finishing with a DST-aware Europe/Prague timestamp.

-   **[Two-File Keyed JOIN (concat + pre_pass + LOOKUP)](advanced/two-file-join/index.md)**

    Enrich a fact table that carries only a foreign key (orders → `customer_id`) with the human details from a separate dimension table (customers → `name`, `city`) — a real relational JOIN across two sources.

-   **[Vintage Harmonisation (one source, format drifted over time)](advanced/vintage-harmonise/index.md)**

    Fold several **vintages of the same source** — a broker export whose column names, date format and number format changed over the years — into one consistent table.

-   **[XLSX Tabs → One Long Table (sheet per period)](advanced/xlsx-tabs-merge/index.md)**

    Flatten an Excel workbook that keeps **one tab per period** (January / February / March) into a single long table with a `month` column.

</div>
