# Space-Grouped Thousands → Number

[← all examples](../../README.md)

**What.** Parse the continental-European number format — space-grouped
thousands with a **comma** decimal, `"1 234 567,89"` = `1234567.89` — into a
clean numeric value.

**Synthetic / teaching example.** The data here is **constructed**, not sourced
— `sample.csv` is hand-written amounts in the FR/CZ/SI style. The *problem
class* is real; the rows are not.

**Why interesting.** French, Czech, Slovenian and many other EU exports group
thousands with a space and use a comma for the decimal point. bxp's built-in
grouped-number handling recognises the *period*-thousands form (`1.234,56`)
automatically, but **not** the space-grouped form — so this is the small idiom
that covers it. (A real cited example of the period-thousands + comma-decimal
form lives in [real-world/french-dvf-realestate](../../real-world/french-dvf-realestate/00-readme.md).)

**Problem class documented in.** (sources for the problem class — not for the data)

- [Decimal separator — Wikipedia](https://en.wikipedia.org/wiki/Decimal_separator)
  documents the space-thousands + comma-decimal convention used across much of
  continental Europe.

**The trick** (see inline comments in `sample.json`):

```text
REPLACE(REPLACE([Amount], ' ', ''), ',', '.') * 1
```

- strip the space thousands separators (`REPLACE` clears *every* occurrence, so
  one call handles `1 234 567`);
- swap the decimal comma for a dot;
- `* 1` coerces the result to a real number.

**Run it.**

```bash
bxp-cli --config ./sample.json --template space_thousands_clean
```

**Smoking gun.**

```text
1 234 567,89  →  1234567.89
12 500,00     →  12500
1 050,50      →  1050.5
```

Each amount is now a plain number, ready to sum or compare.
