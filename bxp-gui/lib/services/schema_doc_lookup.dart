/// Pure helper for looking up a `bxp-fmt --docs` config-schema entry
/// by path. Shared by `TraceStore.findSchemaDoc`, `DartValidator`'s
/// internal walker, and json_tree's `_SchemaTooltipKey`.
///
/// Schema entries are JSON objects with a `'key'` field holding a
/// dot-separated pattern. A `*` segment is a wildcard for one path
/// element, so `"conversion_templates.*.data_dir"` matches every
/// template's `data_dir`. Returns the first hit, or `null` when no
/// pattern matches (or the schema is empty / docs haven't loaded).
library;

Map<String, dynamic>? findSchemaDocIn(
  List<Map<String, dynamic>> schema,
  List<String> path,
) {
  if (path.isEmpty) return null;
  for (final f in schema) {
    final pattern = f['key']?.toString() ?? '';
    final segs = pattern.split('.');
    if (segs.length != path.length) continue;
    var ok = true;
    for (var i = 0; i < segs.length; i++) {
      if (segs[i] == '*') continue;
      if (segs[i] != path[i]) {
        ok = false;
        break;
      }
    }
    if (ok) return f;
  }
  return null;
}
