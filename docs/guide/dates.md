---
description: "Parse and reformat dates with DATE_CONVERT, do calendar and business-day arithmetic, and handle time zones."
---

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
that are not tokens are matched literally. Match the input's own shape
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

Every date and time function shares one reader, so a timestamp column
works with `MONTH()` exactly as it works with `HOUR()`: a date function
given a timestamp ignores the time half, and a time function given a bare
date reads midnight. Accepted are `YYYY-MM-DD`, `YYYY-MM-DD hh:mm:ss`, the
`T`-separated variant, and an ISO tail — fractional seconds, `Z`, `±HH:MM` —
which is read and ignored, because these functions work in wall-clock time
and take their zone from another argument.

The reader matches the **whole** value, so `2024-03-15 nonsense` is an
error rather than midnight on the 15th. The functions return ISO
`YYYY-MM-DD`; an empty argument yields `""`, a malformed one errors, and
pre-1970 dates are fully supported.

A few patterns:

```text
WEEKDAY([Date]) > 5                                  → weekend trade
NTH_DOW(YEAR(d), 3, 7, -1) … NTH_DOW(YEAR(d), 10, 7, -1)   → EU DST boundaries
EOMONTH([Date])                                      → month-end snapping
```

See [Expression functions](../reference/expr-functions.md) for
`DATEADD`, `DATEDIFF`, `WORKDAY`, `YEAR` / `MONTH` / `DAY`, `WEEKDAY`,
`EOMONTH`, and `NTH_DOW`.

### Snapping to the start of a period

`EOMONTH` gives you the *end* of a month, and there is no matching
`DATE_TRUNC` — because the starts are already one expression each, and the
one you want depends on the period:

```text
DATE_CONVERT([Date], 'YYYY-MM-DD', 'YYYY-MM') & '-01'   → 2024-08-15 becomes 2024-08-01
DATE_CONVERT([Date], 'YYYY-MM-DD', 'YYYY') & '-01-01'   → 2024-08-15 becomes 2024-01-01
DATEADD([Date], 1 - WEEKDAY([Date]))                    → 2024-08-15 becomes 2024-08-12
```

The week form works because `WEEKDAY` is ISO — Monday is 1 — so subtracting
one less than the weekday always lands on that week's Monday, whichever day
you started from.

Reach for these when a destination groups rows by period: bucket the date
first, then let the tracker aggregate. bxp itself never sums across rows
(see [Not planned](../dev/roadmap.md#not-planned)).

### Bucketing by ISO week

`WEEKNUM` numbers weeks the ISO way, which means the number alone is not
sortable across a year boundary: 2021-01-01 is week **53** (it belongs to
2020's last week) and 2024-12-30 is week **1** (it already belongs to 2025).
Pair it with the year of its own Thursday:

```text
YEAR(DATEADD([Date], 4 - WEEKDAY([Date]))) & '-W' & WEEKNUM([Date])
```
