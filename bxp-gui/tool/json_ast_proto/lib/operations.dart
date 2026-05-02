import 'ast.dart';
import 'path.dart';
import 'value_builder.dart';

/// Thrown by mutation ops when the requested edit is rejected (e.g. moving
/// past the array bounds, duplicating into a Map without a fresh key).
class AstOpError implements Exception {
  final String message;
  final List<String>? path;
  AstOpError(this.message, [this.path]);
  @override
  String toString() =>
      path == null ? 'AstOpError: $message' : 'AstOpError(path=$path): $message';
}

// --------------------------------------------------------------------------
// EditValueOp — replace a scalar leaf at `path` with `newValue`.
// --------------------------------------------------------------------------

void setValue(JsonAstNode root, List<String> path, JsonAstNode newValue) {
  if (path.isEmpty) {
    throw AstOpError('cannot replace root via setValue', path);
  }
  final ref = resolveParent(root, path);
  if (ref.parent is JsonObject) {
    final prop = ref.children[ref.index] as JsonProperty;
    // Preserve leading/trailing comments on the property; only the value
    // changes.
    prop.value = newValue;
  } else {
    final old = ref.children[ref.index];
    // Inherit leading/trailing comments from the replaced element so the
    // surrounding visual layout doesn't shift.
    newValue.leadingComments
      ..clear()
      ..addAll(old.leadingComments);
    newValue.trailingComment = old.trailingComment;
    ref.children[ref.index] = newValue;
  }
}

/// Convenience: build an AST from a plain Dart value and call [setValue].
void setValueFromPlain(JsonAstNode root, List<String> path, Object? newValue) {
  setValue(root, path, astFromValue(newValue));
}

// --------------------------------------------------------------------------
// DeleteOp — remove a Map property or List element at `path`.
// --------------------------------------------------------------------------

void deleteAt(JsonAstNode root, List<String> path) {
  if (path.isEmpty) {
    throw AstOpError('cannot delete root', path);
  }
  final ref = resolveParent(root, path);
  ref.children.removeAt(ref.index);
}

// --------------------------------------------------------------------------
// DuplicateOp — clone the entry at `path` and insert it right after.
// For Maps: caller must supply `newKey` (the duplicate must have a unique
// key). For Lists: `newKey` is ignored.
// --------------------------------------------------------------------------

JsonAstNode duplicateAt(JsonAstNode root, List<String> path, {String? newKey}) {
  if (path.isEmpty) {
    throw AstOpError('cannot duplicate root', path);
  }
  final ref = resolveParent(root, path);
  if (ref.parent is JsonObject) {
    final orig = ref.children[ref.index] as JsonProperty;
    if (newKey == null) {
      throw AstOpError('Map duplicate requires newKey', path);
    }
    if (_findPropertyIndex(ref.parent as JsonObject, newKey) >= 0) {
      throw AstOpError("Map duplicate: key '$newKey' already exists", path);
    }
    final clone = orig.clone();
    clone.key = newKey;
    ref.children.insert(ref.index + 1, clone);
    return clone;
  } else {
    final orig = ref.children[ref.index];
    final clone = orig.clone();
    ref.children.insert(ref.index + 1, clone);
    return clone;
  }
}

// --------------------------------------------------------------------------
// MoveOp — swap the entry at `path` with its previous (-1) or next (+1)
// real sibling. CommentLine pseudo-entries are skipped (they don't move
// independently; for arrays a leading CommentLine attached to the moved
// element rides along — see _moveArrayElement).
// --------------------------------------------------------------------------

void moveAt(JsonAstNode root, List<String> path, int delta) {
  if (delta != 1 && delta != -1) {
    throw AstOpError('move delta must be -1 or +1, got $delta', path);
  }
  final ref = resolveParent(root, path);
  if (ref.parent is JsonObject) {
    _moveObjectProperty(ref.parent as JsonObject, ref.index, delta, path);
  } else {
    _moveArrayElement(ref.parent as JsonArray, ref.index, delta, path);
  }
}

/// In a JsonObject, swap two adjacent JsonProperty entries (skipping
/// CommentLine pseudo-entries between them — they stay where they are).
void _moveObjectProperty(
    JsonObject obj, int rawIdx, int delta, List<String> path) {
  final targetRaw = _nextSiblingIndex(
      obj.properties, rawIdx, delta,
      isReal: (n) => n is JsonProperty);
  if (targetRaw < 0) {
    throw AstOpError('move out of bounds', path);
  }
  final tmp = obj.properties[rawIdx];
  obj.properties[rawIdx] = obj.properties[targetRaw];
  obj.properties[targetRaw] = tmp;
}

/// In a JsonArray, swap two adjacent real elements. Any CommentLine
/// pseudo-entries between them shift around so they remain adjacent to
/// their original sibling: leading comments hanging off the moved element
/// (i.e. CommentLine entries immediately before it in source order) move
/// with it. This matches user expectation for "move row up/down".
void _moveArrayElement(
    JsonArray arr, int rawIdx, int delta, List<String> path) {
  final targetRaw = _nextSiblingIndex(
      arr.elements, rawIdx, delta,
      isReal: (n) => n is! CommentLine);
  if (targetRaw < 0) {
    throw AstOpError('move out of bounds', path);
  }
  // Group A = leading comments + the moved element at rawIdx.
  // Group B = leading comments + the swap target at targetRaw.
  // Swap groups in place. Order is preserved within each group.
  final aStart = _groupStart(arr.elements, rawIdx);
  final aEnd = rawIdx; // inclusive
  final bStart = _groupStart(arr.elements, targetRaw);
  final bEnd = targetRaw; // inclusive

  if (delta == 1) {
    // A is before B. Splice them.
    final aSlice = arr.elements.sublist(aStart, aEnd + 1);
    final bSlice = arr.elements.sublist(bStart, bEnd + 1);
    arr.elements.replaceRange(aStart, bEnd + 1, [...bSlice, ...aSlice]);
  } else {
    // delta == -1, B is before A.
    final bSlice = arr.elements.sublist(bStart, bEnd + 1);
    final aSlice = arr.elements.sublist(aStart, aEnd + 1);
    arr.elements.replaceRange(bStart, aEnd + 1, [...aSlice, ...bSlice]);
  }
}

/// Walk backwards from `rawIdx` and include any contiguous CommentLine
/// pseudo-entries directly before — these are the "leading comments"
/// belonging to the element at `rawIdx` in source layout terms.
int _groupStart(List<JsonAstNode> entries, int rawIdx) {
  var s = rawIdx;
  while (s > 0 && entries[s - 1] is CommentLine) {
    s--;
  }
  return s;
}

/// Find the index of the next sibling in `entries` from `rawIdx` going by
/// `delta` (±1), skipping entries for which `isReal` is false. Returns -1
/// if no such sibling exists.
int _nextSiblingIndex(
  List<JsonAstNode> entries,
  int rawIdx,
  int delta, {
  required bool Function(JsonAstNode) isReal,
}) {
  var i = rawIdx + delta;
  while (i >= 0 && i < entries.length) {
    if (isReal(entries[i])) return i;
    i += delta;
  }
  return -1;
}

// --------------------------------------------------------------------------
// InsertOp (Map / List) — add a fresh entry into the parent.
// --------------------------------------------------------------------------

/// Insert a Map property. If `atIndex` is null, append after the last
/// existing JsonProperty (CommentLine pseudo-entries at the tail stay
/// after the new property — matching old `_applyInsert` behaviour).
void insertProperty(
  JsonAstNode root,
  List<String> parentPath,
  String key,
  JsonAstNode value, {
  int? atIndex,
}) {
  final parent = parentPath.isEmpty ? root : resolveNode(root, parentPath);
  if (parent is! JsonObject) {
    throw AstOpError(
        'insertProperty: parent at $parentPath is not an object', parentPath);
  }
  if (_findPropertyIndex(parent, key) >= 0) {
    throw AstOpError("insertProperty: key '$key' already exists", parentPath);
  }
  final prop = JsonProperty(key, value);
  if (atIndex != null) {
    if (atIndex < 0 || atIndex > parent.properties.length) {
      throw AstOpError('insertProperty: atIndex out of range', parentPath);
    }
    parent.properties.insert(atIndex, prop);
  } else {
    final lastReal = _lastRealPropertyIndex(parent.properties);
    parent.properties.insert(lastReal + 1, prop);
  }
}

/// Insert a List element at real-index `index` (clamped to end).
void insertElement(
  JsonAstNode root,
  List<String> parentPath,
  int index,
  JsonAstNode value,
) {
  final parent = parentPath.isEmpty ? root : resolveNode(root, parentPath);
  if (parent is! JsonArray) {
    throw AstOpError(
        'insertElement: parent at $parentPath is not an array', parentPath);
  }
  final realCount = realElementCount(parent.elements);
  final clamped = index < 0 ? 0 : (index > realCount ? realCount : index);
  if (clamped == realCount) {
    parent.elements.add(value);
    return;
  }
  final raw = _realIndexToRawIndex(parent.elements, clamped);
  parent.elements.insert(raw, value);
}

// --------------------------------------------------------------------------
// Comment ops — edit / delete / insert.
// --------------------------------------------------------------------------

void editComment(JsonAstNode root, List<String> path, String newText) {
  final loc = _resolveCommentByPath(root, path);
  loc.replaceText(newText);
}

void deleteComment(JsonAstNode root, List<String> path) {
  final loc = _resolveCommentByPath(root, path);
  loc.delete();
}

/// Insert a leading comment immediately before the entry at `anchorPath`.
/// For Map property anchors: prepends to `JsonProperty.leadingComments`
/// (well — appends, so it becomes the last leading comment, closest to
/// the property in source order). For Array element anchors: inserts a
/// CommentLine pseudo-entry right before the element.
///
/// Choice rationale: the existing UI ("insert comment above this row")
/// always means a NEW comment placed adjacent to the anchor. Map vs List
/// is a structural detail — both produce the same visual outcome.
void insertLeadingComment(
  JsonAstNode root,
  List<String> anchorPath,
  CommentStyle style,
  String text,
) {
  if (anchorPath.isEmpty) {
    throw AstOpError(
        'insertLeadingComment: anchor path empty (cannot attach to root)',
        anchorPath);
  }
  final ref = resolveParent(root, anchorPath);
  final newComment = CommentNode(style, text);
  if (ref.parent is JsonObject) {
    final prop = ref.children[ref.index] as JsonProperty;
    prop.leadingComments.add(newComment);
  } else {
    ref.children.insert(ref.index, CommentLine(newComment));
  }
}

CommentLocation _resolveCommentByPath(JsonAstNode root, List<String> path) {
  if (path.isEmpty || !path.last.startsWith(r'$comm_')) {
    throw AstOpError(
        'comment op requires path ending in \$comm_<N>', path);
  }
  final n = int.tryParse(path.last.substring(r'$comm_'.length));
  if (n == null) {
    throw AstOpError("invalid \$comm_N segment '${path.last}'", path);
  }
  final loc = findCommentByGlobalN(root, n);
  if (loc == null) {
    throw AstOpError('no comment with global N=$n', path);
  }
  return loc;
}

// --------------------------------------------------------------------------
// Helpers shared with path.dart equivalents.
// --------------------------------------------------------------------------

int _findPropertyIndex(JsonObject obj, String key) {
  for (var i = 0; i < obj.properties.length; i++) {
    final e = obj.properties[i];
    if (e is JsonProperty && e.key == key) return i;
  }
  return -1;
}

int _realIndexToRawIndex(List<JsonAstNode> elements, int n) {
  var seen = 0;
  for (var i = 0; i < elements.length; i++) {
    if (elements[i] is CommentLine) continue;
    if (seen == n) return i;
    seen++;
  }
  return -1;
}

int _lastRealPropertyIndex(List<JsonAstNode> entries) {
  for (var i = entries.length - 1; i >= 0; i--) {
    if (entries[i] is JsonProperty) return i;
  }
  return -1;
}
