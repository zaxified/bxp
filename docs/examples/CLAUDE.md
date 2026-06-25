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
