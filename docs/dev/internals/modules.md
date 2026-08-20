---
description: "What every bxp-core module is responsible for, where its code lives, and the stateless inspect surface."
---

# Module reference

## bxp-core modules

What each module is responsible for, and — the column that used to rot — where
its code actually lives. Nine are files in `bxp-core/src/`; the rest are pinned
upstream dependencies, either modules of the `zig-libs` collection or standalone
fetch dependencies. Three of the zig-libs entries are re-exports bxp-core never
imports itself: they are published here only so `bxp-gui-bridge` and `bxp-mcp`
share this package's single pin.

--8<-- "includes/bxp-core-modules.md:table"

---

## bxp-cli internals

**`main.zig`** - entry point:

1. Parses run flags: `--config`, `--template`, `--data`, `--dry-run`, `--debug` (+ `=json`), `--quiet`, `--fresh`, `--trace` (+ `--trace-file`), `--check-fs`, `--version`, `--help`.
2. Validates file paths (rejects shell metacharacters, limits `../` depth).
3. Loads and validates all templates in config (`config.validate()`).
4. Calls `pipeline.xlsxPrePass()` for any templates that reference `.xlsx` files.
5. Calls `pipeline.processBroker()` for each selected template.
6. Exits with code `0` (success), `1` (error), or `2` (warnings).

**`pipeline.zig`** - processing engine:

- `xlsxPrePass()` - iterates all templates with `xlsx_sheet` defined, converts each
  `.xlsx` file to an intermediate `.csv`. Templates sharing the same `data_dir` share
  the extraction pass (each file extracted once).
- `processBroker()` - the main processing loop (intentionally monolithic):
  1. Reads input files (CSV, JSON, or intermediate CSV from xlsx pre-pass).
  2. Runs `pre_pass` if defined: one full iteration over all rows building a lookup map.
  3. Main loop: evaluates `input_schema` expressions, matches `row_rules`, renders `output_schema` to produce output rows.
  4. Writes RFC 4180-compliant CSV to `.csvx` output files.
- `Output` - thin wrapper around stdout that respects `--quiet` and `--debug` flags.
- `SectionStats` - accumulates warning/error counts and elapsed time across templates.

Deeper detail: [`bxp-cli/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-cli/CLAUDE.md).

---

## inspect core (stateless surface)

Everything that isn't "run a conversion" — config validation, expression
validation / evaluation / trace, expr-batch, schema/docs emission, template
list/fetch — lives in one stateless module, `bxp-core/src/inspect.zig`. It is
pure: it never reads argv, never writes stdout/stderr, never exits; callers own
all I/O and the arena. Two thin adapters wrap it: **bxp-mcp** (MCP/stdio for
agents) and **bxp-gui-bridge** (FFI for the GUI). A former `bxp-fmt` CLI adapter
wrapped the same calls argv→stdout and was removed once both covered every op.

--8<-- "includes/inspect-surface.md:table"

That table is the module's entire public surface, held there by a compile-time
check in `inspect.zig`: a new `pub fn` without an entry — or an entry naming a
function that was renamed away — fails the build.

Adding an op: write the pure function in `inspect.zig`, describe it in
`module_docs.inspect_ops`, then expose it from each adapter (a `bxp-mcp` tool in
`bxp-mcp/src/tools.zig` + a `bridge_*` entry in `bxp-gui-bridge/src/main.zig`).
No business logic lives in the adapters.

Deeper detail: [`bxp-mcp/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-mcp/CLAUDE.md),
[`bxp-gui-bridge/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui-bridge/CLAUDE.md).
