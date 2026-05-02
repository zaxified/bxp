/// Phase 2 entry point for the new AST-based config patcher.
///
/// Mirrors the public surface of [OpApply.apply] in `op_apply.dart` so the
/// `saveConfig` call site can swap implementations behind a feature flag
/// without further changes.
///
/// Pipeline: rawBytes → parse to JsonAstNode → replay [ConfigOp] log via
/// `applyConfigOp` → deterministic dump → UTF-8 bytes. No spans, no byte
/// patching, no `$meta_*` aparát.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:json_ast_proto/dumper.dart';
import 'package:json_ast_proto/operations.dart';
import 'package:json_ast_proto/parser.dart';
import 'package:json_ast_proto/path.dart';

import 'op_log.dart';
import 'op_to_ast.dart';

class AstPatchError implements Exception {
  final String message;
  AstPatchError(this.message);
  @override
  String toString() => 'AstPatchError: $message';
}

class AstPatchClient {
  /// Apply [ops] to [rawInput] and return the resulting bytes.
  ///
  /// Throws [AstPatchError] if the source can't be parsed or any op
  /// rejects the mutation; the trace_store save path catches this and
  /// surfaces it through `configSaveError` like the legacy patcher does.
  static Uint8List apply(List<int> rawInput, List<ConfigOp> ops) {
    final src = utf8.decode(rawInput);
    final parsed = Parser.parse(src);
    if (parsed.root == null || parsed.hasErrors) {
      final first = parsed.diagnostics.isNotEmpty
          ? parsed.diagnostics.first.message
          : 'unknown parse error';
      throw AstPatchError('parse failed: $first');
    }
    final root = parsed.root!;
    try {
      applyAll(root, ops);
    } on AstOpError catch (e) {
      throw AstPatchError(e.toString());
    } on AstPathError catch (e) {
      throw AstPatchError(e.toString());
    }
    final out = Dumper.dump(root);
    return Uint8List.fromList(utf8.encode(out));
  }
}
