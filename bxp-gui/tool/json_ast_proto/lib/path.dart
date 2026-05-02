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

/// Where a comment lives in the AST. After Phase 5e all comments
/// (standalone + inline-trailing) are `CommentLine` peer entries in a
/// container — there's only ONE kind of location now.
class CommentLocation {
  final JsonAstNode container; // JsonObject or JsonArray
  final int containerIndex;    // raw index of the CommentLine in the container
  final int globalN;           // 1-based global index in source order

  CommentLocation(this.container, this.containerIndex, this.globalN);

  CommentLine get _line {
    final list = container is JsonObject
        ? (container as JsonObject).properties
        : (container as JsonArray).elements;
    return list[containerIndex] as CommentLine;
  }

  CommentNode get comment => _line.comment;
  bool get isInlineTrailing => _line.inlinePlacement;

  void replaceText(String newText) {
    comment.text = newText;
  }

  void delete() {
    final list = container is JsonObject
        ? (container as JsonObject).properties
        : (container as JsonArray).elements;
    list.removeAt(containerIndex);
  }
}

/// Find the N-th comment in source order across the whole tree.
/// N is 1-based to match `$comm_<N>` user-facing convention.
CommentLocation? findCommentByGlobalN(JsonAstNode root, int targetN) {
  final visitor = _CommentWalker(targetN);
  visitor.visit(root);
  return visitor.found;
}

/// Walk the tree in source order, count CommentLines, return the N-th.
/// All comments (standalone + inline-trail) are uniform CommentLine peer
/// entries after Phase 5e, so this is just a flat container walk.
class _CommentWalker {
  final int target;
  int seen = 0;
  CommentLocation? found;
  _CommentWalker(this.target);

  bool _bump(CommentLocation Function() makeLoc) {
    seen++;
    if (seen == target) {
      found = makeLoc();
      return true;
    }
    return false;
  }

  bool visit(JsonAstNode n) {
    if (n is JsonObject) {
      return _walkContainer(n, n.properties);
    }
    if (n is JsonArray) {
      return _walkContainer(n, n.elements);
    }
    if (n is JsonProperty) {
      return visit(n.value);
    }
    return false;
  }

  bool _walkContainer(JsonAstNode container, List<JsonAstNode> entries) {
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e is CommentLine) {
        final capturedIdx = i;
        if (_bump(() => CommentLocation(container, capturedIdx, seen))) {
          return true;
        }
      } else {
        if (visit(e)) return true;
      }
    }
    return false;
  }
}
