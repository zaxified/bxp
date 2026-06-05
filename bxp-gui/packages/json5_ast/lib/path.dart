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
    // caller can read .text. The wrapper is read-only and intentionally
    // drops `inlinePlacement` (defaults to false) — `$comm_<N>` callers
    // only consume `.comment.text` for display, never the placement flag.
    // For mutation (rewrite, delete, move) prefer findCommentByGlobalN
    // which returns a CommentLocation with the live, fully-flagged
    // CommentLine still in place inside its container.
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
    // Path indices are RAW positions in `elements` (counting CommentLine
    // peers), matching the convention `trace_store` uses when it walks
    // the live AST / legacy adapter Map at edit time. Resolving with a
    // real-only conversion here would silently target the wrong element
    // when the array contains a standalone CommentLine before `n`.
    if (n < 0 || n >= cur.elements.length) {
      throw AstPathError('list index $n out of range', path);
    }
    return ParentRef(cur, cur.elements, n);
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
    // RAW indexing — see resolveParent for the rationale.
    if (n < 0 || n >= node.elements.length) {
      throw AstPathError('list index $n out of range', fullPath);
    }
    return node.elements[n];
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

  /// Mutate the live [CommentNode.text] in place. Any [CommentLine]
  /// references held elsewhere observe the new text immediately because
  /// they share the same [CommentNode]. Note that
  /// [globalCommentNumbering]'s identity-keyed map keys on [CommentLine]
  /// (not on text), so rewriting text does NOT invalidate it — and
  /// numbering is rebuilt on every UI render anyway, so even structural
  /// edits don't leak stale entries.
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

/// Inverse of [findCommentByGlobalN]: walk the whole tree once and return
/// an identity-keyed map from each [CommentLine] to its 1-based source-
/// order index. Used by the UI when constructing `$comm_<N>` paths for
/// comment-row click handlers — a single O(N) walk per build avoids the
/// O(N×comments) cost of looking up each comment via a global walker.
///
/// MUST traverse in the exact same source-order as [findCommentByGlobalN]'s
/// `_CommentWalker` (entries in order, recurse into non-comment nodes), or
/// the UI's `$comm_<N>` numbering and the resolver's lookup drift apart and
/// a comment-row click edits the wrong comment. Keep the two walkers in
/// lockstep if a new container node type is added.
Map<CommentLine, int> globalCommentNumbering(JsonAstNode root) {
  final out = <CommentLine, int>{};
  void walk(JsonAstNode n) {
    if (n is JsonObject) {
      for (final c in n.properties) {
        if (c is CommentLine) {
          out[c] = out.length + 1;
        } else {
          walk(c);
        }
      }
    } else if (n is JsonArray) {
      for (final c in n.elements) {
        if (c is CommentLine) {
          out[c] = out.length + 1;
        } else {
          walk(c);
        }
      }
    } else if (n is JsonProperty) {
      walk(n.value);
    }
  }
  walk(root);
  return out;
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
