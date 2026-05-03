/// Phase 5b: schema-aware UI advisor backed by `bxp-fmt --docs` config
/// schema. Centralises the "what may the user do here" rules so each UI
/// button (delete, dup, move, insert, edit) consults one helper instead
/// of replicating doc-lookup logic.
///
/// Wraps the existing `TraceStore.findSchemaDoc(path)` primitive — that
/// stays the underlying data source. Existing call sites continue to use
/// `findSchemaDoc(...)['xxx']` directly; new gates land here.
library;

import 'dart:convert';

import 'package:json_ast_proto/ast.dart';

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

  /// Phase 5f: pre-decoded scaffold value from `bxp-fmt --docs`
  /// `insert_template`. Already a Dart Map / List / scalar (the Zig side
  /// preprocessed the JSON5 source). When non-null, this is the value
  /// inserted under this candidate's key — replaces type-based defaults.
  final Object? insertTemplate;

  const InsertKeyCandidate({
    required this.key,
    required this.typeName,
    required this.required,
    this.defaultValue,
    this.description,
    this.enumValues,
    this.insertTemplate,
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
  /// duplicates. [existingKeys] is the set of property names currently
  /// present in the parent object — typically derived by the caller via
  /// `JsonObject.properties.whereType<JsonProperty>().map((p) => p.key)`.
  ///
  /// Returns empty list if no schema covers this parent path — the caller
  /// should fall back to a free-form text input.
  List<InsertKeyCandidate> validInsertKeys(
      List<String> parentPath, Set<String> existingKeys) {
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
      if (key.isNotEmpty && existingKeys.contains(key)) continue;
      if (!seen.add(key)) continue;
      out.add(InsertKeyCandidate(
        key: key,
        typeName: f['type_name']?.toString() ?? 'string',
        required: f['required'] == true,
        defaultValue: f['default'],
        description: f['description']?.toString(),
        enumValues: (f['enum_values'] as List?)?.cast<String>(),
        insertTemplate: f['insert_template'],
      ));
    }
    return out;
  }

  /// Returns the InsertKeyCandidate for a specific [key] under [parentPath]
  /// — useful when the caller already knows the key (e.g. from dropdown
  /// selection) and wants the metadata to scaffold a default value.
  InsertKeyCandidate? candidateFor(
      List<String> parentPath, String key, Set<String> existingKeys) {
    for (final c in validInsertKeys(parentPath, existingKeys)) {
      if (c.key == key) return c;
    }
    // Wildcard fallback: no literal match, but a `*` candidate covers any name.
    final wildcard = validInsertKeys(parentPath, existingKeys)
        .where((c) => c.isFreeForm)
        .firstOrNull;
    return wildcard;
  }

  /// Default Dart value for a fresh insert based on a candidate's
  /// schema metadata.
  ///
  /// Priority (highest first):
  ///   1. `insertTemplate` — Phase 5f canonical scaffold from
  ///      `--docs insert_template`. Deep-copied so the per-candidate
  ///      payload (decoded once at docs load) isn't shared between
  ///      multiple successive inserts.
  ///   2. `defaultValue` — literal `default` from schema (typically a
  ///      string for primitive fields).
  ///   3. Type-based fallback (`""` / `0` / `false` / `{}` / `[]`).
  static Object? scaffoldFor(InsertKeyCandidate c) {
    final tpl = c.insertTemplate;
    if (tpl != null) {
      // jsonDecode(jsonEncode(...)) is the standard Dart deep-copy idiom
      // for JSON-shaped trees and matches the shape we received from the
      // Zig side (Map<String,dynamic> / List<dynamic> / scalars).
      return jsonDecode(jsonEncode(tpl));
    }
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

  // ── Phase 5f canonical insert positioning ────────────────────────────

  /// Resolve the raw peer index where a new property `newKey` should
  /// land inside `parent` (the current AST object), per the parent's
  /// `insert_order` policy.
  ///
  /// Returns:
  ///   - `null` if the policy is `append` (or unset) — caller should
  ///     omit `atIndex` and the AST helper appends to the end.
  ///   - a non-null int otherwise — raw index into `parent.properties`
  ///     (which counts `CommentLine` peers alongside real `JsonProperty`
  ///     entries; the conversion from real-key position to raw peer
  ///     index happens here so callers don't need to think about it).
  ///
  /// Behaviour by `insert_order`:
  ///   - `alpha` — alphabetic by key. New entry goes immediately before
  ///     the first existing real key whose name sorts strictly after
  ///     `newKey`. If none does, `null` (append).
  ///   - `schema` — declaration order in `docConfigSchema`. The wildcard
  ///     children of `parentPath` carry implicit order via their position
  ///     in the schema array; new entry goes immediately before the first
  ///     existing real key with a higher canonical index. If none does,
  ///     `null` (append). Keys absent from schema (free-form) are placed
  ///     last by treating their canonical index as +infinity.
  int? insertIndexFor(
      List<String> parentPath, String newKey, JsonObject parent) {
    final doc = store.findSchemaDoc(parentPath);
    final order = doc?['insert_order']?.toString();
    if (order == null || order == 'append') return null;

    if (order == 'alpha') {
      for (var i = 0; i < parent.properties.length; i++) {
        final p = parent.properties[i];
        if (p is JsonProperty && p.key.compareTo(newKey) > 0) return i;
      }
      return null;
    }

    if (order == 'schema') {
      // Build "key → canonical index" map by scanning every FieldDoc that
      // is a direct child of parentPath (path length = parentPath.length+1
      // and matches via `*` wildcard semantics). The position in
      // docConfigSchema becomes the canonical index.
      final canonical = <String, int>{};
      var wildcardIdx = 1 << 30;
      var seqIdx = 0;
      for (final f in store.docConfigSchema) {
        final pattern = f['key']?.toString() ?? '';
        final segs = pattern.split('.');
        if (segs.length != parentPath.length + 1) {
          seqIdx++;
          continue;
        }
        var matches = true;
        for (var i = 0; i < parentPath.length; i++) {
          if (segs[i] == '*') continue;
          if (segs[i] != parentPath[i]) {
            matches = false;
            break;
          }
        }
        if (matches) {
          final last = segs.last;
          if (last == '*') {
            wildcardIdx = seqIdx;
          } else {
            canonical[last] = seqIdx;
          }
        }
        seqIdx++;
      }

      final newIdx = canonical[newKey] ?? wildcardIdx;
      for (var i = 0; i < parent.properties.length; i++) {
        final p = parent.properties[i];
        if (p is JsonProperty) {
          final existingIdx = canonical[p.key] ?? wildcardIdx;
          if (existingIdx > newIdx) return i;
        }
      }
      return null;
    }

    return null;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
