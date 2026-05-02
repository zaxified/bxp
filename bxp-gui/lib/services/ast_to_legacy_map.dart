/// Phase 5a TEMPORARY adapter: AST → bxp-fmt-shaped `Map<String, dynamic>`.
///
/// Bridges the new AST loader (Phase 5a) with the legacy UI components
/// (`json_tree`, `output_panel`, `trace_store` mutation methods) that
/// still expect bxp-fmt's annotated-tree shape — `$comm_<N>` peer keys
/// for comments, JSON-typed scalars, etc.
///
/// **Critical property:** `$comm_<N>` numbering is derived from the AST's
/// source-order walk — the SAME walk the AST patcher uses on save. So
/// `op_log` paths that the GUI records with `$comm_<3>` resolve to the
/// same physical comment that the AST patcher will mutate. End of the
/// dual-numbering cycling that plagued Phase 1–4.
///
/// `$meta_*` is NOT emitted: the AST patcher needs no spans, and Phase 3
/// already removed the last in-tree consumer.
///
/// `$err_*` is NOT emitted by this adapter — `trace_store.loadConfig`
/// merges those in from a parallel `bxp-fmt --config` run.
///
/// Phase 5c will delete this adapter; UI will walk AST directly.
library;

import 'package:json_ast_proto/ast.dart';

class AstToLegacyMap {
  /// Convert an AST root into the bxp-fmt-shaped Map / scalar tree.
  static dynamic convert(JsonAstNode root) {
    final c = _Converter();
    return c._node(root);
  }
}

class _Converter {
  int _commCounter = 0;

  dynamic _node(JsonAstNode n) {
    if (n is JsonObject) return _object(n);
    if (n is JsonArray) return _array(n);
    if (n is JsonString) return n.value;
    if (n is JsonNumber) {
      final parsed = num.tryParse(n.rawText);
      return parsed ?? n.rawText;
    }
    if (n is JsonBool) return n.value;
    if (n is JsonNull) return null;
    throw StateError('AstToLegacyMap: unexpected node ${n.runtimeType}');
  }

  Map<String, dynamic> _object(JsonObject obj) {
    final out = <String, dynamic>{};
    for (final entry in obj.properties) {
      if (entry is CommentLine) {
        _commCounter++;
        // Phase 5e: a CommentLine with inlinePlacement=true is the
        // source-level "trailing inline" comment — emit with
        // placement:'trailing' so the existing UI keeps inlining it onto
        // the preceding row. Standalone comments stay 'leading'.
        final placement = entry.inlinePlacement ? 'trailing' : 'leading';
        out['\$comm_$_commCounter'] = _commToMap(entry.comment, placement);
      } else if (entry is JsonProperty) {
        out[entry.key] = _node(entry.value);
      }
    }
    return out;
  }

  List<dynamic> _array(JsonArray arr) {
    final out = <dynamic>[];
    for (final el in arr.elements) {
      if (el is CommentLine) {
        _commCounter++;
        final placement = el.inlinePlacement ? 'trailing' : 'leading';
        out.add(<String, dynamic>{
          '\$comm_$_commCounter': _commToMap(el.comment, placement),
        });
      } else {
        out.add(_node(el));
      }
    }
    return out;
  }

  Map<String, dynamic> _commToMap(CommentNode c, String placement) {
    final marker = c.style == CommentStyle.line
        ? '//${c.text}'
        : '/*${c.text}*/';
    return {
      'text': marker,
      'placement': placement,
    };
  }
}
