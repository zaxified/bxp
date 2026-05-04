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
    // Phase 4F.1: array path resolves by raw index (counts CommentLine
    // peers). Refuse to overwrite a CommentLine peer — silent
    // replacement would lose the comment text. Callers wanting to
    // edit a comment should use the `$comm_<N>` path with
    // editCommentNode / replaceText.
    if (ref.children[ref.index] is CommentLine) {
      throw AstOpError(
          'cannot setValue over a CommentLine peer at array index '
          "'${path.last}' — use \$comm_<N> path for comment ops",
          path);
    }
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
  // Phase 4F.1: refuse to delete a CommentLine peer via numeric array
  // index — `deleteAt` is for real entries; comment removal goes
  // through `deleteComment` with a `$comm_<N>` path.
  if (ref.parent is JsonArray && ref.children[ref.index] is CommentLine) {
    throw AstOpError(
        'cannot deleteAt over a CommentLine peer at array index '
        "'${path.last}' — use \$comm_<N> path for comment ops",
        path);
  }
  // Phase 5e made every comment a peer entry, so a deleted row's leading
  // and trailing comments are siblings — not part of the JsonProperty.
  // Remove them too, otherwise a `// doc-for-row-X` re-attaches visually
  // to whatever sibling follows once X is gone (silent doc corruption).
  //
  // Convention: any contiguous run of CommentLine peers immediately
  // *preceding* the deleted entry, with `inlinePlacement == false`,
  // belongs to it (until the previous real entry or container start).
  // A single CommentLine immediately *after* with `inlinePlacement == true`
  // is the row's trailing inline comment.
  var start = ref.index;
  while (start > 0) {
    final prev = ref.children[start - 1];
    if (prev is! CommentLine || prev.inlinePlacement) break;
    start -= 1;
  }
  var endExclusive = ref.index + 1;
  if (endExclusive < ref.children.length) {
    final next = ref.children[endExclusive];
    if (next is CommentLine && next.inlinePlacement) {
      endExclusive += 1;
    }
  }
  ref.children.removeRange(start, endExclusive);
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
  // Phase 4F.1: array branch never targets a CommentLine peer for
  // duplication — a comment dup goes through duplicateCommentAt.
  if (ref.parent is JsonArray && ref.children[ref.index] is CommentLine) {
    throw AstOpError(
        'cannot duplicateAt over a CommentLine peer at array index '
        "'${path.last}' — use \$comm_<N> path for comment ops",
        path);
  }

  // Phase 4F.4: if the original has a trailing-inline CommentLine
  // peer immediately after it, clone that comment too. Without this
  // fix the dumper's "attach inline-trail to nearest preceding row"
  // rule silently transfers the comment from the original to the
  // duplicate (steal). With the clone in place both rows render
  // their own copy.
  CommentLine? trailingClone;
  final trailingIdx = ref.index + 1;
  if (trailingIdx < ref.children.length) {
    final next = ref.children[trailingIdx];
    if (next is CommentLine && next.inlinePlacement) {
      trailingClone = next.clone();
    }
  }

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
    if (trailingClone != null) {
      // Order: orig, trailing-orig (already in place), clone, trailing-clone.
      ref.children.insert(ref.index + 2, clone);
      ref.children.insert(ref.index + 3, trailingClone);
    } else {
      ref.children.insert(ref.index + 1, clone);
    }
    return clone;
  } else {
    final orig = ref.children[ref.index];
    final clone = orig.clone();
    if (trailingClone != null) {
      ref.children.insert(ref.index + 2, clone);
      ref.children.insert(ref.index + 3, trailingClone);
    } else {
      ref.children.insert(ref.index + 1, clone);
    }
    return clone;
  }
}

// --------------------------------------------------------------------------
// MoveOp — swap the entry at `path` with its previous (-1) or next (+1)
// container neighbour. Neighbours can be real props/elements OR CommentLine
// pseudo-entries; both types are peers in the container after Phase 4's
// model unification. This matches the bxp-fmt's flat row model that the GUI
// uses for the live tree.
//
// Phase 4F.5: this is a *raw-peer* swap — if the neighbour is a
// CommentLine, the comment moves up/down through the container the same
// way a real entry would. Callers who want "move past the next real
// entry" semantics (skipping comment peers) must build that wrapper on
// top — `moveAt` deliberately keeps a single, simple swap policy so the
// `$comm_<N>` move flow can share the same implementation.
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

/// Clone the comment addressed by `path` (last segment `$comm_<N>`) and
/// insert the copy as the next peer in the same container. Mirrors
/// [duplicateAt]'s "insert right after the source" semantics so the user
/// gets the new entry in the position they expect, not at the tail.
void duplicateCommentAt(JsonAstNode root, List<String> path) {
  final loc = _resolveCommentByPath(root, path);
  final children = loc.container is JsonObject
      ? (loc.container as JsonObject).properties
      : (loc.container as JsonArray).elements;
  final orig = children[loc.containerIndex] as CommentLine;
  // Standalone vs inline: the duplicate inherits the source's
  // inlinePlacement (lives on CommentLine, not CommentNode) so duplicating
  // an inline trailing comment yields another inline-style entry, not a
  // standalone block.
  final cloneLine = CommentLine(
    CommentNode(orig.comment.style, orig.comment.text),
    inlinePlacement: orig.inlinePlacement,
  );
  children.insert(loc.containerIndex + 1, cloneLine);
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

/// Insert a trailing INLINE comment that attaches to the row at
/// `anchorPath` — renders on the same source line (`key: value, // note`).
/// Lives as the next peer entry in the container with
/// `inlinePlacement: true`; the dumper picks that up and emits it inline
/// instead of on its own row.
void insertTrailingInlineComment(
  JsonAstNode root,
  List<String> anchorPath,
  CommentStyle style,
  String text,
) {
  if (anchorPath.isEmpty) {
    throw AstOpError(
        'insertTrailingInlineComment: anchor path empty (cannot attach to root)',
        anchorPath);
  }
  final ref = resolveParent(root, anchorPath);
  final newComment = CommentNode(style, text);
  ref.children.insert(
    ref.index + 1,
    CommentLine(newComment, inlinePlacement: true),
  );
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
