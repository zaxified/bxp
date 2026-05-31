# NYC Yellow Taxi Trips → Analytics Schema

[← all examples](../../README.md)

**What.** Convert raw NYC TLC Yellow Taxi trip records into an analytics-ready CSV with ISO timestamps, human-readable payment types, and a per-row data quality flag.

**Why interesting.** NYC TLC publishes monthly Yellow Taxi CSVs containing ~10M rows per month, publicly cited in hundreds of analytics tutorials, and they ship with two silent data-quality landmines that wreck naive aggregations: trips with `passenger_count = 0` (driver-only / no fare) and trips with `fare_amount < 0` (refund/reversal posted as a negative row).

**Edge cases sourced from.**

- <https://www.nyc.gov/assets/tlc/downloads/pdf/data_dictionary_trip_records_yellow.pdf>
  — official TLC data dictionary (datetime format, payment_type codes 1-6)
- <https://chriswhong.com/open-data/foil_nyc_taxi/> — original FOIL release,
  documents the negative-fare refund convention

**Data source.** [NYC TLC Trip Record Data](https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page)
(this slice: first 800 trips of the 2019 Yellow Taxi data). The TLC has since
retired its public CSV downloads in favour of Parquet, so the full-scale fetch
below pulls the identical records — same CSV layout, same `MM/DD/YYYY hh:mm:ss
AM/PM` timestamps — from the [NYC OpenData mirror](https://data.cityofnewyork.us/Transportation/2019-Yellow-Taxi-Trip-Data/2upf-qytp).

**Run it at full scale.** The committed `sample.csv` is an 800-row slice; the
real 2019 dataset is ~84M trips. Pull it and run the same template against the
whole thing:

```bash
bash fetch-full.sh          # downloads ./full/yellow_tripdata_2019.csv (~8 GB)
bxp-cli --config full.json  # processes all ~84M trips
```

Measured on the reference machine (ReleaseFast, 8 cores):

| metric            | value                                       |
| ----------------- | ------------------------------------------- |
| input / output    | 84,399,020 rows (1:1) / 7.7 GB → 6.5 GB     |
| wall time         | ~285 s (two `DATE_CONVERT` calls per row)   |
| peak RSS          | ~23 MB (flat — does not grow with 84M rows) |
| `no_passengers`   | **1,772,399 rows (2.1%)** — physically impossible, paid fare with `passenger_count = 0` |
| `refund`          | **169,241 rows** — negative-fare reversals posted as trips |

Constant ~23 MB while streaming 84 million rows and emitting 6.5 GB is the
headline: the data-quality flag isolates ~1.94M anomalous rows that no spot
check would ever surface.

The data-quality flag is the payoff at scale: the `no_passengers` and `refund`
rows are a tiny fraction of 84M, invisible in any spot check, yet they silently
skew every average-fare and tip-rate aggregate computed over the raw column.

**The tricks** (see inline comments in `sample.json`):

1. **US datetime with AM/PM** — `02/09/2018 01:25:25 PM` → ISO 8601 via
   `DATE_CONVERT(..., 'MM/DD/YYYY hh:mm:ss A', 'YYYY-MM-DD[T]hh:mm:ss[Z]')`.
2. **store_and_fwd_flag** — `"N"`/`"Y"` → readable `false`/`true` with `IF`.
3. **payment_type code → label** — `TICKER()` over a 1-6 → text lookup map
   built from the TLC dictionary.
4. **Data-quality sentinel column** — `IF([passenger_count] = '0', ...)`
   classifies each row as `ok` / `no_passengers` / `refund` so the
   anomalies stand out instead of contaminating aggregates.

**Run it.**

```bash
bxp-cli --config ./sample.json --template nyc_taxi_to_analytics
```

**Smoking gun.** Run the conversion and look at the `quality` column. In this
800-row real-data slice the engine surfaces:

- 5 rows of `no_passengers` (driver pickups with a paid fare but
  `passenger_count = 0` — physically impossible, almost certainly meter bugs)
- 1 row of `refund` (every monetary field is negative: `fare = -4`,
  `tolls = -0.3`, `total = -4.8`)

Open `sample.csvx` row 187 (or `sample.csv` row 507) in the GUI, click the
`quality` cell: the trace pane shows the full evaluation chain that decided
`refund`. Without the quality column those 6 rows silently lower your
average-fare statistic and skew tip-rate analysis.
