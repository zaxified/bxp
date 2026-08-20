# CLAUDE.md — docs/examples

Guidance for Claude Code when authoring or editing the `docs/examples/` tree.
For monorepo-level context see [`../../CLAUDE.md`](../../CLAUDE.md); for the docs
site as a whole see [`mkdocs.yml`](../../mkdocs.yml).

## Purpose

`docs/examples/` is the **Examples** section of the MkDocs Material site **and**
the hand-maintained home of every runnable example. Each example is a
self-contained demonstration of one data problem the bxp engine solves — config
+ input + expected output + a narrative `index.md` that renders as the docs page.

This tree was migrated out of the old top-level `examples/` (June 2026): the
per-example `00-readme.md` became `index.md`, authored directly in MkDocs
Material idiom. There is **no generated/source split** — the `index.md` pages are
the source. (The one-time migration scaffold has been discarded.)

Every example is gated by two phases:

- `scripts/test-09-examples.sh` runs it — each example executes in a scratch
  work dir (its goldens and committed output sit next to the inputs under
  `data_dir: "."`, so an in-place run would re-read them) and every produced
  output is diffed against its `*.expected` golden. Same strict contract as
  `datasets/`: exit 0 and **empty stderr** — a warning is an example-quality
  bug. An example with no golden fails the phase as ungated.
- `scripts/test-08-docs-examples.sh` checks the page — see *Clickable
  expressions* below.

Separate fixtures under [`../../datasets/`](../../datasets/) are gated by
`scripts/test-07-datasets.sh`.

## Two kinds of example

- **Real-world use cases** (`real-world/`) — a real, publicly available dataset
  with a **cited source** documenting a genuine, reproducible data problem. The
  committed `sample.csv`/`sample.json`/`sample.zip` is a small **real slice**; a
  `fetch-full.sh` (+ `full.json`) pulls the complete file for a scale run. Never
  synthesise real-world data ([[feedback_real_world_problem_first]]).
- **Teaching examples** (`basic/` → `intermediate/` → `advanced/`) — small,
  synthetic, hand-constructed inputs that isolate one engine feature. The data is
  fabricated **on purpose** and the page says so (the `!!! note "Synthetic /
  teaching example"` admonition). The _problem class_ must still be real.

## The sample is a teaching artifact, not a data extract

An example is **first of all a teaching document**. The committed `sample.*` is
therefore **hand-picked**, not mechanically derived from the full dataset — for
a real-world example, real rows chosen so that one short table shows every case
the template handles; for a teaching example, rows written to do the same.
Nothing needs to be reproducible by re-slicing the source, and a "first N rows"
slice is usually the worst choice: it is long, repetitive, and still misses the
interesting cases.

Two rules follow, and both are load-bearing:

- **Roughly 10 rows.** The page embeds the sample verbatim, so its length is
  what a reader scrolls through. Every real-world sample was once a 200–800 row
  extract and every one of them was unreadable on the site.
- **A statistic quoted on the page must come from the full run**, never from
  counting the slice. Once the slice is curated, "84% of this slice" measures
  the curation, not the world. Percentages and totals belong under
  `## At full scale`, backed by `full.json`.

Where the scale input comes from depends on the tier: `fetch-full.sh` downloads
it (real-world), `make-full.sh` generates it (teaching — see
`advanced/freeform-payment-memos`). Either way **every scale claim on a page
must have a script next to it that reproduces it**, and re-running that script
must be cheap (reuse what is already in `./full/`, which is gitignored).

## Per-example layout

The unit is a **row of config + input + output + golden**, and an example needs
**at least one**. It may have more:

- **Single-input, one row:** `index.md`, `sample.json` (config), `sample.csv`
  (or `sample.in.json` / `sample.hl7`), `sample.csvx` + `sample.expected`.
- **Multi-input, one row:** several named inputs (`orders.csv`, `legacy.csv`,
  `crm_alpha.in.json`, `sales_q1.xlsx`, …) into a combined output
  `1-<template>-combined.csvx` (+ `.expected`).
- **Multi-pass, one row per stage.** A pipeline's intermediates are results in
  their own right, so commit each one with its own golden —
  `advanced/multi-stage-etl` pins all four passes
  (`1-combine_op-combined`, `1-enriched.in`, `1-combine_oc-combined`,
  `1-final`), `mixed-format-bridge` pins both `*.unified.csv` bridges, and
  `xlsx-tabs-merge` pins the extracted sheet and the stamped part. Every golden
  is gated, so a pipeline cannot drift in the middle and still look right at the
  end. Incidental per-file copies that `combined_output` leaves next to the
  combined file are **not** stages — don't commit those.

Every golden must match the engine output 1:1. Examples stay **runnable in
place** — config + inputs sit next to `index.md`, so
`bxp-cli --config ./sample.json [...]` works from the example dir.

`test-09` decides what to seed into its work dir by **content**: a file equal to
one of the example's goldens is an output and is never seeded. That is what lets
a committed intermediate carry an input-looking name (`legacy.unified.csv` is
read by a later pass; `1-enriched.in.json` matches its consumer's
`file_pattern_in`) without a stale copy standing in for the run.

## What belongs on the site, and where

**Everything the reader needs to understand the example belongs on the page —
output very much included.** Whether a file is an input or something the engine
produced decides nothing; if the result explains the point, show the result.

The real constraint is **placement**, and it is about length:

- A short block — a handful of rows, a before/after, one stage's output —
  belongs **inline in the prose**, right next to the sentence it proves.
- Anything long belongs **at the bottom, in a `## Sample data` tab**. A hundred
  lines of CSV mid-paragraph stops being an explanation and becomes an
  obstacle. Prose blocks currently top out around nine lines; treat that as the
  ceiling and move the rest down.
- Never keep a **hand-copy** of a file in prose to work around length (a
  pretty-printed excerpt of a committed result, say). It is ungated, so it
  drifts. Quote the two or three values the sentence is about, and send the
  reader to the tab for the whole thing.

`exclude_docs` in [`mkdocs.yml`](../../mkdocs.yml) is a separate, duller
question: it decides whether a file also gets its **own URL** as a raw
download. Goldens, engine output, scripts and binaries do not, because the page
already embeds whatever of them matters — a standalone copy would be the same
bytes a second time, linked from nowhere. Binaries and the full-scale files are
linked to GitHub from the page instead.

## Page structure (`index.md`)

Author each page in MkDocs Material idiom, matching the gold standard
[`advanced/multi-stage-etl/index.md`](advanced/multi-stage-etl/index.md):

- `# H1` title, then a GitHub button:
  `[:material-github: View on GitHub](<gh-tree-url>){ .md-button }`
- `!!! abstract "What"` — the one-paragraph transformation statement.
- (teaching) `!!! note "Synthetic / teaching example"` — the fabricated-data
  disclaimer.
- `## Why interesting` — why the problem class matters.
- A `mermaid` diagram **only when** the transformation is a genuine flow:
  multi-pass pipeline, one→many fan-out (unpivot), or a decision tree (row
  classification). Per-field cleanup gets **no** diagram. Never hard-code mermaid
  colours — they break dark mode; let the theme colour it.
- (real-world) keep the cited-source bold-leads verbatim — `**Edge cases sourced
  from.**` / `**Data source.**` / `**Problem class documented in.**` — they are
  the proof the problem is real.
- `## The trick` — the key expression(s), with prose.
- `## At full scale` (real-world) — the `fetch-full.sh` + `full.json` scale run.
- `## Final result` — the before/after that proves the point.
- `## Sample data` (always LAST) — content tabs, **config first**
  (`=== "sample.json (config)"`), then one tab per text input, and **last the
  result** (`=== "sample.csvx (result)"`, or the `1-…-combined.csvx` /
  `1-final.json` for a combined or JSON-emitting template). Embed with
  `--8<-- "examples/<tier>/<name>/<file>"` (path is docs-relative; snippets read
  straight from disk, so `exclude_docs` keeping the file off the site does not
  block the include). Binary inputs and `fetch-full.sh` are GitHub links, not
  embeds. The `bxp-cli …` invocation goes here, in the lead-in line — **not** in
  a `## Run it` section of its own.

  Config → input → result is the reading order the tab strip should offer: the
  reader can see the answer without running anything. The result tab embeds the
  **committed** output, and `test-09` asserts that copy still equals the golden
  — publishing it is exactly why a stale artifact now fails the suite.

  Any **further** tab has to earn its place by teaching something the other
  three do not. `real-world/eurostat-population-tsv` shows `full.json` because
  the slice-vs-full difference (`FIELDS(2)` → `FIELDS(63)`) *is* that page's
  argument; on the other thirteen real-world pages `full.json` differs only by a
  path and a tab would be noise ([[feedback_coverage_is_not_the_goal]]).

**A multi-pass example gets a section per stage instead**, under
`## The trick — …`: one `### Pass N · <template> — <what it does>` per pass,
each with prose and that stage's committed output embedded inline with a
`title=` caption. The tab strip stays config → inputs → final result; the
pipeline is told in the prose, where the reader can see what each pass *knew*
that the previous one did not. `advanced/multi-stage-etl` is the worked example
— its second pass is where an order first learns its `category_id`, which is
the whole reason a single `pre_pass` cannot do the job.

Those headings are the whole set. A page that needs to say something else says
it inside one of them; adding a bespoke `## Run it` / `## Wide files` section
costs every other page's reader the habit they built up.

**`## Final result` is prose plus a text before/after — never GUI
instructions.** The reader is on the docs site with no GUI open and no output
file to sort; "open `sample.csvx` and sort by status" tells them nothing. Show
the rows. A GUI walkthrough is a genuine extra, so it goes underneath in its own
admonition:

```markdown
!!! tip "Trace it in the GUI"
    Click the `quality` cell of the `refund` row: the trace pane walks the
    nested `IF` that decided it, one comparison at a time.
```

The same section must not narrate repository history ("before the fix in TRICK 2
was applied…"). What an earlier version of the config got wrong is a commit
message, not a result.

## Clickable expressions (the scratchpad)

An expression on a page can be made runnable in the reader's browser: clicking
it opens a docked panel that evaluates it against the page's own sample rows,
with a **show all** toggle for the whole column. The engine is
`docs/assets/wasm/bxp-eval.wasm` — bxp-core compiled for wasm32 — so the answer
is the one `bxp-cli` gives, not a second implementation. Glue lives in
[`../assets/javascripts/playground.js`](../assets/javascripts/playground.js).

**Mark the expression** — inline, or as the display block that introduces it:

```markdown
`PRICE_VALUE([Price])`{.bxp-try}          <!-- inline, inside a sentence -->

```{.text .bxp-try}                        <!-- the page's central expression -->
REPLACE(REPLACE([Amount], ' ', ''), ',', '.') * 1
```
```

**Mark the sample** so there is a row to evaluate against — the same CSV tab the
page already shows, no second copy:

```markdown
=== "sample.csv"

    ```{.csv .bxp-sample}
    --8<-- "examples/<tier>/<name>/sample.csv"
    ```
```

**If the sample is not comma-separated**, repeat the template's
`csv_delimiter_in` on the fence — `{.csv .bxp-sample data-delim=";"}`. The panel
cannot read it from `sample.json`, and getting it wrong is not cosmetic: every
`[Column]` silently resolves to `""`. `scripts/test-08-docs-examples.sh` fails
if the two disagree.

**Mark only what teaches.** Coverage is not the goal — a clickable expression
should answer a question the surrounding prose raises. Leave a page static when
its point is a config feature (`combined_output`), a multi-template pipeline, or
a transformation whose expressions run on an earlier pass's output.

**What cannot be made clickable** (the gate rejects these, so it is not on you
to remember them):

| Shape | Why |
| --- | --- |
| `LOOKUP(...)` | needs a `pre_pass` table; the panel has none |
| `REMAP(x, 'name')`, `REPLACE(x, 'name')` | the **named** form needs the `maps` registry — without it the call returns its input unchanged, which reads as a successful remap. The inline form is fine |
| `FILENAME()`, `SHEET_NAME()`, `RECORD_NUM()` | per-file source context a standalone expression never has |
| a function *signature* (`TO_UTC(ts, from)`) | prose, not an expression |
| anything on a **tab-separated** sample | Python-Markdown expands tabs across the whole document before parsing, so a TSV sample cannot reach the panel at all — through a fence or a script element alike |

The first three self-explain in the panel (it names the missing context, from
the engine's own `FnDoc.needs`); the last two simply must not be marked.

Every mark is gated: `bash scripts/test-08-docs-examples.sh` evaluates all of
them against their own sample and fails on any that errors or is blank on every
row.

Mark only **inputs** as `.bxp-sample`. A tempting mistake is to tag the
before/after block in `## Final result`, which points the panel at output rows
the template has already transformed.

**Teach `ISEMPTY`, never `[x] = ''`.** In bxp `'0' = ''` is true — both sides
coerce to the number 0 — so an emptiness guard written that way silently eats
real zeros. The NOAA example shipped with it and reported 1,559 days of "no
rain" and two 0.0 °C mornings as missing measurements. `ISEMPTY` tests the
trimmed length, which `"0"` survives. This applies to the config and to the
prose alike; if the page names a different guard than `sample.json` uses, the
page is wrong.

## The index pages are generated

`docs/examples/index.md` (central) and `docs/examples/<tier>/index.md` (per-tier
landings) are **signposts auto-generated** by
[`../../scripts/docs/gen-examples-index.py`](../../scripts/docs/gen-examples-index.py) from
each page's `# H1` + `!!! abstract "What"`. **Do not hand-edit them** — re-run
the generator after adding, renaming, or re-describing an example:

```bash
python3 scripts/docs/gen-examples-index.py
```

New examples must also be added to the `nav:` in `mkdocs.yml` (under their tier),
and the per-tier `index.md` must stay the **first** entry of each tier group so
it becomes the section landing (`navigation.indexes`).

## Conventions

- All prose and comments in English.
- Real-world data must be **real and cited**; teaching data must be **labelled
  synthetic**. Never blur the two.
- Rank candidate examples by **user value**, not implementation ease
  ([[feedback_classify_by_value_not_difficulty]]).

See [[reference_examples_conventions]] for the longer-form rationale.
