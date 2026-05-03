/// Log of high-level config edits the user performed since load.
///
/// Each [ConfigOp] is one button-press worth of intent (edit / delete /
/// duplicate / move / insert). At save time the AST patcher
/// (`AstPatchClient`) replays the log against the original raw bytes via
/// the Dart JSON5 AST library, then deterministic-dumps the result.
library;

/// Path component: `String` for Map keys, stringified int for List indices
/// (matches the convention in `trace_store.dart` which encodes array indices
/// as `i.toString()`).
typedef ConfigPath = List<String>;

sealed class ConfigOp {
  const ConfigOp();
}

/// Replace a scalar leaf value at [path].
class EditValueOp extends ConfigOp {
  final ConfigPath path;
  final Object? newValue; // null / bool / num / String
  const EditValueOp(this.path, this.newValue);
}

/// Remove the entry at [path] (and its trailing comma + same-line comment).
class DeleteOp extends ConfigOp {
  final ConfigPath path;
  const DeleteOp(this.path);
}

/// Duplicate the entry at [path] right after itself.
/// For Maps, the duplicate gets a fresh unique key suffix `_copy[N]`.
class DuplicateOp extends ConfigOp {
  final ConfigPath path;
  final String? newKey; // for Map duplicates; null for List
  const DuplicateOp(this.path, {this.newKey});
}

/// Reorder: swap the entry at [path] with its previous (-1) or next (+1)
/// real sibling. Trailing-placement comments travel with their owners.
class MoveOp extends ConfigOp {
  final ConfigPath path;
  final int delta; // -1 (up) or +1 (down)
  const MoveOp(this.path, this.delta);
}

/// Edit a comment's text body (the bytes between `//` / `/* */` markers).
/// [path] ends in `$comm_<N>`. [newText] is the raw body to splice in.
class EditCommentOp extends ConfigOp {
  final ConfigPath path;
  final String newText;
  const EditCommentOp(this.path, this.newText);
}

/// Delete a standalone / leading / block comment at [path] (`$comm_<N>`).
/// Trailing comments aren't deleted via this op — they live with their owner.
class DeleteCommentOp extends ConfigOp {
  final ConfigPath path;
  const DeleteCommentOp(this.path);
}

/// Clone the comment at [path] (`$comm_<N>`) into the next peer slot.
/// Mirrors [DuplicateOp] for real keys/elements.
class DuplicateCommentOp extends ConfigOp {
  final ConfigPath path;
  const DuplicateCommentOp(this.path);
}

/// Insert a new comment immediately above the entry at [anchorPath].
/// [style] is `"//"` or `"/*"`. [text] is the body (no markers).
/// `MoveOp` with a `$comm_<N>` last-segment handles reordering.
class InsertCommentOp extends ConfigOp {
  final ConfigPath anchorPath;
  final String style;
  final String text;
  const InsertCommentOp(this.anchorPath, this.style, this.text);
}

/// Insert a trailing INLINE comment glued to the row at [anchorPath]
/// (`key: value, // note`). Mirrors [InsertCommentOp] but the resulting
/// CommentLine carries `inlinePlacement: true`.
class InsertInlineCommentOp extends ConfigOp {
  final ConfigPath anchorPath;
  final String style;
  final String text;
  const InsertInlineCommentOp(this.anchorPath, this.style, this.text);
}

/// Insert a fresh entry into the parent at [parentPath].
///
/// For Maps: [keyOrIndex] is the new key. When [atIndex] is null the
/// entry appends after the last existing peer; non-null inserts at that
/// raw peer position (Phase 5f canonical placement).
/// For Lists: [keyOrIndex] is the stringified target index (clamped to
/// end); [atIndex] is ignored — list position lives in [keyOrIndex].
class InsertOp extends ConfigOp {
  final ConfigPath parentPath;
  final String keyOrIndex;
  final Object? value;
  final int? atIndex;
  const InsertOp(this.parentPath, this.keyOrIndex, this.value, {this.atIndex});
}

/// Append-only ledger of ops since load. Cleared on save.
class OpLog {
  final List<ConfigOp> _ops = [];
  List<ConfigOp> get ops => List.unmodifiable(_ops);
  bool get isEmpty => _ops.isEmpty;
  int get length => _ops.length;

  void record(ConfigOp op) {
    _ops.add(op);
  }

  void clear() {
    _ops.clear();
  }

  /// Drop ops past index [n], keeping `_ops[0..n)`. Used by undo: when the
  /// user steps back through history then makes a new edit, the
  /// "redone-away" ops must not survive in the log.
  void truncate(int n) {
    if (n < 0) n = 0;
    if (n >= _ops.length) return;
    _ops.removeRange(n, _ops.length);
  }
}
