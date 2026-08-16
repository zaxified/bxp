# Testing

This document covers the test suite phases, how to run individual sub-suites,
and how to add new regression tests or expression corpus cases.

```bash
# run test
./scripts/test.sh
```

`test.sh` runs seven sub-scripts in numeric order. Every phase builds the same
optimize mode (**ReleaseSafe**) — one codegen + safety config across the whole
gate keeps the error surface small (a mode-specific bug, like the bridge's
Debug-only SEGV, can't slip through a gap the tests never exercise). The shipped
archives (`release-01`) are the only ReleaseSmall build.

**`test-01-console.sh`** — Zig / CLI build + unit:

1. `zig build test` in `bxp-core` (unit tests for `csv.zig`, `expr.zig`, `docs.zig`, `diagnostics.zig`).
2. Builds `bxp-cli` + runs its unit tests.
3. `dart test` inside `bxp-gui/packages/json5_ast/`.

**`test-02-mcp.sh`** — `bxp-mcp` build + unit tests + JSON-RPC smoke for the
stateless tools (`bxp_validate`, `bxp_validate_expr`, `bxp_eval_batch`, …) plus
a full `bxp_simulate` run.

**`test-03-bridge.sh`** — `bxp-gui-bridge` build + unit tests (FFI surface).

**`test-04-desktop.sh`** — Flutter / Dart side:

1. Builds `bxp-gui-bridge` shared library (needed for `expr_corpus_bridge_test.dart`).
2. `flutter analyze` — static analysis of `bxp-gui/`.
3. `flutter test` — widget + service tests in `bxp-gui/test/`.
4. `dart test` inside `bxp-gui/packages/json5_ast/` — json5_ast unit + round-trip tests.

**`test-05-bench-guard.sh`** — coarse perf-regression gate; recycles the Console
phase's ReleaseSafe `bxp-cli` and asserts an RSS ceiling + a scaling ratio.

**`test-06-expr-corpus.sh`** — expression corpus regression gate (TAB-separated
`expr<TAB>ok|err<TAB>...` cases).

**`test-07-datasets.sh`** — bxp-cli regression: iterates every `datasets/<id>/`
directory and diffs output against `sample.expected`.

> Docs formatting is **not** a test phase, and it is hand-maintained:
> prettier and markdownlint were dropped because they reflow / mis-lint
> MkDocs-specific syntax and break the rendered pages.
> `scripts/check-formatting.sh` (a mermaid-fence parse) is the one
> standalone pre-release docs check — `test.sh` does not run it.

Individual sub-suites:

```bash
bash scripts/test-01-console.sh        # Zig unit + bxp-cli + json5_ast Dart tests
bash scripts/test-02-mcp.sh            # bxp-mcp build + unit + JSON-RPC smoke
bash scripts/test-03-bridge.sh         # bxp-gui-bridge build + unit
bash scripts/test-04-desktop.sh        # flutter analyze + flutter test
bash scripts/test-05-bench-guard.sh    # coarse perf-regression gate
bash scripts/test-06-expr-corpus.sh    # expression corpus regression
bash scripts/test-07-datasets.sh       # bxp-cli regression vs datasets/

cd bxp-core && zig build test          # Zig unit tests only (no build)
```

## Expression corpus

`scripts/test-06-expr-corpus.sh` walks `scripts/test-06-expr-corpus.txt` and runs each line through bxp-mcp's `bxp_validate_expr` tool. Format is TAB-separated:

```text
expr<TAB>ok<TAB>expression
expr<TAB>err<TAB>expression<TAB>error_name
```

The corpus doubles as living documentation for the BXP expression language — readable for both contributors and AI template generators. When a parser bug surfaces, add a failing case before fixing; when adding a new built-in function, add an `ok` case + an `err` case for the wrong arity.

`scripts/test.sh` enforces a 60-second per-phase budget on the corpus phase via the `timeout` command, so a parser infinite-loop regression is caught quickly.

The same corpus is also walked through the GUI bridge (`bridge_eval_expr`) by
`bxp-gui/test/expr_corpus_bridge_test.dart` (run in `test-04`), so every case is
checked **cross-runner**: the MCP transport (`test-06`) and the in-process bridge
must agree on it.

## Adding a regression test

Place `sample.csv` (or `.xlsx`) + `sample.expected` + `sample.json` in `datasets/<template_id>/`.
The test script picks them up automatically.

## Anonymizing test data

Before committing `.csv` or `.xlsx` files in `datasets/`, strip real account or personal data.
