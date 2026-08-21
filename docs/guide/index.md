---
description: "The user guide: how a conversion template is put together, and one page per thing that makes real data hard."
---

# Guide

A conversion is one template: where the files are, how to read a row, and what
to write out. [Templates](templates.md) covers that shape end to end and is the
page to read first — the rest of the section each take one part of it further.

## The language

- [Expressions](expressions.md) — field references, operators, precedence,
  coercion, and the built-in functions.
- [Dates](dates.md) — parsing and reformatting with `DATE_CONVERT`, calendar
  and business-day arithmetic, time zones.
- [Numbers and encoding](numbers-and-encoding.md) — exact fixed-point
  arithmetic, European separators, legacy character encodings.

## Shaping the output

- [Row routing](row-routing.md) — sending one input row to zero, one or several
  output rows, and setting the activity type per branch.
- [Cross-row joins](cross-row-joins.md) — `pre_pass` and `LOOKUP`, when a row
  needs a value that lives in another row.
- [Targets](targets.md) — the `output_schema` each supported tracker expects,
  and how to write one for a tracker that is not listed.

## Running it

- [Running](running.md) — selecting templates, overriding the data directory,
  dry runs, exit codes.

Every function named here has a one-line entry in the
[expression reference](../reference/expr-functions.md), and every configuration
key in the [config schema](../reference/config-schema.md). The guide explains
*when*; the reference answers *what exactly*.
