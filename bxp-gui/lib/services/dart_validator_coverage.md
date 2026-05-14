# DartValidator coverage

What `lib/services/dart_validator.dart` checks natively per edit, what
still routes through `bxp-fmt` as a subprocess, and what is reachable
only at conversion runtime.

The validator is a thin interpreter of the `bxp-fmt --docs` catalog
(FnDoc + FieldDoc with `args` / `min_args` / `max_args` / `validator` /
`autocomplete` populated by `bxp-core`'s Phase 1 metadata). Every
specialised check is data-driven so the Zig and Dart sides cannot
drift.

## Native Dart (no `bxp-fmt` subprocess)

Tree-level — driven by `FieldDoc.validator`:

- ✅ `non_empty` — `data_dir`, `file_pattern_in/out`, `xlsx_sheet.name`.
  Empty / whitespace-only string flagged as `dart.field.NonEmpty`.
- ✅ `starts_with_dollar` — `output_schema.*` values must start with `$`
  (they reference `input_schema` $variables). Flagged as
  `dart.field.StartsWithDollar`.
- ✅ `expr_string` — routes the value through the Dart expression
  walker (see below) so SPLIT_PART / DATE_CONVERT / unknown-function
  hits surface immediately on every edit.

Tree-level — independent walks:

- ✅ Unknown config keys (G7-equivalent) — for any object whose
  schema declares a fixed key set (no `*` wildcard child), flag keys
  not in the FieldDoc whitelist as `dart.config.UnknownKey` with a
  Levenshtein nearest-neighbour suggestion when distance ≤ 2.
- ✅ Unused `pre_pass` block (G8-equivalent) — declared block names
  not referenced via 3-arg `LOOKUP("name", …)` or implicit 2-arg
  resolution against a single-block configuration. Skipped entirely
  when any expression contains a computed-name LOOKUP (cannot
  statically prove which block is hit). `dart.config.UnusedPrePass`.
- ✅ Unused `$variable` (G8-equivalent) — keys of `input_schema` not
  referenced anywhere in the template (other expressions, `output_schema`
  values, `pre_pass` block expressions). `dart.config.UnusedVar`.
- ✅ `[Field]` cluster outliers (G2 layer B-equivalent) — a field
  referenced exactly once that is within edit distance ≤ 2 of a field
  referenced ≥ 3 times. `dart.expr.UnknownField`.

Expression-level — driven by `FnDoc.args[i].kind`:

The Dart walker still implements all five checks below — `_checkCall`
runs them whenever tree-walk (`_revalidateDart` per-edit feedback) hits
an `expr_string` leaf. The editor first-pass (`validateExpr`) filters
four of them out so the bridge response wins per-keystroke without
duplicate diagnostics. See `dart_validator.dart:158-176`.

- ✅ tree-walk only / 🛜 editor via bridge — Unknown function (name
  not in builtins set; suggests nearest builtin within edit distance
  ≤ 2). `dart.expr.UnknownFunction`. Editor: `bridge_eval_expr` via
  `expr.eval` since 2026-05-11.
- ✅ tree-walk only / 🛜 editor via bridge — Wrong arg count (checks
  `min_args` / `max_args`, variadic max of 255 = unbounded).
  `dart.expr.WrongArgCount`. Editor: `bridge_eval_expr`.
- ✅ tree-walk only / 🛜 editor via bridge — `literal_int_positive`
  (SPLIT_PART arg[2]) — bare int literal ≤ 0 is always `""`.
  `dart.expr.SplitPartBadIndex`. Editor: `bridge_eval_expr` via
  `expr.staticCheckCalls` since 2026-05-14.
- ✅ tree-walk only / 🛜 editor via bridge — `sunrise_format`
  (DATE_CONVERT arg[1]/arg[2]) — bare string literal scanned against
  the sunrise vocabulary `Y M D E A` / `a e h i m s`; first
  out-of-vocabulary letter outside `[...]` brackets is flagged.
  `dart.expr.DateFormatBadToken`. Editor: `bridge_eval_expr`.
- ✅ Dart in both flows — `pre_pass_name` (LOOKUP first arg in 3-arg
  form) — bare string literal cross-referenced against the active
  template's pre_pass block names; mismatch suggests nearest declared
  name. `dart.expr.LookupUnknownPrePass`. Bridge ABI doesn't expose
  the `pre_pass_names` whitelist needed for this check, so Dart owns
  it long-term.

Autocomplete — driven by `FieldDoc.autocomplete` + AST + dry-run cache:

- ✅ `[` trigger — CSV header names cached from the most recent
  dry-run's `file_start` events for the active template.
- ✅ `LOOKUP("` trigger — pre_pass block names declared in the active
  template's `pre_pass` map (legacy single-block synthesises
  `_default`).
- ✅ Identifier prefix — function and keyword names from the docs
  catalog (existing behaviour, kept).

UX:

- ✅ Token-level wavy red underline on the offending span in the
  expression editor (driven by `exprValidationOffset` + length set by
  the Dart-side validator first, bxp-fmt subprocess as fallback).

## bxp-fmt subprocess fallback

Still required because the Dart walker doesn't cover them:

- ⚠️ Expression syntax / precedence errors (UnexpectedToken,
  ExpectedRParen, ExpectedComma, …). The Dart token walker is
  sufficient for FnArgDoc-driven static checks but does not parse
  the full expression grammar.
- ⚠️ Filesystem checks (`--check-fs=N`). Requires syscalls; runs only
  on explicit VALIDATE button click and on save.
- ⚠️ Cross-template logic beyond what the AST already exposes (e.g.
  template-level `validate` invariants in `BrokerConfig.validate`).

## Runtime-only (cannot validate at edit / save time)

- ❌ `[FieldName]` vs the actual CSV header at conversion time
  (G2 layer A — fatal). The dry-run / full conversion is the only
  source of truth for headers; the Dart cluster check is a heuristic
  hint, not a substitute.
- ❌ LOOKUP table contents — populated by the pre_pass block at
  runtime; Dart can only verify the block name, not the key/field.
- ❌ NotANumber / type errors on real CSV row data — values arrive
  per-row at conversion time; the Dart walker can't see them.

## Updating this document

When extending the catalog with a new `ArgKind` or `FieldValidator`
that the Dart side handles, move the relevant line from ⚠️ to ✅ in
the same commit that lands the Dart-side dispatch in
`dart_validator.dart`. The list above is a living deliverable, not a
historical snapshot.
