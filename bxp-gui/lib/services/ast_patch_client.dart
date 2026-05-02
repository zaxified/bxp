/// AST-based config patcher invoked from `TraceStore.saveConfig` and
/// `_validateConfigNow`.
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

import 'dev_trace.dart';
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
    devTrace('astPatch.start',
        {'rawBytes': rawInput.length, 'opCount': ops.length});
    final src = utf8.decode(rawInput);
    final parsed = Parser.parse(src);
    if (parsed.root == null || parsed.hasErrors) {
      final first = parsed.diagnostics.isNotEmpty
          ? parsed.diagnostics.first.message
          : 'unknown parse error';
      devTrace('astPatch.parseFail', {'message': first});
      throw AstPatchError('parse failed: $first');
    }
    final root = parsed.root!;
    for (var i = 0; i < ops.length; i++) {
      final op = ops[i];
      try {
        applyConfigOp(root, op);
      } on AstOpError catch (e) {
        devTrace('astPatch.opFail', {
          'opIndex': i,
          'opType': op.runtimeType.toString(),
          'message': e.message,
          'opPath': e.path,
        });
        throw AstPatchError(e.toString());
      } on AstPathError catch (e) {
        devTrace('astPatch.pathFail', {
          'opIndex': i,
          'opType': op.runtimeType.toString(),
          'message': e.message,
          'opPath': e.path,
        });
        throw AstPatchError(e.toString());
      }
    }
    final out = Dumper.dump(root);
    devTrace('astPatch.ok',
        {'outBytes': out.length, 'opCount': ops.length});
    return Uint8List.fromList(utf8.encode(out));
  }
}
