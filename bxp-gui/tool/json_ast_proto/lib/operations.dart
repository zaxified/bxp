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
    // Phase 5e: trailing inline comments live as adjacent CommentLine
    // entries in the container, NOT as a slot on the entry being replaced.
    // So a List setValue is just an in-place swap; the comment row that
    // followed the old element automatically follows the new one too.
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
// container neighbour. Neighbours can be real props/elements OR CommentLine
// pseudo-entries; both types are peers in the container after Phase 4's
// model unification. This matches the bxp-fmt's flat row model that the GUI
// uses for the live tree.
// --------------------------------------------------------------------------

void moveAt(JsonAstNode root, List<String> path, int delta) {
  if (delta != 1 && delta != -1) {
    throw AstOpError('move delta must be -1 or +1, got $delta', path);
  }
  // Comment moves use the global $comm_<N> last segment. Dispatch to the
  // dedicated walker — the path's prefix is informative but not needed
  // for the swap itself (the walker's CommentLocation knows the container).
  if (path.isNotEmpty && path.last.startsWith(r'$comm_')) {
    moveCommentAt(root, path, delta);
    return;
  }
  final ref = resolveParent(root, path);
  _swapContainerEntries(ref.children, ref.index, ref.index + delta, path);
}

/// Swap two container entries by raw index. Either side may be a CommentLine
/// or a JsonProperty / element — they are peers in the container.
void _swapContainerEntries(
    List<JsonAstNode> children, int aIdx, int bIdx, List<String> path) {
  if (bIdx < 0 || bIdx >= children.length) {
    throw AstOpError('move out of bounds', path);
  }
  final tmp = children[aIdx];
  children[aIdx] = children[bIdx];
  children[bIdx] = tmp;
}

/// Move a comment (addressed via `$comm_<N>` last segment) ±1 row in its
/// container. Trailing inline comments are not movable — they belong to a
/// specific row's value.
void moveCommentAt(JsonAstNode root, List<String> path, int delta) {
  if (path.isEmpty || !path.last.startsWith(r'$comm_')) {
    throw AstOpError('moveCommentAt requires \$comm_<N> last segment', path);
  }
  final n = int.tryParse(path.last.substring(r'$comm_'.length));
  if (n == null) {
    throw AstOpError("invalid \$comm_N segment '${path.last}'", path);
  }
  final loc = findCommentByGlobalN(root, n);
  if (loc == null) {
    throw AstOpError('no comment with global N=$n', path);
  }
  // Phase 5e: comment is always a CommentLine peer entry (standalone OR
  // inline-trailing). Move = swap with adjacent container entry — uniform
  // with how real props/elements move. The inlinePlacement flag travels
  // with the comment; the dumper handles whether to render on its own row
  // or attached to whatever it now neighbours.
  final children = loc.container is JsonObject
      ? (loc.container as JsonObject).properties
      : (loc.container as JsonArray).elements;
  _swapContainerEntries(children, loc.containerIndex,
      loc.containerIndex + delta, path);
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

/// Insert a List element at raw `index` in `parent.elements` (clamped to
/// end). RAW indexing — `index` counts CommentLine peers, matching the
/// path convention used by the resolver and trace_store mutations.
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
  final n = parent.elements.length;
  final clamped = index < 0 ? 0 : (index > n ? n : index);
  if (clamped == n) {
    parent.elements.add(value);
    return;
  }
  parent.elements.insert(clamped, value);
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

/// Insert a CommentLine immediately before the entry at `anchorPath` in
/// its container. Works the same way for Map and List anchors — both have
/// `properties` / `elements` as ordered containers that accept CommentLine
/// pseudo-entries (Phase 4 unification).
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
  ref.children.insert(ref.index, CommentLine(newComment));
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

int _lastRealPropertyIndex(List<JsonAstNode> entries) {
  for (var i = entries.length - 1; i >= 0; i--) {
    if (entries[i] is JsonProperty) return i;
  }
  return -1;
}
