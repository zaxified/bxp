---
description: "Send one input row to zero, one or several output rows with row_rules, and set the activity type per branch."
---

# Row routing (`row_rules`)

After `input_schema` has computed a row's `$variable`s, each row is
routed through the ordered `row_rules` list. **The first rule whose
`when` condition matches wins** and decides:

- the row's activity type (`$action`, which must be set here, never in
  `input_schema`), and
- how many output rows the input row produces — `0`, `1`, or `N`.

```json5
row_rules: [
  { when: "[Action] = 'Buy'",      rows: [ { $action: "'BUY'"  } ] },
  { when: "[Action] = 'Sell'",     rows: [ { $action: "'SELL'" } ] },
  { when: "[Action] = 'Deposit'",  rows: [ { $action: "'DEPOSIT'"  } ] },
  // ignored row types: match them and emit nothing
  { when: "[Action] = 'Statement'", rows: [] },
],
```

- `rows: []` — **silent skip**: the row matched a rule but produces no
  output. Use it to deliberately drop row types you don't want.
- `rows: [ {...} ]` — one output row, with optional per-rule
  `$variable` overrides on top of the `input_schema` values.
- `rows: [ {...}, {...}, {...} ]` — **one-to-many**: a single input row
  fans out to several output rows (e.g. a currency conversion that
  becomes FEE + WITHDRAWAL + DEPOSIT). Each object overrides
  `$variables` for that specific output row.

## Matching conventions

Prefer explicit `IN(...)` / exact equality on the action column rather
than `CONTAINS` / `STARTS_WITH` — an exact match is forward-safe against
a source introducing a new code that happens to share a prefix.
See the [Expressions gotchas](expressions.md#function-semantics--common-gotchas).

## Unmatched rows

Set `row_rules_debug_missing: true` and run with `--debug` (CLI) or
`dry-run` (GUI) to surface rows that no rule matched — the usual sign of
a missing or mistyped `when` condition.

The two ways non-trade rows (deposits, fees, dividends) are typically
shaped — centralised in `input_schema` versus per-rule overrides — are
described in [Target specs → Non-trade row patterns](targets.md#non-trade-row-patterns).
