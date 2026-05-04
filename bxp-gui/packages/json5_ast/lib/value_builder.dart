import 'ast.dart';

/// Convert a plain Dart value (String / num / bool / null / Map / List)
/// into the corresponding JsonAstNode subtree. Used by `setValue` and
/// `insertProperty` / `insertElement` callers who carry user-supplied
/// scalars rather than pre-built AST nodes.
///
/// Map order is preserved (Dart Maps iterate in insertion order).
/// Numbers are converted to their Dart `.toString()` form, which loses
/// "1.00" → "1" for non-integral display; if you need an exact rawText
/// (e.g. preserving trailing zeros after Save → reload), construct a
/// JsonNumber directly.
///
/// Nesting deeper than [_kMaxDepth] throws [ArgumentError]. Real configs
/// stay well below this; the limit guards against accidental cyclic
/// structures that would otherwise stack-overflow.
JsonAstNode astFromValue(Object? v) => _astFromValue(v, 0);

const int _kMaxDepth = 64;

JsonAstNode _astFromValue(Object? v, int depth) {
  if (depth > _kMaxDepth) {
    throw ArgumentError('astFromValue: nesting deeper than $_kMaxDepth');
  }
  if (v == null) return JsonNull();
  if (v is bool) return JsonBool(v);
  if (v is num) return JsonNumber(v.toString());
  if (v is String) return JsonString(v);
  if (v is JsonAstNode) return v.clone();
  if (v is Map) {
    final obj = JsonObject();
    v.forEach((k, val) {
      obj.properties.add(JsonProperty(k.toString(), _astFromValue(val, depth + 1)));
    });
    return obj;
  }
  if (v is List) {
    final arr = JsonArray();
    for (final el in v) {
      arr.elements.add(_astFromValue(el, depth + 1));
    }
    return arr;
  }
  throw ArgumentError('astFromValue: unsupported type ${v.runtimeType}');
}
