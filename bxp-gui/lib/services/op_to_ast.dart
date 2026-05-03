/// Translates a [ConfigOp] log into AST mutations on a [JsonAstNode] tree.
///
/// Shape decisions (Map vs List) are made by inspecting the parent in the
/// live AST rather than carrying a discriminator on the [ConfigOp] — keeps
/// the op_log schema independent of the patcher backend.
library;

import 'package:json_ast_proto/ast.dart';
import 'package:json_ast_proto/operations.dart' as ast_ops;
import 'package:json_ast_proto/path.dart';
import 'package:json_ast_proto/value_builder.dart';

import 'op_log.dart';

/// Apply one [ConfigOp] to [root]. Throws [ast_ops.AstOpError] /
/// [AstPathError] on invalid paths or schema-violating mutations.
void applyConfigOp(JsonAstNode root, ConfigOp op) {
  switch (op) {
    case EditValueOp e:
      ast_ops.setValueFromPlain(root, e.path, e.newValue);

    case DeleteOp d:
      ast_ops.deleteAt(root, d.path);

    case DuplicateOp d:
      // For Map duplicates the GUI supplies `newKey`; for List duplicates
      // it's null. The AST helper enforces the Map-needs-newKey invariant.
      ast_ops.duplicateAt(root, d.path, newKey: d.newKey);

    case MoveOp m:
      ast_ops.moveAt(root, m.path, m.delta);

    case InsertOp i:
      _applyInsert(root, i);

    case EditCommentOp e:
      // EditCommentOp.newText carries the BODY (no // or /* */ markers),
      // matching how `editCommentNode` in trace_store stripped markers
      // before recording. CommentNode.text holds the body too — direct
      // assignment is correct.
      ast_ops.editComment(root, e.path, e.newText);

    case DeleteCommentOp d:
      ast_ops.deleteComment(root, d.path);

    case DuplicateCommentOp d:
      ast_ops.duplicateCommentAt(root, d.path);

    case InsertCommentOp i:
      final style = i.style == '/*' ? CommentStyle.block : CommentStyle.line;
      ast_ops.insertLeadingComment(root, i.anchorPath, style, i.text);

    case InsertInlineCommentOp i:
      final style = i.style == '/*' ? CommentStyle.block : CommentStyle.line;
      ast_ops.insertTrailingInlineComment(root, i.anchorPath, style, i.text);
  }
}

/// Apply a sequence of [ConfigOp]s in order.
void applyAll(JsonAstNode root, List<ConfigOp> ops) {
  for (final op in ops) {
    applyConfigOp(root, op);
  }
}

void _applyInsert(JsonAstNode root, InsertOp op) {
  // Resolve the parent to decide Map vs List — the GUI sometimes records
  // a stringified int for `keyOrIndex`, which is ambiguous without the
  // shape context.
  final parent =
      op.parentPath.isEmpty ? root : resolveNode(root, op.parentPath);
  final newValue = astFromValue(op.value);
  if (parent is JsonObject) {
    ast_ops.insertProperty(root, op.parentPath, op.keyOrIndex, newValue,
        atIndex: op.atIndex);
  } else if (parent is JsonArray) {
    final idx = int.tryParse(op.keyOrIndex);
    if (idx == null) {
      throw ast_ops.AstOpError(
          'InsertOp into list requires numeric keyOrIndex, '
          "got '${op.keyOrIndex}'",
          op.parentPath);
    }
    ast_ops.insertElement(root, op.parentPath, idx, newValue);
  } else {
    throw ast_ops.AstOpError(
        'InsertOp parent at ${op.parentPath} is ${parent.runtimeType}, '
        'expected JsonObject or JsonArray',
        op.parentPath);
  }
}
