# Space-Grouped Thousands → Number

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/basic/space-thousands){ .md-button }

!!! abstract "What"
    Parse the continental-European number format — space-grouped
    thousands with a **comma** decimal, `"1 234 567,89"` = `1234567.89` — into a
    clean numeric value.

!!! note "Synthetic / teaching example"
    The data here is **constructed**, not sourced
    — `sample.csv` is hand-written amounts in the FR/CZ/SI style. The _problem
    class_ is real; the rows are not.

## Why interesting

French, Czech, Slovenian and many other EU exports group
thousands with a space and use a comma for the decimal point. bxp's built-in
grouped-number handling recognises the _period_-thousands form (`1.234,56`)
automatically, but **not** the space-grouped form — so this is the small idiom
that covers it. (A real cited example of the period-thousands + comma-decimal
form lives in [real-world/french-dvf-realestate](../../real-world/french-dvf-realestate/index.md).)

**Problem class documented in.** (sources for the problem class — not for the data)

- [Decimal separator — Wikipedia](https://en.wikipedia.org/wiki/Decimal_separator)
  documents the space-thousands + comma-decimal convention used across much of
  continental Europe.

## The trick

The key expression (see inline comments in `sample.json`):

```text
REPLACE(REPLACE([Amount], ' ', ''), ',', '.') * 1
```

- strip the space thousands separators (`REPLACE` clears _every_ occurrence, so
  one call handles `1 234 567`);
- swap the decimal comma for a dot;
- `* 1` coerces the result to a real number.

## Final result

```text
1 234 567,89  →  1234567.89
12 500,00     →  12500
1 050,50      →  1050.5
```

Each amount is now a plain number, ready to sum or compare.

## Sample data

Run it with `bxp-cli --config ./sample.json --template space_thousands_clean`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/basic/space-thousands/sample.json"
    ```

=== "sample.csv"

    ```csv
    --8<-- "examples/basic/space-thousands/sample.csv"
    ```
