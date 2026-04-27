/// Log of high-level config edits the user performed since load.
///
/// Each [ConfigOp] is one button-press worth of intent (edit / delete /
/// duplicate / move / insert). At save time [OpApply] replays the log
/// against the original raw bytes, using `$meta_*` / `$elem_meta_*` tags
/// from the annotated tree to translate each op into one byte patch.
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

/// Insert a fresh entry into the parent at [parentPath].
///
/// For Maps: [keyOrIndex] is the new key. Insertion happens after the
/// last existing real key.
/// For Lists: [keyOrIndex] is the stringified target index (clamped to end).
class InsertOp extends ConfigOp {
  final ConfigPath parentPath;
  final String keyOrIndex;
  final Object? value;
  const InsertOp(this.parentPath, this.keyOrIndex, this.value);
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
