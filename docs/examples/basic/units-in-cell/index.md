# Units-in-Cell → Number + Unit

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/basic/units-in-cell){ .md-button }

!!! abstract "What"
    Split a measurement column that glues a number to its unit —
    `5.0 kg`, `250 g`, `1.5 L`, `12 pcs` — into a clean numeric `amount` and a
    separate `unit` column.

!!! note "Synthetic / teaching example"
    The data here is **constructed**, not sourced
    — `sample.csv` is hand-written rows covering a few unit shapes plus a blank. The
    _problem class_ is real; the rows are not.

## Why interesting

Quantities routinely ship as `"<number> <unit>"` in one
cell (ingredient lists, lab readings, product specs). You can't `SUM` weights or
convert units while the text `kg` is fused to the number — every arithmetic op
throws. Separating the value from the unit is the prerequisite for any
calculation.

**Problem class documented in.** (sources for the problem class — not for the data)

- Tidy-data guidance (e.g. [Wickham, _Tidy Data_](https://vita.had.co.nz/papers/tidy-data.pdf))
  calls a value-plus-unit-in-one-cell a classic "one column, two variables"
  problem to be split before analysis.

## The trick

See inline comments in `sample.json`:

```text
amount: IF(LEN(TRIM([Measure])) = 0, '', SPLIT_PART([Measure], ' ', 1) * 1)
unit:   SPLIT_PART([Measure], ' ', 2)
```

- `SPLIT_PART(…, ' ', 1)` takes the number, `* 1` makes it a real numeric.
- `SPLIT_PART(…, ' ', 2)` takes the unit token.
- `LEN(TRIM([Measure])) = 0` keeps a blank cell empty rather than coercing it
  to `0` (a length test, so it doesn't itself coerce a real `"0"`).

## Final result

One fused column becomes two clean ones:

```text
5.0 kg  →  5    kg
1.5 L   →  1.5  L
12 pcs  →  12   pcs
(blank) →  (empty) (empty)
```

`amount` is now summable and `unit` group-able — ready for a `GROUP BY unit` or
a unit-conversion step.

## Sample data

Run it with `bxp-cli --config ./sample.json --template units_in_cell_split`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/basic/units-in-cell/sample.json"
    ```

=== "sample.csv"

    ```csv
    --8<-- "examples/basic/units-in-cell/sample.csv"
    ```
