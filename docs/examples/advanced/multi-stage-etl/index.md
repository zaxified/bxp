# Multi-Stage ETL — chained two-hop JOIN + DST timezone (capstone)

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/advanced/multi-stage-etl){ .md-button }

!!! abstract "What"
    A transitive (two-hop) JOIN that no single pass can do —
    order → product → category → name — chained across passes, while normalising
    three different date formats and bridging CSV ↔ JSON, finishing with a
    DST-aware Europe/Prague timestamp.

!!! note "Synthetic / teaching example"
    The data here is **constructed**, not sourced — `orders.csv` (US `MM/DD/YYYY`),
    `products.csv` (EU `DD.MM.YYYY`), `categories.in.json` (long `YYYYMMDD`). The
    _problem class_ — snowflake relationships, format drift across sources, and
    timezone correctness — is universal; the rows are not.

## Why interesting

Two limits force the chaining: bxp reads **one file per pass**, and runs **one
pre_pass per pass**. The second hop's key (`category_id`) does not exist on an
order until the first hop has run, so it _cannot_ be a single lookup — you
combine, join, combine again, join again. On top of that, the author knows each
source's date convention up front, and the output target is Prague local time
with a correct **summer/winter offset** — which `TZ_OFFSET` resolves from the
bundled IANA tz database in a single call.

```mermaid
flowchart TD
    O["orders.csv<br/><small>US MM/DD/YYYY</small>"] --> C1["1 · combine_op"]
    P["products.csv<br/><small>EU DD.MM.YYYY</small>"] --> C1
    C1 --> J1["2 · join_product — hop 1<br/><small>+category_id · dates → ISO</small>"]
    J1 --> C2["3 · combine_oc<br/><small>+ DST timestamp</small>"]
    CAT["categories.in.json<br/><small>long YYYYMMDD</small>"] --> C2
    C2 --> J2["4 · join_category — hop 2<br/><small>+category_name · created → ISO</small>"]
    J2 --> R["1-final.json"]
```

**Problem class documented in.** (sources for the problem class — not for the data)

- Snowflake-schema multi-hop joins are standard dimensional modelling (Kimball).
- EU DST: clocks switch on the **last Sunday of March / October** (Directive
  2000/84/EC) — the rule `TZ_OFFSET` applies for `Europe/Prague`.

## The trick — four passes, and what each one leaves behind

Run all four at once with `bxp-cli --config ./sample.json` (the template is
heavily commented — open the `sample.json` tab at the bottom). Each pass writes
a real file, and the point of the pipeline is easiest to see by reading those
four files in order. Every one of them is committed and pinned by a golden, so
what you see below is exactly what the run produces.

Each date is normalised in the pass where its source format is known, and the
timestamp is derived only once `order_date` is ISO — so the final join pass
stays free of date math.

### Pass 1 · `combine_op` — stack the two CSVs

`combined_output` writes orders and products into one file, and `_type` is
derived from which key a row has (orders have `order_id`, products do not). A
`pre_pass` reads one file per pass, so the two tables have to share a file
before they can be joined at all.

Nothing is converted yet — both source date formats are still verbatim, US
`01/15/2024` next to EU `02.01.2023`:

```csv title="1-combine_op-combined.csvx"
--8<-- "examples/advanced/multi-stage-etl/1-combine_op-combined.csvx"
```

### Pass 2 · `join_product` — hop 1, order → product

The `pre_pass` indexes the `product` rows by `product_id`; every `order` row then
`LOOKUP`s its `category_id` out of that index. `row_rules` emits only the orders
— the product rows were scaffolding for the lookup, and they disappear here.

This is also where both CSV date formats become ISO, each with the format its
own source uses. Output is JSON so the next pass can stack it with the
categories file:

```json title="1-enriched.in.json"
--8<-- "examples/advanced/multi-stage-etl/1-enriched.in.json"
```

Note what an order now knows that it could not know before: `category_id`. That
is the key the second hop needs, and it did not exist on an order until this
pass ran — which is the whole reason one `pre_pass` cannot do the job.

### Pass 3 · `combine_oc` — stack in the categories, stamp the timestamp

The enriched orders and the categories file are both JSON, so `combined_output`
merges them the same way pass 1 merged the CSVs, `_type` and all.

The DST-aware timestamp is built **here**, not in the final pass, because this
is where `order_date` is already ISO and still present as a field. Watch the
offset follow the season — `+01:00` in January, `+02:00` in July, back to
`+01:00` in November:

```csv title="1-combine_oc-combined.csvx"
--8<-- "examples/advanced/multi-stage-etl/1-combine_oc-combined.csvx"
```

### The Prague offset — one call with `TZ_OFFSET`

PASS 3 tags the ISO order date with its DST-aware Europe/Prague offset — CET
(`+01:00`) in winter, CEST (`+02:00`) in summer. `TZ_OFFSET` reads the correct
offset from the bundled IANA tz database, so daylight-saving time is handled with
no hand-rolled calendar math:

```js
IF(LEN([order_date]) = 0, '',                                          // (1)!
   [order_date] & 'T00:00:00' & TZ_OFFSET([order_date], 'Europe/Prague'))  // (2)!
```

1. Empty-guard — category rows (no `order_date`) and startup validation stay safe.
2. DST-aware `±HH:MM` offset for the date — `+01:00` in January, `+02:00` in July.

??? note "Under the hood — deriving the offset by hand"
    Before the timezone builtins existed you'd compute the same offset from
    calendar primitives. EU clocks switch on the **last Sunday of March /
    October** (Directive 2000/84/EC); `NTH_DOW(YEAR([order_date]), 3, 7, -1)`
    returns the last Sunday of March directly (ISO weekday `7`, occurrence `-1` =
    last), and a `DATEDIFF` in-window test picks the summer or winter offset:

    ```js
    IF(DATEDIFF([order_date], NTH_DOW(YEAR([order_date]), 3, 7, -1)) >= 0
       AND DATEDIFF([order_date], NTH_DOW(YEAR([order_date]), 10, 7, -1)) < 0,
       '+02:00', '+01:00')
    ```

    `TZ_OFFSET([order_date], 'Europe/Prague')` gives the identical result in one
    call. The dedicated
    [timezone-functions example](../../basic/timezone-functions/index.md) walks
    through all four TZ builtins (`TO_UTC` / `TZ_OFFSET` / `IS_DST` / `TZ_CONVERT`).

### Pass 4 · `join_category` — hop 2, category → name

The last pass indexes the `category` rows and resolves `category_name` plus the
`created` date (long `YYYYMMDD` → ISO). Because passes 2 and 3 did the format
work, this one is pure lookup and passthrough — see **Final result** below.

## Final result

Three orders, three source date formats, two join hops, and a timezone that
flips with the season — one clean JSON dataset. An order arrives knowing only a
`product_id` and a US date, and leaves knowing its category's **name** and its
own Prague instant:

```text
order 1001   product_id P-9   order_date 01/15/2024   (that is all it knew)
             ↓ hop 1 · category_id C-3      ↓ hop 2 · category_name Electronics
             order_ts 2024-01-15T00:00:00+01:00   category_created 2020-01-15
```

Watch `order_ts` across the three orders: `+01:00` in January, **`+02:00` in
July**, back to `+01:00` in November — one `TZ_OFFSET` call, no calendar
arithmetic. The whole three-object result is in the
**`1-final.json (result)`** tab below (bxp writes one compact object per line).

## Sample data

Run it with `bxp-cli --config ./sample.json` — the three inputs and the full
commented template:

=== "sample.json (config)"

    ```js
    --8<-- "examples/advanced/multi-stage-etl/sample.json"
    ```

=== "orders.csv"

    ```{.csv .bxp-sample}
    --8<-- "examples/advanced/multi-stage-etl/orders.csv"
    ```

=== "products.csv"

    ```csv
    --8<-- "examples/advanced/multi-stage-etl/products.csv"
    ```

=== "categories.in.json"

    ```json
    --8<-- "examples/advanced/multi-stage-etl/categories.in.json"
    ```

=== "1-final.json (result)"

    ```json
    --8<-- "examples/advanced/multi-stage-etl/1-final.json"
    ```
