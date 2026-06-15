# Mixed-Format Bridge (CSV batch + JSON batch → one dataset)

[← all examples](../../README.md)

**What.** Combine records that arrive in **two different file formats** — an old
CSV batch and a new JSON batch of the same kind of data — into one unified table.

**Synthetic / teaching example.** The data here is **constructed**, not sourced.
`legacy.csv` (US dates `MM/DD/YYYY`, US-grouped amounts `"1,250.50"`) and
`modern.in.json` (different key names, ISO dates). The _problem class_ — a feed
that migrated from CSV to JSON while the old files still matter — is universal;
the rows are not.

**Why interesting.** A template reads **one input format** (CSV _or_ JSON), so a
mixed-format pile can't be done in a single pass. The fix is one pass per format
into the _same_ `output_schema`, then a fan-in pass to stack the normalised
results — bridging formats without leaving bxp or hand-writing a merge script.

**Problem class documented in.** (sources for the problem class — not for the data)

- Feed/API format migrations (CSV→JSON, v1→v2) are routine; historical batches
  in the old format have to be bridged to the new pipeline schema — a standard
  data-engineering backfill task.

**The trick** (see inline comments in `sample.json`) — three templates, run all
at once with `bxp-cli --config ./sample.json`:

1. `bridge_csv` — CSV batch → unified `id,date,amount` (convert US date, strip
   the `,` thousands).
2. `bridge_json` — JSON batch → the **identical** schema (map the different key
   names `order_id`/`ts`/`total`).
3. `combine_unified` — `combined_output: true` over the two normalised
   `*.unified.csv` files → one `1-combine_unified-combined.csvx`.

Each pass uses a distinct `file_pattern_in` so the three never pick up each
other's files.

**Run it.**

```bash
bxp-cli --config ./sample.json
```

**Smoking gun.** A CSV batch and a JSON batch, different dates and number styles,
land as one consistent dataset:

```text
id,date,amount
A-1,2024-03-15,1250.5
A-2,2024-03-16,980
B-1,2024-03-20,540
B-2,2024-03-21,3120.75
```
