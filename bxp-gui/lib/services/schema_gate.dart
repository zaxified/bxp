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

import 'package:json5_ast/ast.dart';

import '../store/trace_store.dart';
import 'schema_doc_lookup.dart';

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

/// Schema-aware UI advisor.
///
/// Consumes `TraceStore.findSchemaDoc` and `TraceStore.docConfigSchema`
/// (populated from `bxp-fmt --docs`) to answer structural questions about
/// a given tree path without coupling individual UI widgets to the raw docs
/// format. The policy throughout is **permissive by default**: if the path
/// is uncovered by the schema (e.g. user-authored broker-specific keys),
/// every operation is allowed.
class SchemaGate {
  final TraceStore store;
  SchemaGate(this.store);

  /// True when [path] resolves to a schema entry NOT marked `required`,
  /// or no schema match at all (free-form). False when explicitly required.
  ///
  /// Permissive-by-default policy: `findSchemaDoc` returns null for every
  /// non-schema-covered path (template-internal user keys, expression
  /// values, broker-specific blocks). Treating that as "may delete" lets
  /// the user freely edit their own data and reserves rejection for paths
  /// the schema explicitly protects. There is intentionally no `canEdit`
  /// gate here — value editing is always allowed; the schema only
  /// constrains structure (presence/order/required-ness), not contents.
  ///
  /// Wildcard-slot caveat: when the path's last segment matched a schema
  /// wildcard (`*`), the schema entry's `required: true` refers to the
  /// slot's VALUE (the expression must be non-empty), not to the entry's
  /// presence in the parent map. User-named children of wildcards (e.g.
  /// `input_schema.$ticker`, `output_schema.symbol`, `pre_pass.values.foo`)
  /// are always free to remove — the validator will flag the absence
  /// downstream if it matters.
  bool canDelete(List<String> path) {
    final match = findSchemaDocMatchIn(store.docConfigSchema, path);
    if (match.doc == null) return true;
    if (match.wildcardLast) return true;
    return match.doc!['required'] != true;
  }

  /// True when the parent at [parentPath] is `ordered` (or has no schema
  /// at all — default permissive). Lists are always orderable.
  ///
  /// Same permissive-by-default policy as [canDelete]: schema-uncovered
  /// parents (e.g. inside user-authored row rules or input_schema) accept
  /// reordering because the user owns those keys. Explicit `ordered: true`
  /// on a schema entry opts a Map into reordering; absence keeps Map
  /// reordering off (alphabetical / canonical Map keys are usually
  /// cosmetic, not semantic).
  bool canMove(List<String> parentPath, {required bool isList}) {
    if (isList) return true;
    final doc = store.findSchemaDoc(parentPath);
    if (doc == null) return true;
    return doc['ordered'] == true;
  }

  /// Field's enum_values, if the schema declares them.
  ///
  /// Used to populate dropdown pickers in the tree editor; returns null
  /// when the field accepts free-form strings.
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
    // Compute the candidate list once — the previous version re-ran
    // `validInsertKeys` to find a wildcard fallback, doubling the schema
    // walk on every literal-match miss (the common case for free-form
    // child keys like ticker_maps[*] or row_rules[*]).
    final candidates = validInsertKeys(parentPath, existingKeys);
    for (final c in candidates) {
      if (c.key == key) return c;
    }
    // Wildcard fallback: no literal match, but a `*` candidate covers any name.
    return candidates.where((c) => c.isFreeForm).firstOrNull;
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
      // Walk the raw peer list (includes CommentLines) but compare only
      // JsonProperty nodes. The first real key that sorts strictly after
      // `newKey` is the insertion point.
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
      // docConfigSchema becomes the canonical index — the for-i loop here
      // ensures `seqIdx` always tracks list position, regardless of which
      // arm of the filter we hit.
      final canonical = <String, int>{};
      var wildcardIdx = 1 << 30;
      final schema = store.docConfigSchema;
      for (var seqIdx = 0; seqIdx < schema.length; seqIdx++) {
        final f = schema[seqIdx];
        final pattern = f['key']?.toString() ?? '';
        final segs = pattern.split('.');
        if (segs.length != parentPath.length + 1) continue;
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
      }

      // Keys not declared in the schema are treated as if they follow all
      // schema-declared keys (`wildcardIdx = 1 << 30`). This places unknown
      // (broker-specific / user-authored) entries after schema-managed ones.
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

// Polyfill for `Iterable.firstOrNull` — not available before Dart 3.3
// and the SDK constraint in pubspec.yaml currently targets Dart 3.x only.
// Can be removed once the min SDK raises above 3.3 and the stdlib version
// is preferred throughout.
extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
