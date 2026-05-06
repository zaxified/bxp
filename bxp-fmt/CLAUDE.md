# CLAUDE.md — bxp-fmt

Guidance for Claude Code when working with the bxp-fmt package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-fmt** — small developer utility binary sibling to bxp-cli. Holds anything
that isn't "run a conversion": config validation, expression validation,
expression-trace evaluation, schema/docs emission, template lookup. Consumed
by bxp-gui (via `Process.run` from Dart) and by `scripts/test.sh`.

The binary is intentionally a thin shim: every subcommand delegates to a
bxp-core module (`config`, `expr`, `docs`). bxp-fmt's own job is arg parsing,
arena setup, and JSON serialization on stdout/stderr.

## Subcommands (exactly one action per invocation)

- `bxp-fmt --config <path>` — read JSON5 config, validate structure via
  `config_mod.load()` + `BrokerConfig.validate()`, emit annotated JSON to
  stdout (see "Annotated JSON output" below). Exit 0 on success, 1 on any
  validation error.
- `bxp-fmt --expr '<text>'` — parse and evaluate the expression with an
  empty `Context` (no fields, empty column index). Success → exit 0.
  Failure → one JSON line on stderr:
  `{"error":"<ErrorName>","detail":"<detail>"}`; exit 1.
- `bxp-fmt --expr-trace '<text>' [--row-headers <json>] [--row-fields <json>]`
  — evaluate one expression with optional fake-row context and stream
  per-call NDJSON traces to stdout. Used by bxp-gui's expression playground.
- `bxp-fmt --docs` — emit the full language + schema documentation JSON
  to stdout. Top-level keys: `functions`, `keywords`, `operators`,
  `tokens`, `config_schema`. Source of truth lives in
  `bxp-core/src/docs.zig` (which re-exports `expr.zig`'s `FnDoc` catalog and
  flattens `config.zig`'s per-struct `FieldDoc` tables). bxp-fmt is a
  passthrough — see [`../bxp-core/CLAUDE.md`](../bxp-core/CLAUDE.md) for the
  authoring rules.
- `bxp-fmt --config <path> --list-templates` — emit a JSON array of every
  template id declared in the config (no semantic validation). Used by
  bxp-gui's template picker.
- `bxp-fmt --config <path> --fetch-template <id>` — emit the raw JSON5
  block for a single template as JSON.
- `--version`, `--help` — standard.

`--list-templates` and `--fetch-template` are **modifiers** on `--config`;
all other subcommands are mutually exclusive with each other and with the
modifiers. The `--version` output goes to stdout (not stderr) so callers
that capture it (e.g. bxp-gui's runtime info panel) get the version.

## Annotated JSON output (`--config`)

Standard JSON with reserved key prefixes:

- `$comm_<N>: { "text": "<original>", "placement": "<pos>" }` — one entry
  per preserved comment. `placement` ∈ `leading` (own line before key),
  `trailing` (after value on same line), `block` (`/* ... */`),
  `standalone` (block at end of object before `}`).
- `$err_<N>: { "message": "...", "off": N, "len": N, "suggest": "..." }` — error finding.
- `$warn_<N>: { "message": "...", ... }` — warning finding.
- `$info_<N>: { "message": "...", ... }` — info finding.
  `off`, `len`, and `suggest` are present only when the diagnostic has them.
  Each finding is inserted as a sibling immediately before the offending key
  in its parent object; appended at the end of the parent when the offending
  field doesn't exist (e.g. missing required field).

`<N>` is a single monotonically-increasing counter shared across all
prefixes so all keys are unique. Original key order is preserved
(insertion order via `std.json.ObjectMap`).

The runtime config loader (`bxp-cli`) uses `json5.preprocess` (the
non-annotated variant), so `$comm_<N>`/`$err_<N>` never reach the data
tree consumed by the conversion pipeline.

## Exit codes

- `0` — success
- `1` — validation failure (config diagnostic, expression error, template id
  not found)
- `2` — usage error (unknown flag, missing argument, mutually-exclusive
  actions, missing `--config` for a modifier)

## Why a separate binary

- bxp-cli's job is "run a conversion against broker data"; mixing validate /
  format subcommands in dilutes that contract.
- Matches the Go/Rust convention (`gofmt` vs `go build`, `rustfmt` vs `cargo`).
- Small, focused binaries compose well — bxp-gui spawns both bxp-cli (for
  conversions) and bxp-fmt (for everything else).

## Source layout

```text
bxp-fmt/
  src/
    main.zig      ← single file: arg parsing + 6 subcommand dispatchers
                    (~2150 lines — bulk is JSON serialization helpers,
                     `--config` annotation glue, and deep validation logic)
  build.zig       ← depends on bxp-core path dep (../bxp-core); imports
                    the `config`, `expr`, `json5`, `docs`, and `diagnostics` modules
  build.zig.zon
```

## Build and run

```bash
cd bxp-fmt
zig build

./zig-out/bin/bxp-fmt --config ../datasets/xtb2_cash_to_wealthfolio/sample.json
./zig-out/bin/bxp-fmt --expr "IF([Qty] > 0, 'BUY', 'SELL')"
./zig-out/bin/bxp-fmt --docs | jq '.config_schema | length'
./zig-out/bin/bxp-fmt --config ../DEV/bxp-cli.json --list-templates
```

## Notes

- All code comments and documentation in English.
- Zig 0.15.2 API — use the zig skill before writing new code.
- Scope is intentionally tiny; the real work lives in bxp-core.
- Every `runX` function wraps the input GPA in an `ArenaAllocator` —
  `expr.Context.alloc` and JSON parse helpers don't garbage-collect, so
  using a raw GPA leaks per call.
- New flags get added when bxp-gui or scripts have a concrete need, not
  speculatively.

## Known non-issues — deliberately not refactored

Audit follow-up rationale captured here so future audits don't re-flag
the same observations. If the rationale stops applying (e.g. caller
count crosses the threshold), revisit.

- **`runX` writer setup boilerplate.** Each of the five `runX` functions
  starts with the same `ArenaAllocator.init` + `stdout.fwriter` setup.
  Skipped: extracting into a `WriterSetup` helper would obscure
  per-function specifics (different stdout buffer sizes, e.g. 4 KB for
  `runDocs` vs 64 B for `--version`). Revisit only when a 7th caller
  appears — the rule-of-three threshold is already hit but the
  variation between callers makes the abstraction hurt more than it
  helps today.

- **`emitExprError` extraction.** `runExpr` and `runExprTrace` each
  serialize a JSON error object to stderr — almost identical except
  `runExprTrace` also writes `"t":"error"`, and both now include optional
  `"off"`/`"len"` token-span fields (Phase G1). Skipped: only two call
  sites today. Extract when a third caller shows up; the gain is too
  modest to justify a parameterised helper for two consumers.
