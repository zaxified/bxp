# Null Variants → Empty

[← all examples](../../README.md)

**What.** Fold every "no value" spelling — `NULL`, `NA`, `N/A`, `n/a`, `None`,
`"-"` — into a single genuine empty cell, while leaving real values untouched.

**Synthetic / teaching example.** The data here is **constructed**, not sourced
— `sample.csv` is hand-written rows planting the common null markers across a
few columns. The *problem class* is real and universal; the rows are not.

**Why interesting.** When data passes through several systems, "missing" gets
written a dozen incompatible ways. Imported verbatim, the literal text `"N/A"`
is *not* empty: it inflates `COUNT`s, breaks joins on the column, sorts as a
real value, and clutters dropdowns. Normalising all of them to one empty cell
up front is the first step of almost every cleanup.

**Problem class documented in.** (sources for the problem class — not for the data)

- [pandas `na_values`](https://pandas.pydata.org/docs/reference/api/pandas.read_csv.html)
  exists precisely because CSVs encode missing values as `NA`, `N/A`, `null`,
  `None`, `-`, … and each must be mapped to a true blank.

**The trick** (see inline comments in `sample.json`):

```text
IF(IN(TRIM([Email]), 'NULL', 'NA', 'N/A', 'n/a', 'None', 'none', '-'), '', TRIM([Email]))
```

- `IN(value, …)` is a **function** in bxp — `IN(val, a, b, …)` — testing the
  value against a list of markers (not SQL `value IN (…)` infix).
- `TRIM` first, so `" NA "` with stray spaces still matches.
- Match → `''`; otherwise keep the trimmed value. The same guard drops onto
  every dirty column.

**Smoking gun.** Bob's `N/A` email and `NULL` note, Carol's `-` phone and `None`
note, Dave's `NA`/`n/a` all become truly empty — while `follow up next week`
and the real emails survive:

```text
Bob,,555-9999,
Carol,carol@example.com,,
Dave,,,follow up next week
```

Now an `email IS NULL` filter or a `COUNT(phone)` means what it says.
