# CLAUDE.md — bxp-fmt

Guidance for Claude Code when working with the bxp-fmt package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-fmt** — small developer utility binary sibling to bxp-cli. Holds anything
that isn't "run a conversion": config validation, expression validation, future
schema helpers. Consumed by bxp-ui (short-lived `Bun.spawn` calls) and by
`scripts/test.sh`.

## Flags (exactly one action per invocation)

- `bxp-fmt --config <path>` — read JSON5 config, validate structure via
  `config_mod.load()` + `BrokerConfig.validate()`, and emit annotated JSON to
  stdout (see "Output format" below).
- `bxp-fmt --expr '<text>'` — parse and evaluate the expression with an empty
  `Context` (no fields, empty column index). Success → exit 0. Failure → one
  JSON line on stderr: `{"error":"<ErrorName>","detail":"<detail>"}`; exit 1.
- `--version`, `--help` — standard.

## Output format (`--config`)

Standard JSON with two reserved key prefixes that bxp-ui consumes:

- `$comm_<N>: { "text": "<original>", "placement": "<pos>" }` — one entry per
  preserved comment. `placement` ∈ `leading` (own line before key), `trailing`
  (after value on same line), `block` (`/* ... */`), `standalone` (block at end
  of object before `}`).
- `$err_<N>: "<message>"` — one entry per syntax or semantic error. Inserted as
  a sibling immediately before the offending key in its parent object; if the
  offending field doesn't exist (e.g. missing required field), appended at the
  end of the parent.

`<N>` is a single monotonically-increasing counter shared between `$comm_` and
`$err_` so all keys are unique across the entire output. Original key order is
preserved (insertion order via `std.json.ObjectMap`).

The runtime config loader (`bxp-cli`) uses `json5_mod.preprocess` (the
non-annotated variant), so `$comm_<N>`/`$err_<N>` never reach the data tree
consumed by the conversion pipeline.

## Exit codes

- `0` — success
- `1` — validation failure (config diagnostic or expression error)
- `2` — usage error (unknown flag, missing argument, both/neither action flag)

## Why a separate binary

- bxp-cli's job is "run a conversion against broker data"; mixing validate /
  format subcommands in dilutes that contract.
- Matches the Go/Rust convention (`gofmt` vs `go build`, `rustfmt` vs `cargo`).
- Small, focused binaries compose well — bxp-ui calls both; future scripts can
  call just one.

## Source layout

```text
bxp-fmt/
  src/
    main.zig      ← arg parsing + subcommand dispatch (single file, ~140 lines)
  build.zig       ← depends on bxp-core (path dep ../bxp-core)
  build.zig.zon
```

## Build and run

```bash
cd bxp-fmt
zig build

./zig-out/bin/bxp-fmt --config ../datasets/xtb2_cash_to_wealthfolio/sample.json
./zig-out/bin/bxp-fmt --expr "IF([Qty] > 0, 'BUY', 'SELL')"
```

## Notes

- All code comments and documentation in English.
- Zig 0.15.2 API — use the zig skill before writing new code.
- Scope is intentionally tiny; the real work lives in bxp-core.
- Future flags (`--schema`, `--diff`, migration helpers) are added when a
  concrete need appears, not speculatively.
