/// Phase 5a: Load a JSON5 config file via the Dart AST library.
///
/// Replaces `the bridge config validation` as the primary loader. The AST stays the
/// single source of truth for the file contents; the bridge is invoked
/// separately as a background validator that contributes only `$err_*`
/// markers (see `_validateConfigNow` / `loadConfig` for the merge step).
library;

import 'dart:convert';
import 'dart:io';

import 'package:json5_ast/ast.dart';
import 'package:json5_ast/parser.dart';

/// Carries the parsed tree (or null on hard failure), the list of
/// JSON5-syntax diagnostics emitted by the parser, and the raw source text.
/// Callers keep [rawText] around so [AstPatchClient] can replay the op log
/// against the identical bytes that were originally loaded, avoiding a
/// re-read from disk between load and save.
class AstLoadResult {
  final JsonAstNode? root;
  final List<ParseDiagnostic> diagnostics;
  final String rawText;
  AstLoadResult(this.root, this.diagnostics, this.rawText);

  /// True when any diagnostic carries [Severity.error].
  /// Warnings (e.g. trailing commas in strict mode) do NOT block editing.
  bool get hasErrors =>
      diagnostics.any((d) => d.severity == Severity.error);
}

class AstLoader {
  /// Read [path] from disk, parse it via the Dart JSON5 AST library, and
  /// return the resulting tree plus any JSON5-syntax diagnostics. Throws
  /// [FileSystemException] if the file is unreadable; otherwise always
  /// returns a result (with `root == null` and a populated `diagnostics`
  /// list when parsing fails).
  static Future<AstLoadResult> loadFromFile(String path) async {
    final bytes = await File(path).readAsBytes();
    // allowMalformed: a corrupt/binary config must surface as a parse
    // diagnostic, never an uncaught FormatException (the "loader never
    // crashes" contract). Invalid sequences become U+FFFD, which the
    // JSON5 parser then rejects with a normal diagnostic.
    final src = utf8.decode(bytes, allowMalformed: true);
    final parsed = Parser.parse(src);
    return AstLoadResult(parsed.root, parsed.diagnostics, src);
  }
}
