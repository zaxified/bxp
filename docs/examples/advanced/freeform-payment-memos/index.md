# Free-Text Payment Memos → Structured References

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/advanced/freeform-payment-memos){ .md-button }

!!! abstract "What"
    Pull the structured tokens a downstream ledger needs — an invoice
    number, an order reference, a has-any-reference flag — out of **free-text**
    payment memos, where each token sits at a _variable_ position inside an
    otherwise human-written sentence. Done with `REGEX_EXTRACT` / `REGEX_MATCH`,
    which match by **shape, anywhere** in the string.

!!! note "Synthetic / teaching example"
    The data is **constructed**, not
    sourced — `sample.csv` is hand-written memos that pack a moving-target token
    into a sentence. The _problem class_ — bank / PSP / ERP exports whose only
    machine-readable handle is a free-text "reference" or "memo" field — is
    universal; the rows are not.

## Why interesting

This is the one extraction job the cheaper string tools
**cannot express**. `SPLIT_PART` needs a stable delimiter at a fixed position;
`CONTAINS` only tests presence; `IN` / `REMAP` only match whole values. When the
invoice number can appear as `"Payment for INV-2024-0042 thank you"` in one row
and `"Refund INV-2023-0911 order #88 processed"` in the next, only a pattern
match pinned to the token's _shape_ reaches it. The example also teaches the
flip side: the `Tags` column is cleanly `a|b|c`-delimited, so its first tag is a
plain `SPLIT_PART` — reaching for regex there would be paying the engine for a
job a delimiter split already does.

## The trick

(see `sample.json`)

1. **Capture group** — `REGEX_EXTRACT([Memo], 'INV-([0-9]{4}-[0-9]{4})')`{.bxp-try}
   returns just the inner `YYYY-NNNN` (the group), dropping the `INV-` literal;
   no match → `""`.
2. **Different anchor** — `REGEX_EXTRACT([Memo], '#([0-9]+)')`{.bxp-try} pulls the order
   number that follows a `#`, wherever it lands.
3. **Alternation gate** — `REGEX_MATCH([Memo], 'INV-[0-9]{4}|#[0-9]+')`{.bxp-try} answers
   "does this memo carry _any_ structured reference" in a single pass; `CONTAINS`
   would need two calls and would still accept a bare `INV-` with no digits.
4. **Cost-hierarchy contrast** — `SPLIT_PART([Tags], '|', 1)`{.bxp-try} for the
   already-delimited tag. No regex on purpose.

The cost ladder is deliberate: `IN`/`REMAP` (hash) < `CONTAINS`/`REPLACE`
(literal scan) < regex (pattern engine). Pick the cheapest tool that does the
job; regex earns its keep only on a real pattern the others cannot phrase.

## Final result

A pile of free-text memos —

```text
T001,Payment for INV-2024-0042 thank you,priority|cleared|eu
T005,Refund INV-2023-0911 order #88 processed,low|cleared|us
T003,Card settlement no reference here,normal|pending|us
```

— becomes a clean, joinable reference table, each token lifted out by shape:

```text
T001,2024-0042,,true,priority
T005,2023-0911,88,true,low
T003,,,false,normal
```

## At full scale

Regex is the most expensive rung of the
ladder, so it is worth knowing the price. On this same workload — but scaled to
**1,000,000 synthetic memo rows (~62 MB)** — the regex template (two
`REGEX_EXTRACT` + one `REGEX_MATCH` per row) was measured against a
literal-only template that produces **byte-identical output** by leaning on the
stable `INV-` / `#` anchors (`CONTAINS` + nested `SPLIT_PART`):

| Template (1M rows)                         | Wall   | Peak RSS | Throughput   |
| ------------------------------------------ | ------ | -------- | ------------ |
| regex (2× `REGEX_EXTRACT` + `REGEX_MATCH`) | ~2.4 s | ~23 MB   | ~415k rows/s |
| cheap (`CONTAINS` + `SPLIT_PART`)          | ~1.3 s | ~23 MB   | ~790k rows/s |

So the regex path costs roughly **1.9× the wall time** here — about **+1 µs per
row** for the three pattern ops — while **peak RSS is flat** (the Pike-VM engine
is window/arena-bounded, with no per-row growth). The takeaway matches the cost
ladder above: regex is cheap enough to use freely when you _need_ shape
matching, and still worth skipping when a delimiter split or a literal
`CONTAINS` already answers the question.

Reproduce it — the 1M-row file is generated rather than committed, so this
directory ships only the six-row teaching slice:

```bash
bash make-full.sh                 # writes ./full/memos.csv (~62 MB)
bxp-cli --config full.json        # the regex template
bxp-cli --config full-cheap.json  # the literal-only template
diff full/memos.csvx full/memos-cheap.csvx && echo identical
```

The `diff` is not decoration: a timing comparison between two templates only
means anything once they are proven to produce the same answer.

> Methodology: best of five interleaved runs, `bxp-cli` built `ReleaseFast`,
> `BXP_METRICS=1` self-reported wall + peak RSS. Absolute milliseconds vary by
> machine; the ratio and the flat-RSS shape are the portable takeaways.
>
> Note what the cheap template needs and the teaching slice deliberately
> withholds: **stable literal anchors**. `make-full.sh` emits memos that always
> spell `INV-` and `#`, which is what lets `CONTAINS` + `SPLIT_PART` reach the
> tokens at all. Free text in the wild does not promise that — which is the
> reason the example itself uses regex.

## Sample data

Run it with `bxp-cli --config ./sample.json --template freeform_payment_memos`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/advanced/freeform-payment-memos/sample.json"
    ```

=== "sample.csv"

    ```{.csv .bxp-sample}
    --8<-- "examples/advanced/freeform-payment-memos/sample.csv"
    ```

=== "sample.csvx (result)"

    ```csv
    --8<-- "examples/advanced/freeform-payment-memos/sample.csvx"
    ```

**Scale files** (the 1M-row cost comparison): [`make-full.sh`](https://github.com/zaxified/bxp/tree/master/docs/examples/advanced/freeform-payment-memos/make-full.sh) · [`full.json`](https://github.com/zaxified/bxp/tree/master/docs/examples/advanced/freeform-payment-memos/full.json) · [`full-cheap.json`](https://github.com/zaxified/bxp/tree/master/docs/examples/advanced/freeform-payment-memos/full-cheap.json).
