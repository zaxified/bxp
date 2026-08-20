---
description: "Join a row to other rows in the same file with pre_pass and LOOKUP, including multiple named lookup tables."
---

# Cross-row joins (`pre_pass`)

Use `pre_pass` when an input row needs data that lives on **another
row** (for example, Anycoin writes `trade payment` and `trade fill` as
two rows sharing an `Order ID`). bxp-cli makes a first pass over the
file, collects rows matching `when`, and stores `values` under `key`.
Then `input_schema` can read them via `LOOKUP(key, 'field')`.

```json5
pre_pass: {
  when:   "[Type] = 'trade payment'",      // which rows to collect
  key:    "[Order ID]",                    // expression used as the lookup key
  values: {
    amount:   "ABS([Amount])",             // accessed as LOOKUP(..., 'amount')
    currency: "[Currency]",                // accessed as LOOKUP(..., 'currency')
  },
},

input_schema: {
  $unitprice: "LOOKUP([Order ID], 'amount') / [Amount]",
  $currency:  "LOOKUP([Order ID], 'currency')",
},
```

Note: keys inside `values` are **plain field names**, not `$variables`,
and they are not visible to `row_rules` or `output_schema` directly —
only through `LOOKUP()`.

## Named pre_pass blocks

A template may declare several named `pre_pass` blocks; each block name
becomes part of the `LOOKUP` namespace, so different blocks cannot
collide. Wrap each block under its own name and reach into it with the
**3-argument** `LOOKUP('block_name', key, 'field')`:

```json5
pre_pass: {
  fills: {                                   // block name = first LOOKUP arg
    when:   "[Type] = 'trade fill'",
    key:    "[Order ID]",
    values: { qty: "[Amount]" },             // read as LOOKUP('fills', ..., 'qty')
  },
  fx: {
    when:   "[Type] = 'fx rate'",
    key:    "[Order ID]",
    values: { rate: "[Rate]" },              // read as LOOKUP('fx', ..., 'rate')
  },
},

input_schema: {
  $quantity: "LOOKUP('fills', [Order ID], 'qty')",
  $fxRate:   "LOOKUP('fx', [Order ID], 'rate')",
},
```

Extra blocks are free in I/O terms: the first pass reads the input file once
and fills every block on that single sweep, so a template with four blocks
still reads the file exactly twice in total.

The single-block form shown above is the legacy shape — it uses the
2-argument `LOOKUP(key, 'field')`, works only while exactly one block is
defined, and is still accepted. See
[Config schema](../reference/config-schema.md) for both forms.

Reach for `pre_pass` **only** for genuine cross-row joins (paired
transaction legs, fee refunds, order/fill pairs). If a row's data is
self-contained, omit it entirely.
