# OpenNGC Sexagesimal Coordinates → Decimal Degrees

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/ngc-sexagesimal-coords){ .md-button }

!!! abstract "What"
    Convert the celestial coordinates in the OpenNGC deep-sky catalogue
    from **sexagesimal** form — right ascension as `HH:MM:SS.s` (hours) and
    declination as `±DD:MM:SS.s` — into **decimal degrees**, the form plotting
    libraries, GIS tools and cross-match services expect.

## Why interesting

Essentially every astronomical catalogue stores
coordinates sexagesimally, and it trips up newcomers twice: right ascension is
in **hours, not degrees** (so it needs a ×15 factor, since 24h = 360°), and the
declination's sign sits on the degrees field but must apply to the arc-minutes
and arc-seconds too. Getting either wrong silently places objects in the wrong
part of the sky. The standard fix is an `astropy`/`SkyCoord` call or a
hand-written parser; bxp does it declaratively in two expressions.

**Edge cases sourced from.**

- The HH:MM:SS / ±DD:MM:SS convention and the hours→degrees ×15 factor are
  standard [equatorial coordinate](https://en.wikipedia.org/wiki/Equatorial_coordinate_system)
  notation used by every catalogue.
- Non-existent catalogue entries (`Type = NonEx`) carry **blank** RA/Dec, so the
  conversion must guard empty cells.

**Data source.** [OpenNGC](https://github.com/mattiaverga/OpenNGC) — the open,
maintained catalogue of NGC/IC objects (`database_files/NGC.csv`,
semicolon-delimited). Licensed CC-BY-SA-4.0. (This slice: famous Messier objects
— M31, M42, M51, M13, M57, … — plus a few IC objects and one `NonEx` blank-coord
entry.)

## The trick

(see `sample.json`):

- **RA → degrees:** `(SPLIT_PART([RA],':',1) + SPLIT_PART([RA],':',2)/60 +
SPLIT_PART([RA],':',3)/3600) * 15` — split on `:`, sum to hours, ×15.
- **Dec → degrees:** capture the sign once with `STARTS_WITH('-')`, then apply
  it to the magnitude `ABS(deg) + min/60 + sec/3600` so the sign covers the
  whole value, not just the degrees field.
- Both guarded with `LEN(TRIM(...)) = 0` so blank-coord `NonEx` rows stay empty
  instead of computing to `0` (which would be a real point on the sky).

## At full scale

```bash
bash fetch-full.sh          # downloads all ~13,970 NGC/IC objects into ./full/
bxp-cli --config full.json  # converts every object's RA/Dec → decimal degrees
```

## Final result

The Andromeda Galaxy (M31 = NGC 224) and the Orion Nebula
(M42 = NGC 1976, southern) convert exactly:

```text
NGC0224  00:42:44.35  +41:16:08.6  →  10.68479167   41.26905556
NGC1976  05:35:16.48  -05:23:22.8  →  83.81866667   -5.38966667
```

Those decimal degrees drop straight into a scatter plot, a `astropy` `SkyCoord`,
or a spatial join — no per-coordinate parsing in the consumer.

## Sample data

Run it with `bxp-cli --config ./sample.json --template ngc_to_decimal_degrees`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/real-world/ngc-sexagesimal-coords/sample.json"
    ```

=== "sample.csv"

    ```csv
    --8<-- "examples/real-world/ngc-sexagesimal-coords/sample.csv"
    ```

**Full-scale &amp; binary files** (run it on the complete dataset): [`fetch-full.sh`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/ngc-sexagesimal-coords/fetch-full.sh) · [`full.json`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/ngc-sexagesimal-coords/full.json).
