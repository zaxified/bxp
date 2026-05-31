# NOAA GHCN Daily → Metric Units

[← all examples](../../README.md)

**What.** Convert NOAA Global Historical Climatology Network daily records into a CSV with proper SI units (°C and mm) and a per-row consistency flag.

**Why interesting.** GHCN is the most widely cited open climate dataset in the world (10k+ stations, daily back to 1763 for some) and it ships with a unit convention that silently 10×-amplifies every reading for anyone who doesn't read the documentation: temperatures are stored as integer **tenths of degrees Celsius**, precipitation as **tenths of millimetres**, both left-padded with whitespace into a fixed-width column. A row showing `TMAX="   50"` is 5.0°C, not 50°C — climate-research repos on GitHub repeatedly ship this bug.

**Edge cases sourced from.**

- <https://www.ncei.noaa.gov/pub/data/ghcn/daily/readme.txt> — official GHCN
  daily README; documents the tenths-of-units convention, the whitespace
  padding, and the per-element quality flag columns
- <https://github.com/pangeo-data/pangeo/issues/598> — Pangeo community
  thread where users were getting 50°C readings before noticing the scaling

**Data source.** [NOAA GHCN Daily — Central Park station USW00094728](https://www.ncei.noaa.gov/data/global-historical-climatology-network-daily/access/USW00094728.csv)
(this slice: first 300 days from 2020-01-01 onwards).

**Run it at full scale.** The committed `sample.csv` is a 300-row slice; the
real Central Park file is the complete daily history. Pull it and run the same
template against the whole thing:

```bash
bash fetch-full.sh          # downloads ./full/USW00094728.csv (~17 MB)
bxp-cli --config full.json  # processes the full history
```

Measured on the reference machine (ReleaseFast, 8 cores):

| metric        | value                                       |
| ------------- | ------------------------------------------- |
| input         | 57,486 rows × **124 columns** / 17 MB       |
| date span     | 1869-01-01 → 2026-05-23 (157 years)         |
| wall time     | ~0.25 s                                     |
| peak RSS      | ~15 MB (flat — does not grow with the file) |
| `ok`          | 55,918 rows                                 |
| `partial`     | 1,566 rows (TMAX or TMIN missing)           |
| `tmax_below_tmin` | **2 rows** — 1894-10-05 (15.6 < 16.1 °C) etc. |

The consistency flag earns its keep here: two instrument-fault days hidden in
157 years of records, found in a quarter-second.

**The tricks** (see inline comments in `sample.json`):

1. **TRIM + ÷10 unit conversion** — `IF(TRIM([TMAX]) = '', '', TRIM([TMAX]) / 10)`
   handles both the whitespace padding and the tenths-of-°C scaling, while
   keeping empty cells empty (`partial` measurement gaps stay empty rather
   than collapsing to 0.0°C).
2. **Per-row consistency flag** — flag rows where `TMAX < TMIN` (instrument
   fault), `TMAX`/`TMIN` empty (`partial`), or otherwise `ok`. Climatology
   averages computed across the raw column would silently swallow these.

**Wide files.** GHCN's per-station file has **124 columns** (every
measurement element pairs with a `_ATTRIBUTES` quality-flag column). BXP
parses all of them — the full run reports `warnings:0` and every referenced
element resolves, including `TAVG` at column 57. bxp-cli's column ceiling is
**1024** (`MAX_COLUMNS`); a 124-column climate file sits comfortably under it.
Inputs wider than that (e.g. a daily time-series with one column per day) warn
and ignore the overflow — see the roadmap entry on raising the cap.

**Smoking gun.** Run the conversion and look at row 3 (`2020-01-03`):

- Raw `TMAX="   94"` → `tmax_c = 9.4`
- Raw `TMIN="   67"` → `tmin_c = 6.7`
- Raw `PRCP="   38"` → `prcp_mm = 3.8`

Open the GUI on the `tmax_c` cell of any row: the trace pane shows the
chain `IF(TRIM("   94") = '', '', TRIM("   94") / 10) = 9.4`. Without the
÷10 step a casual user sees `94` and concludes January 3rd 2020 in Central
Park hit 94°C. The 298 `ok` rows plus 2 `partial` rows in this slice show
that the engine separates "real measurement" from "measurement gap" before
either lands in your downstream analytics.
