import 'ast.dart';

/// Thrown when a path can't be resolved against the AST. The Phase 2
/// integration wraps this into the existing UI save-error surface.
class AstPathError implements Exception {
  final String message;
  final List<String> path;
  AstPathError(this.message, this.path);
  @override
  String toString() => 'AstPathError(path=$path): $message';
}

/// Reference to a child position inside a container so callers can read,
/// replace, or remove without re-walking. `index` points into the raw
/// container list (`JsonObject.properties` or `JsonArray.elements`),
/// which still includes [CommentLine] pseudo-entries.
class ParentRef {
  final JsonAstNode parent;       // JsonObject or JsonArray
  final List<JsonAstNode> children; // properties or elements list
  final int index;                // raw index in `children`
  ParentRef(this.parent, this.children, this.index);

  JsonAstNode get child => children[index];
  bool get isObject => parent is JsonObject;
  bool get isArray => parent is JsonArray;
}

/// Resolve `path` to the target node. Path uses the same convention as
/// `op_log.dart#ConfigPath`: Map segments are string keys, Array segments
/// are stringified ints (real-only — skipping [CommentLine]). The last
/// segment may be `$comm_<N>` to address a comment by global N (in source
/// order); see [findCommentByGlobalN].
JsonAstNode resolveNode(JsonAstNode root, List<String> path) {
  if (path.isEmpty) return root;
  final last = path.last;
  if (last.startsWith(r'$comm_')) {
    final n = int.tryParse(last.substring(r'$comm_'.length));
    if (n == null) {
      throw AstPathError("invalid \$comm_N segment '$last'", path);
    }
    final loc = findCommentByGlobalN(root, n);
    if (loc == null) {
      throw AstPathError('no comment with global N=$n', path);
    }
    // Comment isn't a JsonAstNode; wrap into a transient CommentLine so the
    // caller can read .text. For mutation, prefer findCommentByGlobalN.
    return CommentLine(loc.comment);
  }
  final ref = resolveParent(root, path);
  final c = ref.child;
  return c is JsonProperty ? c.value : c;
}

/// Resolve `path` to the (parent, last-segment) pair. The returned
/// [ParentRef] points at the addressed child inside its container.
/// For `$comm_<N>` last segments, throw — comment lookups go through
/// [findCommentByGlobalN] instead (parents are heterogeneous).
ParentRef resolveParent(JsonAstNode root, List<String> path) {
  if (path.isEmpty) {
    throw AstPathError('empty path has no parent', path);
  }
  if (path.last.startsWith(r'$comm_')) {
    throw AstPathError(
        '\$comm_N path has no ParentRef; use findCommentByGlobalN', path);
  }
  JsonAstNode cur = root;
  for (var i = 0; i < path.length - 1; i++) {
    cur = _step(cur, path[i], path);
  }
  final last = path.last;
  if (cur is JsonObject) {
    final idx = _findPropertyIndex(cur, last);
    if (idx < 0) {
      throw AstPathError("key '$last' not found in object", path);
    }
    return ParentRef(cur, cur.properties, idx);
  }
  if (cur is JsonArray) {
    final n = int.tryParse(last);
    if (n == null) {
      throw AstPathError("expected numeric index, got '$last'", path);
    }
    final idx = _realIndexToRawIndex(cur.elements, n);
    if (idx < 0) {
      throw AstPathError('list index $n out of range', path);
    }
    return ParentRef(cur, cur.elements, idx);
  }
  throw AstPathError(
      "cannot index into ${cur.runtimeType} with '$last'", path);
}

/// Walk one step deeper into `node` using `seg`. Used internally by
/// resolvers; throws with the full `fullPath` for diagnostics.
JsonAstNode _step(JsonAstNode node, String seg, List<String> fullPath) {
  if (node is JsonObject) {
    final idx = _findPropertyIndex(node, seg);
    if (idx < 0) {
      throw AstPathError("key '$seg' not found", fullPath);
    }
    return (node.properties[idx] as JsonProperty).value;
  }
  if (node is JsonArray) {
    final n = int.tryParse(seg);
    if (n == null) {
      throw AstPathError("expected numeric index, got '$seg'", fullPath);
    }
    final idx = _realIndexToRawIndex(node.elements, n);
    if (idx < 0) {
      throw AstPathError('list index $n out of range', fullPath);
    }
    return node.elements[idx];
  }
  if (node is JsonProperty) {
    return _step(node.value, seg, fullPath);
  }
  throw AstPathError(
      "cannot descend into ${node.runtimeType} with '$seg'", fullPath);
}

int _findPropertyIndex(JsonObject obj, String key) {
  for (var i = 0; i < obj.properties.length; i++) {
    final e = obj.properties[i];
    if (e is JsonProperty && e.key == key) return i;
  }
  return -1;
}

/// Map a real-only index (skipping [CommentLine]) to the raw index inside
/// `elements`. Returns -1 if `n` is out of range.
int _realIndexToRawIndex(List<JsonAstNode> elements, int n) {
  var seen = 0;
  for (var i = 0; i < elements.length; i++) {
    if (elements[i] is CommentLine) continue;
    if (seen == n) return i;
    seen++;
  }
  return -1;
}

/// Count of real (non-CommentLine) elements in `elements`.
int realElementCount(List<JsonAstNode> elements) {
  var c = 0;
  for (final e in elements) {
    if (e is! CommentLine) c++;
  }
  return c;
}

/// Where a comment lives in the AST. Needed to mutate it without
/// re-walking the tree.
class CommentLocation {
  /// Two kinds:
  ///   `standalone`: a `CommentLine` pseudo-entry in a container.
  ///   `trailing`: a `JsonAstNode.trailingComment` slot on an entry.
  /// (Phase 4: leading comments unified into standalone CommentLines —
  /// no longer a separate kind.)
  final CommentLocationKind kind;
  final JsonAstNode container; // for kind=standalone: JsonObject/JsonArray
  final int containerIndex;    // for kind=standalone: raw index of CommentLine
  final JsonAstNode owner;     // for kind=trailing: the node owning the comment
  final int globalN;           // 1-based global index in source order

  CommentLocation.standalone(
      this.container, this.containerIndex, this.globalN)
      : kind = CommentLocationKind.standalone,
        owner = container;

  CommentLocation.trailing(this.owner, this.globalN)
      : kind = CommentLocationKind.trailing,
        container = owner,
        containerIndex = -1;

  CommentNode get comment {
    switch (kind) {
      case CommentLocationKind.standalone:
        final list = container is JsonObject
            ? (container as JsonObject).properties
            : (container as JsonArray).elements;
        return (list[containerIndex] as CommentLine).comment;
      case CommentLocationKind.trailing:
        return owner.trailingComment!;
    }
  }

  void replaceText(String newText) {
    final c = comment;
    c.text = newText;
  }

  void delete() {
    switch (kind) {
      case CommentLocationKind.standalone:
        final list = container is JsonObject
            ? (container as JsonObject).properties
            : (container as JsonArray).elements;
        list.removeAt(containerIndex);
        break;
      case CommentLocationKind.trailing:
        owner.trailingComment = null;
        break;
    }
  }
}

enum CommentLocationKind { standalone, trailing }

/// Find the N-th comment in source order across the whole tree.
/// N is 1-based to match `$comm_<N>` user-facing convention. Trailing
/// inline comments ARE counted (deterministic source position) so the
/// global N matches what bxp-fmt's annotated tree assigns.
CommentLocation? findCommentByGlobalN(JsonAstNode root, int targetN) {
  final visitor = _CommentWalker(targetN);
  visitor.visit(root);
  return visitor.found;
}

/// Walk the tree in source order, count comments, return the N-th.
class _CommentWalker {
  final int target;
  int seen = 0;
  CommentLocation? found;
  _CommentWalker(this.target);

  bool _bump(CommentLocation Function() makeLoc) {
    seen++;
    if (seen == target) {
      found = makeLoc();
      return true; // stop
    }
    return false;
  }

  /// Visit `n`'s body (via `inner`), then its trailing comment if any.
  /// Returns true if the target was found (caller should stop).
  bool _visitBodyThenTrailing(JsonAstNode n, bool Function() inner) {
    if (inner()) return true;
    if (n.trailingComment != null) {
      if (_bump(() => CommentLocation.trailing(n, seen))) return true;
    }
    return false;
  }

  bool visit(JsonAstNode n) {
    if (n is JsonObject) {
      return _visitBodyThenTrailing(n, () {
        for (var i = 0; i < n.properties.length; i++) {
          final entry = n.properties[i];
          if (entry is CommentLine) {
            final capturedIdx = i;
            if (_bump(() => CommentLocation.standalone(n, capturedIdx, seen))) {
              return true;
            }
          } else if (entry is JsonProperty) {
            if (_visitBodyThenTrailing(entry, () => visit(entry.value))) {
              return true;
            }
          }
        }
        return false;
      });
    }
    if (n is JsonArray) {
      return _visitBodyThenTrailing(n, () {
        for (var i = 0; i < n.elements.length; i++) {
          final el = n.elements[i];
          if (el is CommentLine) {
            final capturedIdx = i;
            if (_bump(() => CommentLocation.standalone(n, capturedIdx, seen))) {
              return true;
            }
          } else {
            if (_visitBodyThenTrailing(el, () => visit(el))) return true;
          }
        }
        return false;
      });
    }
    // Scalar — has no children; its trailing comment is visited by caller.
    return false;
  }
}
