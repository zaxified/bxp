# Timezone Functions — normalise to UTC, convert between zones

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/basic/timezone-functions){ .md-button }

!!! abstract "What"
    Turn messy per-broker timestamps into clean UTC and derive zone facts with
    the four timezone builtins — `TO_UTC`, `TZ_OFFSET`, `IS_DST`, and
    `TZ_CONVERT` — all DST-aware, no external service.

!!! note "Synthetic / teaching example"
    The rows in `sample.csv` are **hand-written** to cover a few zone/DST shapes
    (Prague winter vs summer, New York, Tokyo). The _problem class_ — reconciling
    timestamps from sources that disagree on how they encode time — is real; the
    data is not.

## Why interesting

Every data source encodes time differently. One broker stamps an ISO string with
its UTC offset (`2024-07-15T14:30:00+02:00`); the next gives a **naive** local
time and expects you to know the account's zone; a third is in Tokyo. You cannot
compare, sort, or join these until they share one clock. The honest common clock
is **UTC**, and getting there correctly means handling daylight-saving time — the
offset for `Europe/Prague` is `+01:00` in January but `+02:00` in July.

BXP bundles a snapshot of the IANA time-zone database, so the conversion is exact
and offline — no `pytz`, no timezone API, no hand-rolled "last Sunday of March"
arithmetic.

## The trick

Two ways in, depending on what the source gives you. Each **Run it** below
evaluates against `sample.csv`; **show all** shows the whole column, which is
where the winter/summer difference becomes obvious:

```text
# The string already carries its offset → subtract it, no zone lookup:
utc:    TO_UTC([raw_iso], 'YYYY-MM-DD[T]hh:mm:ssZZ')

# Only a naive local time + a zone id → let the tz database do the work:
offset: TZ_OFFSET([local_time], [zone])                       # +01:00 / +02:00, DST-aware
dst:    IS_DST([local_time], [zone])                          # true in summer
nyc:    TZ_CONVERT([local_time], [zone], 'America/New_York')  # move it to another zone
```

- **`TO_UTC(ts, from)`** parses a format that ends in the `ZZ` offset token (or a
  literal `Z`) and subtracts the parsed offset. It needs no zone database — the
  offset is in the string.
  Run it: `TO_UTC([raw_iso], 'YYYY-MM-DD[T]hh:mm:ssZZ')`{.bxp-try}
- **`TZ_OFFSET(datetime, zone)`** returns the DST-aware `±HH:MM` offset of an
  IANA `zone` at a local wall-clock time. Concatenate it onto a naive timestamp
  to make it ISO-8601 tz-aware.
  Run it: `TZ_OFFSET([local_time], [zone])`{.bxp-try}
- **`IS_DST(datetime, zone)`** flags whether daylight-saving time was in effect.
  Run it: `IS_DST([local_time], [zone])`{.bxp-try}
- **`TZ_CONVERT(ts, from_zone, to_zone)`** converts a wall-clock time between two
  zones (each an IANA id, a fixed offset like `+02:00`, or `UTC`).
  Run it: `TZ_CONVERT([local_time], [zone], 'America/New_York')`{.bxp-try}

## Final result

The same 14:30 wall-clock in Prague lands on a different UTC instant in winter
and summer, and both are handled automatically:

```text
label        local        zone            → utc          offset  dst    in New York
CET-winter   14:30 Jan    Europe/Prague   → 13:30 UTC    +01:00  false  08:30
CEST-summer  14:30 Jul    Europe/Prague   → 12:30 UTC    +02:00  true   08:30
EST-newyork  09:00 Jan    America/New_York→ 14:00 UTC    -05:00  false  09:00
JST-tokyo    23:45 Jul    Asia/Tokyo      → 14:45 UTC    +09:00  false  10:45
```

Every timestamp now shares the UTC clock and is ready to sort, compare, or join
across sources. For the full builtin reference see
[Expression functions](../../../reference/expr-functions.md) and the `ZZ` row in
[Date tokens](../../../reference/date-tokens.md).

## Sample data

Run it with `bxp-cli --config ./sample.json --template timezone_functions`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/basic/timezone-functions/sample.json"
    ```

=== "sample.csv"

    ```{.csv .bxp-sample}
    --8<-- "examples/basic/timezone-functions/sample.csv"
    ```
