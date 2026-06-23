# Dates

BXP parses and reformats dates with `DATE_CONVERT(s, from, to)`, and does
calendar arithmetic with `DATEADD`, `DATEDIFF`, `WORKDAY`, and the
component functions. The complete token table is in [Date
tokens](../reference/date-tokens.md); the arithmetic functions are in
[Expression functions](../reference/expr-functions.md). This page covers
how to use them and the gotchas.

## `DATE_CONVERT`

```text
DATE_CONVERT([Date], 'DD/MM/YYYY hh:mm:ss', 'YYYY-MM-DD hh:mm:ss')
```

Both the `from` and `to` arguments use the same token set. Any characters
that are not tokens are matched literally. Match the broker's input shape
**character-by-character**; use `[*]` to skip fractional seconds, a
trailing `Z`, or a timezone suffix.

### Worked examples

```text
"26 Jun 2022, 16:02:36"       →  'DD MMM YYYY, hh:mm:ss'
"2024-02-23T06:20:20.182Z"    →  'YYYY-MM-DDThh:mm:ss[*]'   (skips .182Z)
"07/03/2026 14:05:00"         →  'DD/MM/YYYY hh:mm:ss'
"2026-01-05 05:20:18"         →  'YYYY-MM-DD hh:mm:ss'      (canonical output)
```

### Gotchas

- `mm` is minute; `MM` is month — easy to mix up.
- `MMM` expects exactly 3 characters; 4-character variants like `Sept`
  and `June` are pre-normalized automatically.
- Dates before 1970 are fully supported — birthdates, census, and
  archival dates convert losslessly.
- Components not present in the `from` format default to
  `1970-01-01 00:00:00`.

## Date arithmetic

All date-arithmetic functions take/return ISO `YYYY-MM-DD` strings; an
empty date argument yields `""`, a malformed one errors. Pre-1970 dates
are fully supported.

A few patterns:

```text
WEEKDAY([Date]) > 5                                  → weekend trade
NTH_DOW(YEAR(d), 3, 7, -1) … NTH_DOW(YEAR(d), 10, 7, -1)   → EU DST boundaries
EOMONTH([Date])                                      → month-end snapping
```

See [Expression functions](../reference/expr-functions.md) for
`DATEADD`, `DATEDIFF`, `WORKDAY`, `YEAR` / `MONTH` / `DAY`, `WEEKDAY`,
`EOMONTH`, and `NTH_DOW`.
