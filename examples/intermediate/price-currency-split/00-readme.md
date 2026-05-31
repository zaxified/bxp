# Price + Currency Split

[← all examples](../../README.md)

**What.** Split a single mixed-notation `Price` column — `$12.99`, `50.00 EUR`,
`€3.50`, `1,234.00 USD` — into a clean numeric `price` and a separate
`currency` code, using bxp's `PRICE_VALUE` / `PRICE_CURRENCY` builtins.

**Synthetic / teaching example.** The data here is **constructed**, not sourced
— `sample.csv` is hand-written rows engineered to cover the common currency
notations (leading symbol, trailing ISO code, comma thousands, empty). The
*problem class* is real; the rows are not. (Mixed-currency price columns live in
private marketplace/ERP exports with no public dataset.)

**Why interesting.** Prices arrive glued to their currency in a dozen
incompatible shapes — symbol-before (`$`, `€`), code-after (`EUR`, `CZK`), with
or without thousands separators. To `SUM`, convert, or compare them you first
need the bare number and the currency in their own columns. That is normally a
pile of regexes; bxp has a dedicated pair of functions for it.

**Problem class documented in.** (sources for the problem class — not for the data)

- [ISO 4217 currency codes](https://www.iso.org/iso-4217-currency-codes.html) —
  the same amount ships as `$`, `€`, `EUR`, `USD`, … across systems.
- Generic data-cleaning guides repeatedly cover separating currency symbols
  from numeric values before analysis.

**The trick** (see inline comments in `sample.json`):

- `PRICE_CURRENCY([Price])` → the currency code (`$12.99` → `USD`,
  `50.00 EUR` → `EUR`, `€3.50` → `EUR`).
- `PRICE_VALUE([Price])` → the numeric part with the symbol/code removed. It
  leaves the comma thousands in place (`1,234.00`), so wrap it:
  `REPLACE(PRICE_VALUE([Price]), ',', '') * 1` lands a clean number.
- An `IF([Price] = '', '', …)` guard keeps a genuinely empty price empty rather
  than coercing it to `0`.

**Run it.**

```bash
bxp-cli --config ./sample.json --template price_currency_split
```

**Smoking gun.** One ragged column becomes two clean ones:

```text
$12.99        →  12.99   USD
€3.50         →  3.5     EUR
1,234.00 USD  →  1234    USD
(empty)       →  (empty) (empty)
```

`price` is now a real number and `currency` a separate code — ready for FX
conversion or a `GROUP BY currency` total.
