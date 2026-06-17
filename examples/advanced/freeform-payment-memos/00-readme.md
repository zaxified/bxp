# Free-Text Payment Memos → Structured References

[← all examples](../../README.md)

**What.** Pull the structured tokens a downstream ledger needs — an invoice
number, an order reference, a has-any-reference flag — out of **free-text**
payment memos, where each token sits at a *variable* position inside an
otherwise human-written sentence. Done with `REGEX_EXTRACT` / `REGEX_MATCH`,
which match by **shape, anywhere** in the string.

**Synthetic / teaching example (advanced).** The data is **constructed**, not
sourced — `sample.csv` is hand-written memos that pack a moving-target token
into a sentence. The *problem class* — bank / PSP / ERP exports whose only
machine-readable handle is a free-text "reference" or "memo" field — is
universal; the rows are not.

**Why interesting.** This is the one extraction job the cheaper string tools
**cannot express**. `SPLIT_PART` needs a stable delimiter at a fixed position;
`CONTAINS` only tests presence; `IN` / `REMAP` only match whole values. When the
invoice number can appear as `"Payment for INV-2024-0042 thank you"` in one row
and `"Refund INV-2023-0911 order #88 processed"` in the next, only a pattern
match pinned to the token's *shape* reaches it. The example also teaches the
flip side: the `Tags` column is cleanly `a|b|c`-delimited, so its first tag is a
plain `SPLIT_PART` — reaching for regex there would be paying the engine for a
job a delimiter split already does.

**The trick** (see `sample.json`):

1. **Capture group** — `REGEX_EXTRACT([Memo], 'INV-([0-9]{4}-[0-9]{4})')`
   returns just the inner `YYYY-NNNN` (the group), dropping the `INV-` literal;
   no match → `""`.
2. **Different anchor** — `REGEX_EXTRACT([Memo], '#([0-9]+)')` pulls the order
   number that follows a `#`, wherever it lands.
3. **Alternation gate** — `REGEX_MATCH([Memo], 'INV-[0-9]{4}|#[0-9]+')` answers
   "does this memo carry *any* structured reference" in a single pass; `CONTAINS`
   would need two calls and would still accept a bare `INV-` with no digits.
4. **Cost-hierarchy contrast** — `SPLIT_PART([Tags], '|', 1)` for the
   already-delimited tag. No regex on purpose.

The cost ladder is deliberate: `IN`/`REMAP` (hash) < `CONTAINS`/`REPLACE`
(literal scan) < regex (pattern engine). Pick the cheapest tool that does the
job; regex earns its keep only on a real pattern the others cannot phrase.

**Run it.**

```bash
bxp-cli --config ./sample.json --template freeform_payment_memos
```

**Smoking gun.** A pile of free-text memos —

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

**Cost — regex vs. the cheaper tools.** Regex is the most expensive rung of the
ladder, so it is worth knowing the price. On this same workload — but scaled to
**1,000,000 synthetic memo rows (~62 MB)** — the regex template (two
`REGEX_EXTRACT` + one `REGEX_MATCH` per row) was measured against a
literal-only template that produces **byte-identical output** by leaning on the
stable `INV-` / `#` anchors (`CONTAINS` + nested `SPLIT_PART`):

| Template (1M rows)                          | Wall   | Peak RSS | Throughput   |
| ------------------------------------------- | ------ | -------- | ------------ |
| regex (2× `REGEX_EXTRACT` + `REGEX_MATCH`)  | ~2.4 s | ~23 MB   | ~415k rows/s |
| cheap (`CONTAINS` + `SPLIT_PART`)           | ~1.3 s | ~23 MB   | ~790k rows/s |

So the regex path costs roughly **1.9× the wall time** here — about **+1 µs per
row** for the three pattern ops — while **peak RSS is flat** (the Pike-VM engine
is window/arena-bounded, with no per-row growth). The takeaway matches the cost
ladder above: regex is cheap enough to use freely when you *need* shape
matching, and still worth skipping when a delimiter split or a literal
`CONTAINS` already answers the question.

> Methodology: best of five interleaved runs, `bxp-cli` built `ReleaseFast`,
> `BXP_METRICS=1` self-reported wall + peak RSS. Absolute milliseconds vary by
> machine; the ratio and the flat-RSS shape are the portable takeaways. The
> 1M-row file is generated, not committed — this directory ships only the
> six-row teaching slice.
