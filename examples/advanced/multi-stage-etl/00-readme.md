# Multi-Stage ETL — chained two-hop JOIN + DST timezone (capstone)

[← all examples](../../README.md)

**What.** A transitive (two-hop) JOIN that no single pass can do —
order → product → category → name — chained across passes, while normalising
three different date formats and bridging CSV ↔ JSON, finishing with a
DST-aware Europe/Prague timestamp.

**Synthetic / teaching example.** The data here is **constructed**, not sourced
— `orders.csv` (US `MM/DD/YYYY`), `products.csv` (EU `DD.MM.YYYY`),
`categories.in.json` (long `YYYYMMDD`). The *problem class* — snowflake
relationships, format drift across sources, and timezone correctness — is
universal; the rows are not.

**Why interesting.** Two limits force the chaining: bxp reads **one file per
pass**, and runs **one pre_pass per pass**. The second hop's key
(`category_id`) does not exist on an order until the first hop has run, so it
*cannot* be a single lookup — you combine, join, combine again, join again.
On top of that, the author knows each source's date convention up front, and the
output target is Prague local time with a correct **summer/winter offset** — which
the engine has no built-in timezone for, yet it's still computable.

**Problem class documented in.** (sources for the problem class — not for the data)

- Snowflake-schema multi-hop joins are standard dimensional modelling (Kimball).
- EU DST: clocks switch on the **last Sunday of March / October** (Directive
  2000/84/EC) — the rule the `$order_ts` expression encodes.

**The trick** (see the heavily-commented `sample.json`) — four passes, run all at
once with `bxp-cli --config ./sample.json`:

1. `combine_op` — stack orders + products (`combined_output`, `_type` from key
   presence) so a pre_pass can see both.
2. `join_product` (hop 1) — index products, attach `category_id`; convert
   `order_date` US→ISO and `added_date` EU→ISO. Output JSON.
3. `combine_oc` — stack the enriched orders (JSON) with categories (JSON), and
   build the **DST-aware** timestamp here, where `order_date` is already ISO.
4. `join_category` (hop 2) — index categories, attach `category_name` and
   `created` (long→ISO); pure lookup + passthrough, no date math.

Each date is normalised in the pass where its source format is known
(`order_date` US→ISO and `added_date` EU→ISO in PASS 2, `created` long→ISO in
PASS 4), and the timestamp is derived once `order_date` is ISO — so the final
join pass stays clean.

**Computing the Prague offset with no timezone support** (PASS 3). CEST
(`+02:00`) holds from the last Sunday of March to the last Sunday of October,
else CET (`+01:00`).
"Last Sunday of month" = `EOMONTH` minus its ISO weekday mod 7 (mod done as
`x - 7*FLOOR(x/7)`, since there is no `MOD`); the in-window test uses `DATEDIFF`
(numeric) because `>=` is unsupported on date strings.

> Caveat: the offset is computed at **date** granularity, so the exact switch
> hour on the transition day is not modelled — fine for date-stamped data. A
> first-class `TZ_OFFSET`/zone feature is on the roadmap.

**Run it.**

```bash
bxp-cli --config ./sample.json
```

**Smoking gun.** Three orders, three source date formats, two join hops, and a
timezone that flips with the season — one clean JSON dataset. Note `order_ts`:
`+01:00` in January and November, `+02:00` in July:

```json
[
{"order_id":"1001","product_id":"P-9","category_id":"C-3","category_name":"Electronics","order_ts":"2024-01-15T00:00:00+01:00","product_added":"2023-01-02","category_created":"2020-01-15"},
{"order_id":"1002","product_id":"P-7","category_id":"C-1","category_name":"Books","order_ts":"2024-07-20T00:00:00+02:00","product_added":"2023-06-15","category_created":"2019-12-20"},
{"order_id":"1003","product_id":"P-9","category_id":"C-3","category_name":"Electronics","order_ts":"2024-11-02T00:00:00+01:00","product_added":"2023-01-02","category_created":"2020-01-15"}
]
```
