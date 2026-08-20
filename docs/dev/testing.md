---
description: "The test-suite phases, how to run one alone, and how to add a regression or an expression-corpus case."
---

# Testing

This document covers the test suite phases, how to run individual sub-suites,
and how to add new regression tests or expression corpus cases.

```bash
# run test
./scripts/test.sh
```

`test.sh` runs every `test-NN-*.sh` sibling in numeric order. All of them build
the same optimize mode (**ReleaseSafe**) — one codegen + safety configuration
across the whole gate keeps the error surface small, since a mode-specific bug
like the bridge's old Debug-only SEGV cannot slip through a gap the tests never
exercise. The shipped archives (`release-01`) are the only ReleaseSmall build.

Each phase describes itself in its own header, and this table is read from those
headers — so a new phase appears here by being added, and nothing has to be
kept in step by hand:

--8<-- "includes/test-phases.md:table"

Run one alone with `bash scripts/<phase>`, or just the Zig unit tests with
`cd bxp-core && zig build test`.

A few phases carry detail the one-liner cannot:

- **test-01** drives eight `zig build test` roots in `bxp-core` — `json`,
  `btrace`, `expr`, `unicode`, `xlsx`, `config`, `docs`, `inspect`. There are no
  `csv`, `tz`, `datefmt`, `json5`, `decimal`, `zipstream` or `diagnostics` roots
  any more: those modules moved to zig-libs and carry their own, larger suites
  upstream.
- **test-04** also builds the bridge shared library, because
  `expr_corpus_bridge_test.dart` loads it, and it hosts the
  generated-documentation drift guard (see below).
- **test-08 and test-09** are complementary, not redundant: the first evaluates
  the *expressions* printed on the example pages, the second runs the examples
  and diffs their output against the committed goldens.

> **Docs formatting is not a phase, and is hand-maintained.** Prettier and
> markdownlint were dropped because they reflow and mis-lint MkDocs-specific
> syntax and break the rendered pages, so
> `scripts/docs/check-formatting.sh` (a mermaid-fence parse) stays a standalone
> pre-release check that `test.sh` does not run. The *generated* pages are a
> different matter: `scripts/docs/gen-docs.sh --check` regenerates every
> catalog-driven page and fragment and fails on any diff, and it runs inside
> **test-04** on every suite run.

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
