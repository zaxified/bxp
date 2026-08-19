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

Regression coverage lives in [`../../datasets/`](../../datasets/) (gated by
`scripts/test-07-datasets.sh`). `docs/examples/` is **not** in any `test-NN-*.sh`
phase — its `.expected` files are hand-verified goldens, exercised manually and
by `scripts/bench/verify-output.sh`.

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

## Per-example layout

Two file layouts exist (both valid):

- **Single-input:** `index.md`, `sample.json` (config), `sample.csv` (or
  `sample.in.json` / `sample.hl7`), `sample.csvx` + `sample.expected` (golden).
- **Multi-input:** `index.md`, `sample.json`, several named inputs
  (`orders.csv`, `legacy.csv`, `crm_alpha.in.json`, `sales_q1.xlsx`, …), and a
  combined output `1-<template>-combined.csvx` (+ `.expected`).

`sample.expected` is the final-only golden and must match the engine output 1:1.
Examples stay **runnable in place** — config + inputs sit next to `index.md`, so
`bxp-cli --config ./sample.json [...]` works from the example dir.

What ships to the published site is controlled by `exclude_docs` in
[`mkdocs.yml`](../../mkdocs.yml): goldens (`*.expected`), engine output
(`*.csvx`, `1-*`), scripts (`*.sh`), and binaries (`*.zip`, `*.xlsx`) are kept
**out** of the site — only the prose + embedded text inputs ship. The binaries
and full-scale files are linked to GitHub from the page instead.

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
  (`=== "sample.json (config)"`), then one tab per text input, embedded with
  `--8<-- "examples/<tier>/<name>/<file>"` (path is docs-relative). Binary inputs
  and `full*`/`fetch-full.sh` are GitHub links, not embeds.

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

## The index pages are generated

`docs/examples/index.md` (central) and `docs/examples/<tier>/index.md` (per-tier
landings) are **signposts auto-generated** by
[`../../scripts/gen-examples-index.py`](../../scripts/gen-examples-index.py) from
each page's `# H1` + `!!! abstract "What"`. **Do not hand-edit them** — re-run
the generator after adding, renaming, or re-describing an example:

```bash
python3 scripts/gen-examples-index.py
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
