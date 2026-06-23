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
collide. The single-block form shown above is the legacy shape and is
still accepted. See [Config schema](../reference/config-schema.md) for
both forms.

Reach for `pre_pass` **only** for genuine cross-row joins (paired
transaction legs, fee refunds, order/fill pairs). If a row's data is
self-contained, omit it entirely.
