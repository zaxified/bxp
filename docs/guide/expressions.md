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
  for the first word, or a more specific positive match.
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
