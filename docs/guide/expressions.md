---
description: "The expression language: field references, operators, precedence, type coercion and the built-in functions."
---

# Expressions

Expressions are strings evaluated once per row, used in `input_schema`
(to compute `$variable`s) and in `row_rules` `when` conditions. The
full function list lives in [Expression
functions](../reference/expr-functions.md); this page covers syntax,
operators, and the gotchas worth knowing before you write one.

## Operator precedence

High → low:

```text
unary -    →    * /    →    & (concat)    →    + -    →    = != < > <= >=    →    NOT    →    AND    →    OR
```

## Column and literal syntax

| Syntax         | Description                                                    |
| -------------- | -------------------------------------------------------------- |
| `[ColumnName]` | Raw CSV field by header name (leading/trailing spaces trimmed) |
| `FIELDS(n)`    | Raw CSV field by 1-based column **position**                   |
| `'text'`       | String literal                                                 |
| `123`, `-0.5`  | Numeric literal                                                |
| `&`            | String concatenation (`'$CASH-' & [Currency]`)                 |
| `$variable`    | Reference to a variable set earlier in `input_schema`          |

Column header names may contain spaces, parentheses, currency symbols,
and other punctuation — `[Price ($)]`, `[Run Date]`, and
`[Stamp duty reserve tax]` are all valid references. The bracket
syntax preserves the header verbatim; only the closing `]` itself is
reserved.

**Brackets are a name lookup, never a position.** `[2]` asks for a column
whose header is literally `2`; it does not read the second column, and it
silently yields `""` when no such header exists. Use `FIELDS(2)` to reach a
column by position — that is also the only way in on headerless input
(`csv_header_line: 0`).

Function names are case-insensitive.

## Function semantics — common gotchas

- **`CONTAINS(s, sub)` is a substring match, not a prefix match.** It
  returns `true` whenever `sub` appears _anywhere_ inside `s`, which
  means `CONTAINS('Sell to Buy', 'Buy')` is `true`. Brokers with
  prefix-based action codes (Schwab `MKT BUY` / `LMT BUY`, IBKR
  multi-word actions) need an exact or word-boundary check: prefer
  exact comparison (`[Action] = 'Buy'`), `SPLIT_PART([Action], ' ', 1) = 'Buy'`
  for the first word, or excluding the false matches explicitly —
  `CONTAINS([Action], 'Buy') AND NOT CONTAINS([Action], 'Sell')` is a valid
  expression (`NOT` binds tighter than `AND`, see the precedence above) and is
  `false` for `Sell to Buy`.
- **`SPLIT_PART(s, delim, n)` is 1-based and returns `""` on out-of-range.**
  Out-of-range never errors — silent empty makes it safe to chain but
  hides off-by-one bugs. Trace the variable in `bxp-gui` if the output
  is empty unexpectedly.

## Type coercions

- Empty string → `0` in a numeric context.
- Any non-empty string → `true` in a boolean context; empty string → `false`.
- Numeric strings are parsed on demand; `csv_decimal_separator_in`
  controls which decimal separator is accepted (see [Numbers and
  encoding](numbers-and-encoding.md)).
- American thousands-separated numbers (`1,234.56`, `-1,234,567`) are
  automatically parsed in arithmetic contexts; the original string is
  preserved when the field is passed through as-is to output.

## Minimal examples

```text
'$CASH-' & [Currency]                                          → string concat
IF([Type] = 'Buy', 'BUY', IF([Type] = 'Sell', 'SELL', ''))     → nested conditional
[Action] = 'Buy' OR CONTAINS([Action], 'Buy to')               → match action variants
ROUND(ABS([Total]) / [Quantity], 4)                            → derived unit price
DATE_CONVERT([Date], 'DD/MM/YYYY hh:mm:ss', 'YYYY-MM-DD hh:mm:ss')
LOOKUP([Order ID], 'amount') / [Amount]                        → cross-row join via pre_pass
PRICE_VALUE([Price])                                           → strip currency symbol
SPLIT_PART([Comment], ' @ ', 2)                                → second part after " @ "
[Commission ($)] + [Fees ($)]                                  → sum two raw numeric columns
```

## Worked example — a ticker hidden in free text

Some brokers leave the `Symbol` column empty and name the instrument only
inside a free-text field: a dividend row reads
`Description: "Qualified Dividend APPLE INC 100"` with no ticker column at all.
Two composable functions cover this without a new builtin.

**`REGEX_EXTRACT` isolates the company name.** It is a run of ALL-CAPS words,
so a pattern matching one-or-more upper-case words skips the Title-case prefix
and the trailing count on its own:

```text
REGEX_EXTRACT([Description], '[A-Z]{2,}(?: [A-Z]{2,})*')     → APPLE INC
```

The group is **non-capturing** `(?:…)` on purpose. A capturing `(…)` under a
repeat makes `REGEX_EXTRACT` return only the last repetition — one word
instead of the whole name.

**`REMAP` turns that name into a ticker**, via a named `maps` entry keyed on
the company name. Maps can key on anything, not just an existing symbol:

```json5
maps: { company_names: { "APPLE INC": "AAPL", "TESLA INC": "TSLA" } },
```

Combined into one `$ticker` expression:

```text
REMAP(REGEX_EXTRACT([Description], '[A-Z]{2,}(?: [A-Z]{2,})*'), 'company_names')
```

If the field holds *only* the company name, skip the regex and use
`REMAP([Description], 'company_names')` directly — `REMAP` is a whole-value
match, so the field has to equal a key exactly.
