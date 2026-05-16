# CLAUDE.md — json5_ast

Standalone Dart JSON5 parser + comment-preserving AST + mutation API.

## Status

Path-dep package consumed only by `bxp-gui` today. Not bxp-specific —
the library has no notion of `BrokerConfig`, `FieldDoc`, or any other
bxp domain concept. **Candidate for extraction** to its own repo (and
later `pub.dev` publish) once a second Dart project needs it; until
then it lives here so refactors stay atomic with the consumer.

## Origin

Replaces the older CST byte-patcher (`op_apply.dart` + `json5_emitter.dart`,
~1800 lines, deleted in Phase 3 of the AST migration). The CST approach
treated bytes as truth and tracked spans through every edit, which led
to recurring trailing-comma / move-down / dup bugs. The AST approach
flips the source-of-truth: parse once, mutate the tree, dump
deterministically. The first save canonicalises whitespace; from then
on dumps are byte-stable (idempotent canonicalisation).

## Public API

- `parser.dart` — `Parser.parse(src) → ParseResult { root, diagnostics }`.
  Captures TokenizerError + ParserError into diagnostics so a malformed
  config never crashes the loader.
- `dumper.dart` — `Dumper.dump(root) → String`. Deterministic style
  (2-space indent, no trailing commas, per-block leaf alignment).
- `ast.dart` — node types: `JsonObject`, `JsonArray`, `JsonProperty`,
  `JsonString`, `JsonNumber`, `JsonBool`, `JsonNull`, `CommentLine`
  (with `inlinePlacement` flag for trailing comments).
- `operations.dart` — `setValue`, `insertProperty`, `insertElement`,
  `deleteAt`, `duplicateAt`, `moveAt`, `insertLeadingComment`,
  `editComment`, `deleteComment`, `moveCommentAt`. Dotted/indexed paths.
- `path.dart` — `resolveNode`, `resolveParent`, `findCommentByGlobalN`,
  `globalCommentNumbering`. RAW indices (count CommentLine peers).
- `value_builder.dart` — `astFromValue(Map/List/scalar)` for converting
  Dart-native values into AST nodes (used by op_to_ast.dart in bxp-gui).

## Comment ownership conventions

After Phase 5e every comment is a peer entry in its container:

- `CommentLine(node, inlinePlacement: false)` — standalone (own line),
  appears between real entries.
- `CommentLine(node, inlinePlacement: true)` — trailing inline comment
  attached to the preceding real entry (`a: 1, // trailing`).

`deleteAt(path)` removes any contiguous run of non-inline CommentLines
immediately preceding the target plus a single inline-placement
CommentLine immediately following. This treats `// doc-for-X\n  X: ...`
as a single semantic unit so deletes don't silently re-attach the
comment to the next sibling.

## Tests

```bash
cd bxp-gui/packages/json5_ast && dart test
```

~105 tests covering tokenizer/parser features, all 11 mutation
primitives, path navigation edge cases, and round-trip canonicalisation.
The round-trip test asserts **idempotent canonicalisation** (not
byte-identity) — the first dump may reformat input, but subsequent
parse → dump cycles must produce identical bytes.

## Coding conventions

- Pure Dart, no Flutter, no `package:bxp_*`.
- All code comments and documentation in English.
- Public surface should stay minimal — anything in `lib/*.dart` is
  reachable from `package:json5_ast/X.dart`. Keep the API stable so
  future extraction doesn't break consumers.

## Future extraction

Recipe for spinning out to its own repo:

1. `git subtree split --prefix=bxp-gui/packages/json5_ast -b json5_ast`
2. Push that branch to a new GitHub repo.
3. In bxp-gui's pubspec.yaml, change `path: packages/json5_ast` to
   `git: { url: ..., ref: ... }`, or eventually `^X.Y.Z` after `pub publish`.
4. Drop `bxp-gui/packages/json5_ast/` from this monorepo.

Until then, treat any change here as a bxp-gui-affecting change.
