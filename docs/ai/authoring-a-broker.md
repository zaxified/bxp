---
description: "How an agent authors a conversion template from a sample export, validating each step through bxp-mcp."
---

# Authoring a broker with an AI

bxp-cli templates are plain JSON5 — a capable AI (Claude, ChatGPT, …) can
write one for you. **Two files are required context:** the BXP docs (this
site, or the bundled `readme.md`) AND `bxp-cli.examples.json` (in the
console archive and the GitHub repository). The docs define the language
and the target output spec; the examples.json carries working per-broker
patterns the AI is expected to pattern-match against. Without
examples.json the AI should refuse to guess.

## Give the assistant the tools

Everything below works without it, but an assistant that can *run* bxp instead
of reasoning about it gets there far faster and stops handing you templates it
could not check. `bxp-mcp` ships in both packages — beside `bxp-cli` in the
console archive, inside the bundle on desktop — and registering it with an
MCP-capable client is one entry:

```json
{ "mcpServers": { "bxp": { "command": "/abs/path/to/bxp-mcp", "args": [] } } }
```

BXP Desktop fills that block in for you, with the path already resolved:
**ABOUT** in the top bar. That matters on Linux, where an AppImage mounts
itself somewhere new on every launch, so the path is not something you can
write down once.

## The prompt

Paste this into your assistant, attach both files, then drop in 5 rows of
your broker's raw CSV:

> _"I use BXP. Please read the **Guide** and **Target specs** sections of
> the docs and the comments in `bxp-cli.examples.json`. Here is a sample
> of my broker's export: `<paste 5 rows including the header>`. Add a new
> entry under `conversion_templates` in my `bxp-cli.json` that converts
> this to Wealthfolio CSV, following the same patterns as the existing
> templates. Self-test your output (validate the config, then run it
> against the sample rows — via the bxp-mcp tools if available, else
> `bxp-cli --debug`) before returning, return JSON5 with `//` comments
> explaining non-obvious decisions, and end your reply with a 'Things to
> check in bxp-gui' list for anything you couldn't fully verify."_

After the AI proposes a template, paste it into the GUI's tree editor (or
directly into your `bxp-cli.json`) and run a dry-run. The GUI's inline
error chips will tell you exactly which expressions need fixing, and the
AI's "Things to check in bxp-gui" list (see [Handing off](handoff.md))
tells you what to look for next.

## Rules for an AI assistant

If you are an AI assistant generating a new template, follow these rules
strictly:

1. **`bxp-cli.examples.json` is required context.** It ships working
   templates with rich inline comments. If you don't have it, ask the
   user to provide it before generating any template — do not guess at
   non-trade row patterns, action vocabulary, or broker quirks.
   Pattern-match against whichever shipped template is closest in shape
   to the broker at hand: a plain stock broker with one row per trade, a
   broker that emits paired rows per transaction, an xlsx source, or a
   template targeting the tracker output rather than Wealthfolio. Read
   the real ids out of the file rather than assuming them — with the
   bxp-mcp server, `bxp_list_templates` returns a compact index (id plus
   the file patterns and description) and `bxp_fetch_template` returns a
   single template's JSON, so you can quote the one you are modelling
   rather than the whole file. Both take the config **text**, not a path.
2. **Add, do not modify.** Insert a new entry under
   `conversion_templates`. Never rewrite existing templates unless the
   user explicitly asks.
3. **Match the real CSV format.** Set `csv_delimiter_in`,
   `csv_decimal_separator_in`, and `csv_text_quote_in` to what the
   broker actually exports — do not guess.
4. **Put activity-type logic in `row_rules`, not `input_schema`.**
   `$action` must be assigned inside a `row_rules[].rows[]` entry. The
   `input_schema` only extracts and transforms neutral values.
5. **Use `pre_pass` only for cross-row joins.** If one input row needs a
   value from another row, use `pre_pass` and `LOOKUP`. Otherwise omit
   it entirely. `pre_pass` has two shapes, and they select different
   `LOOKUP` arities — do not mix them up:
   a single block `{ when, key, values }`, read with the 2-arg
   `LOOKUP(key, 'field')`; or named blocks `{ name1: { … }, name2: { … } }`,
   read with the 3-arg `LOOKUP('name1', key, 'field')`.
6. **Prefer named `maps`.** If the broker's symbols overlap an existing
   named map, reference it by name with `REMAP([Symbol], 'xtb')`.
   Otherwise define a small inline `REMAP(s, k, v, ...)`.
7. **One-to-many rows.** When one input row must produce multiple output
   rows (currency conversion = FEE + WITHDRAWAL + DEPOSIT; dividend with
   tax), return multiple objects in the same `row_rules[].rows` array.
8. **Match the broker's exact date shape.** Use `DATE_CONVERT` with
   tokens that correspond to the input literally, character-by-character;
   use `[*]` to skip fractional seconds, trailing `Z`, or timezone
   suffixes.
9. **Prices with embedded currency.** For fields like `"$100.00"` or
   `"24.00 CZK"`, use `PRICE_VALUE()` for the number and
   `PRICE_CURRENCY()` for the ISO code.
10. **Empty values.** Set a `$variable` to `""` to leave that output
    column blank. Drop a column from `output_schema` to remove it.
11. **Surface unmatched rows during development.** On the CLI, set
    `row_rules_debug_missing: true` and run with `--debug` — the pair is
    what dumps rows matching no rule as JSON. (`--debug` conflicts with
    `--quiet` and `--trace`.) The GUI does not use that flag: a dry-run
    reports skipped rows through the per-row trace instead, and clicking
    one shows its **RULE RESULTS**.
12. **Self-test before returning.** See below — predict each sample row's
    outcome, then verify with the bxp-mcp tools (`bxp_validate`,
    `bxp_eval` / `bxp_eval_trace`, `bxp_simulate`), or `bxp-cli --debug`.
13. **Return commented JSON5, not bare JSON.** Use `//` comments to
    explain non-obvious decisions — the user reads your output as
    documentation; future-you reads it to extend the template later.
14. **Hand off the unfinished business in plain language.** End with a
    numbered "things to check in bxp-gui" list — see
    [Handing off](handoff.md).

## Self-testing the generated template

Validate before returning. Treat the steps like unit tests — predict the
expected result, then compare against actual output.

The self-test surface depends on what you have wired:

- **With the bxp-mcp server** (agent path), nine tools: `bxp_validate`,
  `bxp_validate_expr`, `bxp_eval`, `bxp_eval_trace`, `bxp_eval_batch`,
  `bxp_list_templates`, `bxp_fetch_template`, `bxp_docs`, and
  `bxp_simulate` (a full end-to-end run). Each takes config / expression
  _text_ as arguments, so you never touch the filesystem. Reach for
  `bxp_docs` rather than guessing a builtin's signature — it is the same
  catalog the reference pages are generated from.
- **With only `bxp-cli`** (no MCP): `bxp-cli --debug` and a real run.

!!! note "`headers` / `fields` are arrays of strings"

    Every eval tool takes the row context the same way — a native JSON
    array, `["Price","Qty"]`. `bxp_eval` and `bxp_eval_trace` still
    accept the array encoded into a string
    (`"[\"Price\",\"Qty\"]"`), the shape their schema used to declare,
    but there is no reason to write it.

    Anything else is a **tool failure naming the argument**, never a
    silently empty row: an earlier version dropped the context and still
    answered `{"ok":true}`, so every `[Column]` read as `""` and agents
    concluded a correct expression was broken.

**1. Schema + JSON5 syntax check.** Call `bxp_validate` with the config
text. Expect no `$err_*` / `$warn_*` keys for the new template's path. If
`$err_*` appears, fix it before going further.

**2. Predict, then verify.** For each sample row, write down beforehand
which `row_rules` entry should match (and therefore `$action`), what each
`$variable` should evaluate to, and how many output rows the input row
should produce (0 / 1 / N).

- **Step A — per-expression check.** Before wiring an expression in,
  evaluate it on its own against one sample row with `bxp_eval_trace`
  (the `{"t":"final","value":...}` line is the result). Use
  `bxp_validate_expr` to catch authoring-time mistakes the lenient
  runtime swallows (e.g. a literal `SPLIT_PART(…, 0)`), and
  `bxp_eval_batch` for several `$variable` expressions against the same
  row at once.

  `bxp_eval` / `bxp_eval_trace`:

  ```json
  {
    "expr": "DATE_CONVERT([Time], 'YYYY-MM-DD hh:mm:ss', 'YYYY-MM-DD')",
    "headers": ["Action", "Time", "Ticker"],
    "fields": ["Market buy", "2024-04-25 07:00:35", "RIO"]
  }
  ```

  `bxp_eval_batch` — the same, plus `exprs`:

  ```json
  {
    "headers": ["Action", "Time", "Ticker"],
    "fields": ["Market buy", "2024-04-25 07:00:35", "RIO"],
    "exprs": ["UPPER([Ticker])", "[Action]"]
  }
  ```

  `bxp_eval_batch` also accepts `maps` (named `REMAP` / `REPLACE` tables),
  `lookups` and `single_prepass_name` — the only way to exercise `LOOKUP`
  without a full run.

- **Step B — run it end-to-end.** With MCP, call `bxp_simulate` with the
  config, the template id, and the sample CSV. It stages and runs the
  real `bxp-cli` pipeline and returns the produced output, a record-count
  diff, diagnostics, and a per-row `trace` — each filtered row carrying a
  reason (`rule_skip` / `no_rule_match`) and its 1-based input line, which
  is what tells you a `when` condition never matched. `ok: true` only
  means the run happened; read `exit_code` / `status` / `diagnostics` for
  the verdict. Pass the optional `workspace` argument to reuse one scratch
  directory across iterations instead of littering temp with a new one per
  call. Without MCP:

  ```bash
  ./bxp-cli --config bxp-cli.json --template <new_id> --debug
  ```

  Output: human-readable summary + `[expr error] $var = "expr": …` lines
  for any expression that failed at runtime + JSON dumps of unmatched
  rows when `row_rules_debug_missing: true`.

- **Step C — confirm the final output.** With `bxp_simulate`, read the
  returned `outputs[].csv`. Without MCP, run without `--debug` and read
  the generated `.csvx`:

  ```bash
  ./bxp-cli --config bxp-cli.json --template <new_id>
  ```

Iterate until step B is silent (zero `[expr error]`, zero unmatched rows)
and the `.csvx` from step C matches every prediction.

**3. Inspect the `.csvx`.** Header row matches `output_schema` keys, in
order. Spot-check at least one row of each `$action` type the template
emits.

**4. If a prediction fails, diagnose by category.**

| Symptom                          | Likely cause                                                                                       |
| -------------------------------- | -------------------------------------------------------------------------------------------------- |
| `$date` empty or wrong           | Date token mismatch (`MM` vs `mm`, missing `[*]` for timezone, etc.)                               |
| `[ColumnName]` resolves to empty | Column name typo / case mismatch / extra whitespace in source header                               |
| `$amount` differs by sign        | Missed `ABS()` — see [Target specs](../guide/targets.md)                                           |
| `--debug` lists unmatched rows   | Missing or wrong `row_rules` `when` condition                                                      |
| `$ticker` empty for cash event   | Non-trade row pattern not applied — see [Target specs](../guide/targets.md#non-trade-row-patterns) |

Only return the template once every prediction matches and `--debug`
output is empty.
