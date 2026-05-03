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
JsonAstNode astFromValue(Object? v) {
  if (v == null) return JsonNull();
  if (v is bool) return JsonBool(v);
  if (v is num) return JsonNumber(v.toString());
  if (v is String) return JsonString(v);
  if (v is JsonAstNode) return v.clone();
  if (v is Map) {
    final obj = JsonObject();
    v.forEach((k, val) {
      obj.properties.add(JsonProperty(k.toString(), astFromValue(val)));
    });
    return obj;
  }
  if (v is List) {
    final arr = JsonArray();
    for (final el in v) {
      arr.elements.add(astFromValue(el));
    }
    return arr;
  }
  throw ArgumentError('astFromValue: unsupported type ${v.runtimeType}');
}
