/// Phase 5a: Load a JSON5 config file via the Dart AST library.
///
/// Replaces `bxp-fmt --config` as the primary loader. The AST stays the
/// single source of truth for the file contents; bxp-fmt is invoked
/// separately as a background validator that contributes only `$err_*`
/// markers (see `_validateConfigNow` / `loadConfig` for the merge step).
library;

import 'dart:convert';
import 'dart:io';

import 'package:json_ast_proto/ast.dart';
import 'package:json_ast_proto/parser.dart';

class AstLoadResult {
  final JsonAstNode? root;
  final List<ParseDiagnostic> diagnostics;
  final String rawText;
  AstLoadResult(this.root, this.diagnostics, this.rawText);

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
    final src = utf8.decode(bytes);
    final parsed = Parser.parse(src);
    return AstLoadResult(parsed.root, parsed.diagnostics, src);
  }
}
