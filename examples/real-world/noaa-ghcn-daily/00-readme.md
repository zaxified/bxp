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

**The tricks** (see inline comments in `sample.json`):

1. **TRIM + ÷10 unit conversion** — `IF(TRIM([TMAX]) = '', '', TRIM([TMAX]) / 10)`
   handles both the whitespace padding and the tenths-of-°C scaling, while
   keeping empty cells empty (`partial` measurement gaps stay empty rather
   than collapsing to 0.0°C).
2. **Per-row consistency flag** — flag rows where `TMAX < TMIN` (instrument
   fault), `TMAX`/`TMIN` empty (`partial`), or otherwise `ok`. Climatology
   averages computed across the raw column would silently swallow these.

**BXP limitation surfaced.** GHCN's per-station file has **124 columns**
(every measurement element pairs with a `_ATTRIBUTES` quality-flag column).
BXP's CSV parser caps at 64 columns and emits `warnings:1`. All elements
this example needs (TMAX at col 13, TMIN at 15, TAVG at 57) fit under the
cap, but a config that referenced anything past column 64 would silently
return empty strings. Worth a tracker entry as a real-world ceiling.

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
