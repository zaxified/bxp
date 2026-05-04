/// JSON5 parser, comment-preserving AST, and mutation API.
///
/// Public API entry point. Consumers should
/// `import 'package:json5_ast/json5_ast.dart';` to pick up the supported
/// surface in one go. Cherry-picking individual files (e.g.
/// `package:json5_ast/ast.dart`) still works for now and is what bxp-gui
/// currently does — both styles are accepted for transitional builds.
///
/// `lib/src/tokenizer.dart` is intentionally NOT re-exported. It lives
/// under `lib/src/` (idiomatic Dart "package-private") and its public
/// symbols are annotated `@internal`; consumers must not import them.
/// When the package is extracted to a standalone repo, the barrel is
/// the contract that gets stabilised under SemVer; tokenizer changes
/// are free.
library;

export 'ast.dart';
export 'dumper.dart';
export 'operations.dart';
export 'parser.dart';
export 'path.dart';
export 'value_builder.dart';
