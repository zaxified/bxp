/// Phase 5b: schema-aware UI advisor backed by `bxp-fmt --docs` config
/// schema. Centralises the "what may the user do here" rules so each UI
/// button (delete, dup, move, insert, edit) consults one helper instead
/// of replicating doc-lookup logic.
///
/// Wraps the existing `TraceStore.findSchemaDoc(path)` primitive — that
/// stays the underlying data source. Existing call sites continue to use
/// `findSchemaDoc(...)['xxx']` directly; new gates land here.
library;

import '../store/trace_store.dart';

/// Suggestion entry for the "Add property" dropdown.
class InsertKeyCandidate {
  /// The key name. Empty string `""` means "user names this key freely"
  /// (the FnDoc has a `*` wildcard at this position).
  final String key;
  final String typeName;
  final bool required;
  final Object? defaultValue;
  final String? description;
  final List<String>? enumValues;
  const InsertKeyCandidate({
    required this.key,
    required this.typeName,
    required this.required,
    this.defaultValue,
    this.description,
    this.enumValues,
  });

  bool get isFreeForm => key.isEmpty;
}

class SchemaGate {
  final TraceStore store;
  SchemaGate(this.store);

  /// True when [path] resolves to a schema entry NOT marked `required`,
  /// or no schema match at all (free-form). False when explicitly required.
  bool canDelete(List<String> path) {
    final doc = store.findSchemaDoc(path);
    if (doc == null) return true;
    return doc['required'] != true;
  }

  /// True when the parent at [parentPath] is `ordered` (or has no schema
  /// at all — default permissive). Lists are always orderable.
  bool canMove(List<String> parentPath, {required bool isList}) {
    if (isList) return true;
    final doc = store.findSchemaDoc(parentPath);
    if (doc == null) return true;
    return doc['ordered'] == true;
  }

  /// Field's enum_values, if the schema declares them.
  List<String>? enumValuesFor(List<String> path) {
    final doc = store.findSchemaDoc(path);
    return (doc?['enum_values'] as List?)?.cast<String>();
  }

  /// Field's type_name (e.g. "string", "number", "boolean", "object",
  /// "array"), or null when the schema doesn't cover this path.
  String? typeNameFor(List<String> path) =>
      store.findSchemaDoc(path)?['type_name']?.toString();

  /// Default value for a fresh insert at [path], if FnDoc supplies one.
  Object? defaultValueFor(List<String> path) =>
      store.findSchemaDoc(path)?['default'];

  /// Candidate keys the user may add into the Map at [parentPath]. Each
  /// candidate is either a literal name (e.g. `data_dir`) or a free-form
  /// wildcard (`key == ""`, meaning the user names it).
  ///
  /// Already-present keys are filtered out so the dropdown doesn't offer
  /// duplicates. [parentChildren] is the current Map contents (used to
  /// skip existing keys); pass `configJson` Map at [parentPath].
  ///
  /// Returns empty list if no schema covers this parent path — the caller
  /// should fall back to a free-form text input.
  List<InsertKeyCandidate> validInsertKeys(
      List<String> parentPath, Map<String, dynamic> parentChildren) {
    final out = <InsertKeyCandidate>[];
    final seen = <String>{};
    for (final f in store.docConfigSchema) {
      final pattern = f['key']?.toString() ?? '';
      final segs = pattern.split('.');
      if (segs.length != parentPath.length + 1) continue;
      // Match parent prefix (with `*` wildcard semantics).
      var ok = true;
      for (var i = 0; i < parentPath.length; i++) {
        if (segs[i] == '*') continue;
        if (segs[i] != parentPath[i]) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final lastSeg = segs.last;
      final key = lastSeg == '*' ? '' : lastSeg;
      if (key.isNotEmpty && parentChildren.containsKey(key)) continue;
      if (!seen.add(key)) continue;
      out.add(InsertKeyCandidate(
        key: key,
        typeName: f['type_name']?.toString() ?? 'string',
        required: f['required'] == true,
        defaultValue: f['default'],
        description: f['description']?.toString(),
        enumValues: (f['enum_values'] as List?)?.cast<String>(),
      ));
    }
    return out;
  }

  /// Returns the InsertKeyCandidate for a specific [key] under [parentPath]
  /// — useful when the caller already knows the key (e.g. from dropdown
  /// selection) and wants the metadata to scaffold a default value.
  InsertKeyCandidate? candidateFor(
      List<String> parentPath, String key, Map<String, dynamic> parentChildren) {
    for (final c in validInsertKeys(parentPath, parentChildren)) {
      if (c.key == key) return c;
    }
    // Wildcard fallback: no literal match, but a `*` candidate covers any name.
    final wildcard = validInsertKeys(parentPath, parentChildren)
        .where((c) => c.isFreeForm)
        .firstOrNull;
    return wildcard;
  }

  /// Default Dart value for a fresh insert based on a candidate's typeName.
  static Object? scaffoldFor(InsertKeyCandidate c) {
    if (c.defaultValue != null) return c.defaultValue;
    switch (c.typeName) {
      case 'string':
        return '';
      case 'number':
        return 0;
      case 'boolean':
        return false;
      case 'object':
        return <String, dynamic>{};
      case 'array':
        return <dynamic>[];
      default:
        return '';
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
