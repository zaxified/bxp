/// Replays an [OpLog] against the original raw bytes to produce the final
/// JSON5 file content for save.
///
/// Algorithm (per op):
///   1. Resolve the op's path to a `$meta_*` / `$elem_meta_*` entry in the
///      mutable tree state (which mirrors `configJson` after all prior ops).
///   2. Apply one byte splice using the meta's `value_span` / `block_span`.
///   3. Mutate tree state to reflect the op (edit/insert/delete/move/dup).
///   4. Walk the tree and shift every meta offset that sits at or after the
///      splice point by `delta = newLength - (origEnd - origStart)`. This
///      keeps subsequent ops' meta lookups consistent with the new bytes.
///
/// Meta lookup rules:
///   - Map child at `path = [...parent, key]` → `parent[$meta_<key>]`.
///   - Array element at `path = [...grandparent, arrayKey, index]` →
///     `grandparent[$elem_meta_<arrayKey>][index]`.
///
/// Synthetic entries (created by InsertOp / DuplicateOp) have meta entries
/// synthesised with the correct byte offsets so subsequent ops on those
/// paths succeed. No fallbacks: every op produces exactly one byte splice.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'json5_emitter.dart';
import 'op_log.dart';

class OpApply {
  /// Apply [ops] in order against [rawInput] (the file as it was on disk
  /// at load time) using span metadata from [originalTree] (the parsed
  /// `bxp-fmt --config` output, which carries `$meta_*` etc.). Returns the
  /// resulting bytes; UTF-8 decode happens at the call site.
  static Uint8List apply(
    List<int> rawInput,
    dynamic originalTree,
    List<ConfigOp> ops,
  ) {
    final state = _State(
      bytes: Uint8List.fromList(rawInput),
      tree: _deepCopy(originalTree),
    );
    for (final op in ops) {
      _applyOne(op, state);
    }
    return state.bytes;
  }

  static void _applyOne(ConfigOp op, _State state) {
    switch (op) {
      case EditValueOp e:
        _applyEdit(e, state);
      case DeleteOp d:
        _applyDelete(d, state);
      case DuplicateOp d:
        _applyDuplicate(d, state);
      case MoveOp m:
        _applyMove(m, state);
      case InsertOp i:
        _applyInsert(i, state);
      case EditCommentOp ec:
        _applyEditComment(ec, state);
      case DeleteCommentOp dc:
        _applyDeleteComment(dc, state);
        _renumberComments(state.tree);
      case InsertCommentOp ic:
        _applyInsertComment(ic, state);
        _renumberComments(state.tree);
    }
  }

  /// Renumber every `$comm_<N>` + `$meta_comm_<N>` pair in [tree] so their
  /// IDs match what `bxp-fmt`'s annotated reparse would assign — sequential
  /// 1..K by source position (block_span.start). Without this, an insert
  /// or delete leaves `state.tree`'s synthesised IDs out of step with the
  /// IDs the GUI sees after `_validateConfigNow` replaces `configJson`
  /// with the reparsed tree, and a follow-up op's path no longer matches.
  ///
  /// Critically: rename keys IN PLACE without disturbing the surrounding
  /// insertion order. Earlier impl removed+re-added each entry which moved
  /// it to the end of its parent map, breaking the source-order invariant
  /// downstream ops rely on for sibling enumeration.
  static void _renumberComments(dynamic tree) {
    // Phase 1: collect every $comm_<N> with its block_start.
    final entries = <_CommentEntry>[];
    void collect(dynamic node) {
      if (node is Map) {
        for (final e in node.entries) {
          final k = e.key.toString();
          if (k.startsWith(r'$comm_')) {
            final n = k.substring(r'$comm_'.length);
            final meta = node[r'$meta_comm_' + n];
            if (meta is Map) {
              final b = meta['block_span'];
              if (b is Map && b['start'] is int) {
                entries.add(_CommentEntry(node, n, b['start'] as int));
              }
            }
          }
          if (!k.startsWith(r'$meta_') && !k.startsWith(r'$elem_meta_')) {
            collect(e.value);
          }
        }
      } else if (node is List) {
        for (final v in node) {
          collect(v);
        }
      }
    }
    collect(tree);

    // Phase 2: assign new IDs by source position. Build a global old→new map.
    entries.sort((a, b) => a.blockStart.compareTo(b.blockStart));
    final oldToNew = <String, String>{};
    for (var i = 0; i < entries.length; i++) {
      oldToNew[entries[i].oldN] = (i + 1).toString();
    }

    // Phase 3: walk the tree and rebuild every map that holds $comm_*/
    // $meta_comm_* entries, preserving insertion order while substituting
    // the new IDs in place. Two-pass per map (TMP_ prefix) to avoid
    // collisions when the new ID equals some other entry's old ID.
    void rename(dynamic node) {
      if (node is Map) {
        bool needsRebuild = false;
        for (final k in node.keys) {
          final s = k.toString();
          if (s.startsWith(r'$comm_') || s.startsWith(r'$meta_comm_')) {
            needsRebuild = true;
            break;
          }
        }
        if (needsRebuild) {
          final originalEntries = node.entries.toList();
          node.clear();
          for (final e in originalEntries) {
            final k = e.key.toString();
            if (k.startsWith(r'$comm_')) {
              final oldN = k.substring(r'$comm_'.length);
              final newN = oldToNew[oldN];
              node[newN != null ? r'$comm_' + newN : k] = e.value;
            } else if (k.startsWith(r'$meta_comm_')) {
              final oldN = k.substring(r'$meta_comm_'.length);
              final newN = oldToNew[oldN];
              node[newN != null ? r'$meta_comm_' + newN : k] = e.value;
            } else {
              node[e.key] = e.value;
            }
          }
        }
        // Recurse after rebuild so nested $comm_<N> get the same treatment.
        for (final v in node.values) {
          rename(v);
        }
      } else if (node is List) {
        for (final v in node) {
          rename(v);
        }
      }
    }
    rename(tree);
  }

  // ── Edit ──────────────────────────────────────────────────────────────

  static void _applyEdit(EditValueOp op, _State state) {
    final meta = _lookupMeta(state.tree, op.path);
    if (meta == null) return;
    final newText = utf8.encode(_emitScalar(op.newValue));
    state.splice(meta.value.start, meta.value.end, newText);
    // Mutate tree leaf to the new value (preserves sibling annotations).
    _setLeaf(state.tree, op.path, op.newValue);
    // The leaf's value_span needs its END shifted by `delta`; block_span
    // needs the same. Other entries past this point already shifted via
    // [_State.splice]. Fix this entry's spans manually since splice's
    // global walk preserves spans whose START is < splice point.
    final entry = _lookupMetaRaw(state.tree, op.path);
    if (entry != null) {
      _grow(entry['value_span'] as Map, newText.length - (meta.value.end - meta.value.start));
      _grow(entry['block_span'] as Map, newText.length - (meta.value.end - meta.value.start));
    }
  }

  // ── Delete ────────────────────────────────────────────────────────────

  static void _applyDelete(DeleteOp op, _State state) {
    final meta = _lookupMeta(state.tree, op.path);
    if (meta == null) return;
    // Eat the trailing '\n' too if present, so we don't leave a blank line.
    int delEnd = meta.block.end;
    if (delEnd < state.bytes.length && state.bytes[delEnd] == 0x0A) delEnd++;
    state.splice(meta.block.start, delEnd, Uint8List(0));
    _removeFromTree(state.tree, op.path);
  }

  // ── Duplicate ─────────────────────────────────────────────────────────

  static void _applyDuplicate(DuplicateOp op, _State state) {
    final meta = _lookupMeta(state.tree, op.path);
    if (meta == null) return;
    final parent = _walkParent(state.tree, op.path);
    final insertAt = meta.block.end;

    if (parent is Map) {
      final origKey = op.path.last;
      final newKey = op.newKey ?? _uniqueKey(parent, origKey);
      final origMeta = parent[r'$meta_' + origKey] as Map;
      final origBlock = origMeta['block_span'] as Map;
      final origVal = origMeta['value_span'] as Map;
      final origKeySpan = origMeta['key_span'] as Map;
      // Build the duplicate's bytes from the source block, substituting
      // the key text so we don't emit two entries with the same key.
      // Match the original key's quoting style (unquoted JSON5 ident vs
      // "double" vs 'single').
      final blockBytes =
          state.bytes.sublist(meta.block.start, meta.block.end);
      final keyOff = (
        start: (origKeySpan['start'] as int) - (origBlock['start'] as int),
        end:   (origKeySpan['end']   as int) - (origBlock['start'] as int),
      );
      final firstByte = blockBytes[keyOff.start];
      final quote = (firstByte == 0x22 /* " */ || firstByte == 0x27 /* ' */)
          ? String.fromCharCode(firstByte)
          : null;
      final newKeyBytes = utf8.encode(_emitKeyQuoted(newKey, quote));
      final patched = BytesBuilder(copy: false)
        ..add(blockBytes.sublist(0, keyOff.start))
        ..add(newKeyBytes)
        ..add(blockBytes.sublist(keyOff.end));
      final entryBytes = patched.toBytes();
      // If the source entry is the last sibling in its map, its block has
      // no trailing `,` — splicing `\n` + duplicate would emit two adjacent
      // map entries without a separator (JSON5 syntax error). Detect and
      // prepend `,` in that case (mirrors _insertMap's logic).
      bool hasTrailingComma = false;
      for (int i = origVal['end'] as int; i < (origBlock['end'] as int); i++) {
        if (state.bytes[i] == 0x2C /* , */) { hasTrailingComma = true; break; }
      }
      final prefix = hasTrailingComma ? <int>[0x0A] : <int>[0x2C, 0x0A];
      final inserted = Uint8List(prefix.length + entryBytes.length)
        ..setRange(0, prefix.length, prefix)
        ..setRange(prefix.length, prefix.length + entryBytes.length, entryBytes);
      state.splice(insertAt, insertAt, inserted);

      final blockOffset = insertAt + prefix.length;
      final newKeyStart = blockOffset + keyOff.start;
      final keyDelta = newKeyBytes.length - (keyOff.end - keyOff.start);
      parent[newKey] = _deepCopy(parent[origKey]);
      parent[r'$meta_' + newKey] = {
        'key_span': {
          'start': newKeyStart,
          'end':   newKeyStart + newKeyBytes.length,
        },
        'value_span': {
          'start': (origVal['start'] as int) - (origBlock['start'] as int)
              + blockOffset + keyDelta,
          'end':   (origVal['end']   as int) - (origBlock['start'] as int)
              + blockOffset + keyDelta,
        },
        'block_span': {
          'start': blockOffset,
          'end':   blockOffset + entryBytes.length,
        },
      };
    } else if (parent is List) {
      // Lists: keys are positional, no rename needed — copy the block
      // verbatim. This branch keeps the original behaviour.
      final original = state.bytes.sublist(meta.block.start, meta.block.end);
      // Same trailing-comma detection as the Map branch: when duplicating
      // the last list element, its block carries no `,` and we must add
      // one before the inserted copy.
      bool hasTrailingComma = false;
      for (int i = meta.value.end; i < meta.block.end; i++) {
        if (state.bytes[i] == 0x2C /* , */) { hasTrailingComma = true; break; }
      }
      final prefix = hasTrailingComma ? <int>[0x0A] : <int>[0x2C, 0x0A];
      final inserted = Uint8List(prefix.length + original.length)
        ..setRange(0, prefix.length, prefix)
        ..setRange(prefix.length, prefix.length + original.length, original);
      state.splice(insertAt, insertAt, inserted);
      final idx = int.parse(op.path.last);
      final newIdx = idx + 1;
      final emIdx = _emIndex(parent, idx);
      parent.insert(newIdx, _deepCopy(parent[idx]));
      // Update grandparent's $elem_meta to insert a new entry.
      final gpRes = _walkParentTwo(state.tree, op.path);
      if (gpRes != null && gpRes.parent is Map) {
        final em = (gpRes.parent as Map)[r'$elem_meta_' + gpRes.arrayKey];
        if (em is List) {
          final origEntry = em[emIdx] as Map;
          final origBlock = origEntry['block_span'] as Map;
          final origVal = origEntry['value_span'] as Map;
          final blockOffset = insertAt + prefix.length;
          final shift = blockOffset - (origBlock['start'] as int);
          em.insert(emIdx + 1, {
            'value_span': {
              'start': (origVal['start'] as int) + shift,
              'end':   (origVal['end']   as int) + shift,
            },
            'block_span': {
              'start': (origBlock['start'] as int) + shift,
              'end':   (origBlock['end']   as int) + shift,
            },
          });
        }
      }
    }
  }

  // ── Move ──────────────────────────────────────────────────────────────

  static void _applyMove(MoveOp op, _State state) {
    if (op.delta == 0) return;
    if (op.path.isNotEmpty && op.path.last.toString().startsWith(r'$comm_')) {
      _moveComment(op, state);
      return;
    }
    final meta = _lookupMeta(state.tree, op.path);
    if (meta == null) return;
    final parent = _walkParent(state.tree, op.path);
    if (parent is List) {
      _moveListElement(op, state, parent);
    } else if (parent is Map) {
      _moveMapKey(op, state, parent);
    }
  }

  static void _moveListElement(MoveOp op, _State state, List parent) {
    final idx = int.tryParse(op.path.last);
    if (idx == null) return;
    // Find target real-element index (skip $comm_ pseudo-objects).
    int? targetIdx;
    if (op.delta < 0) {
      int t = idx - 1;
      while (t >= 0 && _isPseudoComm(parent[t])) t--;
      if (t < 0) return;
      targetIdx = t;
    } else {
      int t = idx + 1;
      while (t < parent.length && _isPseudoComm(parent[t])) t++;
      if (t >= parent.length) return;
      targetIdx = t;
    }

    // Lookup spans via $elem_meta on the grandparent.
    final gpRes = _walkParentTwo(state.tree, op.path);
    if (gpRes == null || gpRes.parent is! Map) return;
    final em = (gpRes.parent as Map)[r'$elem_meta_' + gpRes.arrayKey];
    if (em is! List) return;
    final emIdxA = _emIndex(parent, idx);
    final emIdxB = _emIndex(parent, targetIdx);
    final aMeta = em[emIdxA] as Map;
    final bMeta = em[emIdxB] as Map;
    final a = _coerceSpan(aMeta['block_span']);
    final b = _coerceSpan(bMeta['block_span']);
    if (a == null || b == null) return;
    _swapBlocks(state, a, b);
    // Swap tree positions
    final tmp = parent[idx];
    parent[idx] = parent[targetIdx];
    parent[targetIdx] = tmp;
    // Swap their $elem_meta entries too (so next op finds correct meta).
    final tmpMeta = em[emIdxA];
    em[emIdxA] = em[emIdxB];
    em[emIdxB] = tmpMeta;
  }

  static void _moveMapKey(MoveOp op, _State state, Map parent) {
    final key = op.path.last;
    // Row-by-row sibling list: include real keys AND $comm_<N> entries.
    // Skip only the bookkeeping siblings ($meta_*, $elem_meta_*, $err_*,
    // $meta_self). This matches the row-level UX the GUI shows.
    final siblings = parent.keys
        .map((k) => k.toString())
        .where((k) => !k.startsWith(r'$meta_') &&
            !k.startsWith(r'$elem_meta_') &&
            k != r'$meta_self' &&
            !k.startsWith(r'$err_'))
        .toList();
    final pos = siblings.indexOf(key);
    if (pos < 0) return;
    final targetPos = pos + op.delta;
    if (targetPos < 0 || targetPos >= siblings.length) return;
    final targetKey = siblings[targetPos];
    String metaOf(String k) => k.startsWith(r'$comm_')
        ? r'$meta_comm_' + k.substring(r'$comm_'.length)
        : r'$meta_' + k;
    final aMeta = parent[metaOf(key)] as Map?;
    final bMeta = parent[metaOf(targetKey)] as Map?;
    if (aMeta == null || bMeta == null) return;
    final aRaw = _coerceSpan(aMeta['block_span']);
    final bRaw = _coerceSpan(bMeta['block_span']);
    if (aRaw == null || bRaw == null) return;
    // Row-by-row semantics: each row is its own block; we never absorb
    // preceding blank/comment lines. (The old header-with-key absorption
    // belonged to the pre-row-by-row model where comments moved as a
    // group with the next real key. Now comments are first-class siblings
    // that move independently, so block_span IS the row.)
    _swapBlocks(state, aRaw, bRaw);
    // Reorder keys in parent map (Dart Maps are insertion-ordered).
    _swapMapEntriesInPlace(parent, key, targetKey);
    // After _swapBlocks + key swap, each meta still carries the spans that
    // describe where THAT key's bytes USED TO BE — but those byte ranges
    // now hold the OTHER key's content. Splice tracked position-shifts but
    // can't model a swap. Exchange span fields between the two metas so
    // each points at its key's NEW location.
    final aRenamed = parent[metaOf(targetKey)] as Map?;
    final bRenamed = parent[metaOf(key)] as Map?;
    if (aRenamed != null && bRenamed != null) {
      _exchangeSpans(aRenamed, bRenamed);
    }
  }

  /// Exchange `key_span` / `value_span` / `block_span` field VALUES between
  /// two `$meta_*` maps. Used by `_moveMapKey` and `_moveListElement` to fix
  /// up span ownership after a content swap.
  static void _exchangeSpans(Map metaA, Map metaB) {
    for (final spanKey in const ['key_span', 'value_span', 'block_span']) {
      final tmp = metaA[spanKey];
      metaA[spanKey] = metaB[spanKey];
      metaB[spanKey] = tmp;
    }
  }

  // ── Comment: edit / delete / insert / move ────────────────────────────

  static void _applyEditComment(EditCommentOp op, _State state) {
    final raw = _lookupCommentMetaRaw(state.tree, op.path);
    if (raw == null) return;
    final v = _coerceSpan(raw['value_span']);
    if (v == null) return;
    final newBytes = utf8.encode(op.newText);
    state.splice(v.start, v.end, newBytes);
    final delta = newBytes.length - (v.end - v.start);
    _grow(raw['value_span'] as Map, delta);
    _grow(raw['block_span'] as Map, delta);
    // Update tree text field on $comm_<N>, preserving original markers.
    final parent = _walkParent(state.tree, op.path);
    if (parent is Map) {
      final commObj = parent[op.path.last];
      if (commObj is Map) {
        final existing = commObj['text']?.toString() ?? '';
        if (existing.startsWith('/*')) {
          commObj['text'] = '/*${op.newText}*/';
        } else {
          commObj['text'] = '//${op.newText}';
        }
      }
    }
  }

  static void _applyDeleteComment(DeleteCommentOp op, _State state) {
    final raw = _lookupCommentMetaRaw(state.tree, op.path);
    if (raw == null) return;
    final b = _coerceSpan(raw['block_span']);
    if (b == null) return;
    int delEnd = b.end;
    if (delEnd < state.bytes.length && state.bytes[delEnd] == 0x0A) delEnd++;
    // Also consume the run of `[ \t]*` that precedes the comment on the same line —
    // covers indentation we want to remove with the comment.
    int delStart = b.start;
    state.splice(delStart, delEnd, Uint8List(0));
    _removeCommentFromTree(state.tree, op.path);
  }

  static void _applyInsertComment(InsertCommentOp op, _State state) {
    final anchorMeta = _lookupMetaRaw(state.tree, op.anchorPath);
    if (anchorMeta == null) return;
    final aBlock = _coerceSpan(anchorMeta['block_span']);
    if (aBlock == null) return;
    // Detect indent: leading inline whitespace at anchor's block start.
    int p = aBlock.start;
    while (p < state.bytes.length &&
        (state.bytes[p] == 0x20 || state.bytes[p] == 0x09)) {
      p++;
    }
    final indent = state.bytes.sublist(aBlock.start, p);
    final commentSrc = (op.style == '/*') ? '/*${op.text}*/' : '//${op.text}';
    final commentBytes = utf8.encode(commentSrc);
    final entry = BytesBuilder(copy: false)
      ..add(indent)
      ..add(commentBytes)
      ..addByte(0x0A);
    final entryBytes = entry.toBytes();
    final insertAt = aBlock.start;
    state.splice(insertAt, insertAt, entryBytes);

    // Synthesise meta + tree entries for the new comment.
    final newN = _nextCommNumber(state.tree);
    final commKey = r'$comm_' + newN.toString();
    final metaKey = r'$meta_comm_' + newN.toString();
    final markerLen = 2; // both `//` and `/*` are two bytes
    final bodyStart = insertAt + indent.length + markerLen;
    final bodyEnd = bodyStart + utf8.encode(op.text).length;
    final blockStart = insertAt;
    // block_end excludes the trailing `\n` to mirror json5.zig's emission
    // (which doesn't include the newline in the block).
    final blockEnd = insertAt + entryBytes.length - 1;

    final commObj = <String, dynamic>{
      'text': commentSrc,
      'placement': 'leading',
    };
    final metaObj = <String, dynamic>{
      'value_span': {'start': bodyStart, 'end': bodyEnd},
      'block_span': {'start': blockStart, 'end': blockEnd},
    };

    final parent = _walkParent(state.tree, op.anchorPath);
    final lastSeg = op.anchorPath.last.toString();
    if (parent is Map) {
      // Anchor is a map child. Insert $comm_<N> + $meta_comm_<N> right
      // before the anchor key in insertion order.
      _insertMapKeysBefore(parent, lastSeg, {commKey: commObj, metaKey: metaObj});
    } else if (parent is List) {
      // Anchor is an array element at index lastSeg. Insert pseudo-object.
      final idx = int.tryParse(lastSeg);
      if (idx == null) return;
      parent.insert(idx, <String, dynamic>{commKey: commObj, metaKey: metaObj});
      // No $elem_meta entry for pseudo-comm objects (Zig doesn't track them).
    }
  }

  /// Move a $comm_<N> entry up/down past one sibling (real or comment).
  /// Cut+paste because comments don't have a JSON5 trailing comma like real
  /// entries — `_swapBlocks`'s comma-aware splice would corrupt them.
  static void _moveComment(MoveOp op, _State state) {
    final raw = _lookupCommentMetaRaw(state.tree, op.path);
    if (raw == null) return;
    final cb = _coerceSpan(raw['block_span']);
    if (cb == null) return;
    final siblings = _enumerateOrderedSiblings(state.tree, op.path);
    if (siblings == null) return;
    final myIdx = siblings.indexWhere((e) => e.lastSeg == op.path.last.toString());
    if (myIdx < 0) return;
    final tgtIdx = myIdx + op.delta;
    if (tgtIdx < 0 || tgtIdx >= siblings.length) return;
    final target = siblings[tgtIdx];

    int cutEnd = cb.end;
    if (cutEnd < state.bytes.length && state.bytes[cutEnd] == 0x0A) cutEnd++;
    final commentBytes = state.bytes.sublist(cb.start, cutEnd);
    state.splice(cb.start, cutEnd, Uint8List(0));

    // Refresh target span (it may have shifted via _State.splice).
    final tMeta = _lookupRawForSibling(state.tree, op.path, target);
    if (tMeta == null) return;
    final tb = _coerceSpan(tMeta['block_span']);
    if (tb == null) return;

    int insertAt;
    if (op.delta < 0) {
      insertAt = tb.start;
    } else {
      insertAt = tb.end;
      if (insertAt < state.bytes.length && state.bytes[insertAt] == 0x0A) {
        insertAt++;
      }
    }
    state.splice(insertAt, insertAt, commentBytes);

    // Reposition comment meta to its new bytes.
    final newBlockStart = insertAt;
    final newBlockEnd = insertAt + commentBytes.length -
        ((commentBytes.isNotEmpty && commentBytes.last == 0x0A) ? 1 : 0);
    final origVal = _coerceSpan(raw['value_span']);
    final origBlock = _coerceSpan(raw['block_span']);
    final valOffsetInBlock = (origVal != null && origBlock != null)
        ? origVal.start - origBlock.start
        : 2;
    final valLen = (origVal != null) ? (origVal.end - origVal.start) : 0;
    raw['block_span'] = {'start': newBlockStart, 'end': newBlockEnd};
    raw['value_span'] = {
      'start': newBlockStart + valOffsetInBlock,
      'end': newBlockStart + valOffsetInBlock + valLen,
    };

    // Reorder tree to reflect new sibling order.
    _reorderCommentInTree(state.tree, op.path, target, op.delta);
  }

  // ── Comment helpers ────────────────────────────────────────────────────

  /// Look up `$meta_comm_<N>` for a path ending in `$comm_<N>`. The parent
  /// in tree-walk is always a Map: either the real container (map context)
  /// or the array's pseudo-comm wrapper object (array context).
  static Map? _lookupCommentMetaRaw(dynamic tree, ConfigPath path) {
    if (path.isEmpty) return null;
    final last = path.last.toString();
    if (!last.startsWith(r'$comm_')) return null;
    final n = last.substring(r'$comm_'.length);
    final parent = _walkParent(tree, path);
    if (parent is Map) {
      final m = parent[r'$meta_comm_' + n];
      if (m is Map) return m;
    }
    return null;
  }

  static int _nextCommNumber(dynamic tree) {
    int maxN = 0;
    void scan(dynamic node) {
      if (node is Map) {
        for (final entry in node.entries) {
          final k = entry.key.toString();
          if (k.startsWith(r'$comm_')) {
            final n = int.tryParse(k.substring(r'$comm_'.length));
            if (n != null && n > maxN) maxN = n;
          }
          if (!k.startsWith(r'$meta_') && !k.startsWith(r'$elem_meta_')) {
            scan(entry.value);
          }
        }
      } else if (node is List) {
        for (final v in node) {
          scan(v);
        }
      }
    }
    scan(tree);
    return maxN + 1;
  }

  static void _removeCommentFromTree(dynamic tree, ConfigPath path) {
    final last = path.last.toString();
    if (!last.startsWith(r'$comm_')) return;
    final n = last.substring(r'$comm_'.length);
    final parent = _walkParent(tree, path);
    if (parent is! Map) return;
    parent.remove(last);
    parent.remove(r'$meta_comm_' + n);
    // If we just emptied a pseudo-comm wrapper inside an array, drop the
    // wrapper from the grandparent list.
    final remaining = parent.keys
        .where((k) =>
            !k.toString().startsWith(r'$comm_') &&
            !k.toString().startsWith(r'$meta_comm_'))
        .isEmpty;
    final hasNoComms = !parent.keys.any((k) => k.toString().startsWith(r'$comm_'));
    if (remaining && hasNoComms) {
      // wrapper-only object now empty. Path: [...gp, arrayKey, idx, "$comm_<N>"]
      // Parent of wrapper = the list at path[len-3].
      if (path.length >= 2) {
        final wrapperParentPath = path.sublist(0, path.length - 1);
        final list = _walkParent(tree, wrapperParentPath);
        if (list is List) {
          final idx = int.tryParse(wrapperParentPath.last.toString());
          if (idx != null && idx >= 0 && idx < list.length) {
            list.removeAt(idx);
          }
        }
      }
    }
  }

  static void _insertMapKeysBefore(
      Map parent, String beforeKey, Map<String, dynamic> newEntries) {
    final entries = parent.entries.toList();
    parent.clear();
    bool injected = false;
    for (final e in entries) {
      final k = e.key.toString();
      if (!injected && k == beforeKey) {
        newEntries.forEach((nk, nv) {
          parent[nk] = nv;
        });
        injected = true;
      }
      parent[e.key] = e.value;
    }
    if (!injected) {
      // Anchor not found — append at end as a last resort.
      newEntries.forEach((nk, nv) {
        parent[nk] = nv;
      });
    }
  }

  /// Sibling ordering used by comment moves. Entries in source order
  /// (real keys/elements + comment slots), each described by a
  /// path-resolvable last segment and a kind tag.
  static List<_SiblingRef>? _enumerateOrderedSiblings(
      dynamic tree, ConfigPath path) {
    if (path.length < 1) return null;
    final last = path.last.toString();
    if (!last.startsWith(r'$comm_')) return null;
    final parent = _walkParent(tree, path);
    if (parent is Map) {
      // Map context: walk parent's keys in insertion order; emit one
      // _SiblingRef per real key and one per $comm_<N>.
      final out = <_SiblingRef>[];
      for (final k in parent.keys) {
        final s = k.toString();
        if (s.startsWith(r'$meta_') ||
            s.startsWith(r'$elem_meta_') ||
            s == r'$meta_self' ||
            s.startsWith(r'$err_')) {
          continue;
        }
        out.add(_SiblingRef(lastSeg: s, isComment: s.startsWith(r'$comm_')));
      }
      return out;
    }
    return null;
  }

  static Map? _lookupRawForSibling(
      dynamic tree, ConfigPath myPath, _SiblingRef sib) {
    final parentPath = myPath.sublist(0, myPath.length - 1);
    final siblingPath = [...parentPath, sib.lastSeg];
    if (sib.isComment) {
      return _lookupCommentMetaRaw(tree, siblingPath);
    }
    return _lookupMetaRaw(tree, siblingPath);
  }

  /// Reorder my $comm_<N> + $meta_comm_<N> pair past `target`. For delta<0,
  /// insert the pair just before target's first key (the real key or the
  /// $comm_<N> key for comment targets). For delta>0, insert after target's
  /// final paired entry (its $meta_<key> or $meta_comm_<N>).
  static void _reorderCommentInTree(
      dynamic tree, ConfigPath path, _SiblingRef target, int delta) {
    final parent = _walkParent(tree, path);
    if (parent is! Map) return;
    final myKey = path.last.toString();
    final n = myKey.substring(r'$comm_'.length);
    final myMetaKey = r'$meta_comm_' + n;
    final entries = parent.entries.toList();

    // Keys that belong to "me" and "target" pair, used to decide insertion bounds.
    final mineKeys = <String>{myKey, myMetaKey};
    final targetFirstKey = target.lastSeg;
    String targetLastKey;
    if (target.isComment) {
      final tn = target.lastSeg.substring(r'$comm_'.length);
      targetLastKey = r'$meta_comm_' + tn;
    } else {
      targetLastKey = r'$meta_' + target.lastSeg;
    }

    parent.clear();
    final myEntries = entries.where((e) => mineKeys.contains(e.key.toString())).toList();
    final others = entries.where((e) => !mineKeys.contains(e.key.toString())).toList();

    bool injected = false;
    for (int i = 0; i < others.length; i++) {
      final e = others[i];
      final k = e.key.toString();
      if (delta < 0 && !injected && k == targetFirstKey) {
        for (final m in myEntries) {
          parent[m.key] = m.value;
        }
        injected = true;
      }
      parent[e.key] = e.value;
      if (delta > 0 && !injected && k == targetLastKey) {
        for (final m in myEntries) {
          parent[m.key] = m.value;
        }
        injected = true;
      }
    }
    if (!injected) {
      for (final m in myEntries) {
        parent[m.key] = m.value;
      }
    }
  }

  // ── Insert ────────────────────────────────────────────────────────────

  static void _applyInsert(InsertOp op, _State state) {
    final parent = _walkPath(state.tree, op.parentPath);
    if (parent is Map) {
      _insertMap(op, state, parent);
    } else if (parent is List) {
      _insertList(op, state, parent);
    }
  }

  /// Build new entry text by lifting last-sibling block bytes and substituting
  /// key + value within. Falls back to a fresh emit when no sibling exists.
  static void _insertMap(InsertOp op, _State state, Map parent) {
    final newKey = op.keyOrIndex;
    final lastKey = _lastRealKey(parent);
    if (lastKey == null) {
      // Empty map — emit fresh entry on a new indented line.
      _insertFresh(op, state, parent);
      return;
    }
    final lastMeta = parent[r'$meta_' + lastKey] as Map;
    final lastBlock = _coerceSpan(lastMeta['block_span']);
    final lastValue = _coerceSpan(lastMeta['value_span']);
    final lastKeyS = _coerceSpan(lastMeta['key_span']);
    if (lastBlock == null || lastValue == null || lastKeyS == null) return;
    // Take the sibling block as template; substitute the value first (later
    // offset) so the key replacement's offsets stay intact.
    final tpl = state.bytes.sublist(lastBlock.start, lastBlock.end);
    final keyOff = (start: lastKeyS.start - lastBlock.start, end: lastKeyS.end - lastBlock.start);
    final valOff = (start: lastValue.start - lastBlock.start, end: lastValue.end - lastBlock.start);
    // Match template's key quoting: detect leading quote char.
    final tplKeyFirst = tpl[keyOff.start];
    final quote = (tplKeyFirst == 0x22 /* " */ || tplKeyFirst == 0x27 /* ' */)
        ? String.fromCharCode(tplKeyFirst)
        : null;
    final newKeyBytes = utf8.encode(_emitKeyQuoted(newKey, quote));
    final newValBytes = utf8.encode(_emitScalar(op.value));
    final patched = BytesBuilder(copy: false)
      ..add(tpl.sublist(0, keyOff.start))
      ..add(newKeyBytes)
      ..add(tpl.sublist(keyOff.end, valOff.start))
      ..add(newValBytes)
      ..add(tpl.sublist(valOff.end));
    final entryBytes = patched.toBytes();
    // Detect whether previous last entry already ends with ',' (somewhere in
    // its trailing tail between value_span.end and block_span.end). JSON5
    // tolerates trailing commas, so the original might or might not have one.
    bool hasTrailingComma = false;
    for (int i = lastValue.end; i < lastBlock.end; i++) {
      if (state.bytes[i] == 0x2C /* , */) { hasTrailingComma = true; break; }
    }
    final prefix = hasTrailingComma ? <int>[0x0A] : <int>[0x2C, 0x0A];
    // Insert: optional ',' + '\n' + entry, right after the last sibling's block.
    final insertAt = lastBlock.end;
    final inserted = Uint8List(prefix.length + entryBytes.length)
      ..setRange(0, prefix.length, prefix)
      ..setRange(prefix.length, prefix.length + entryBytes.length, entryBytes);
    state.splice(insertAt, insertAt, inserted);

    // Synthesise meta for the new entry.
    final blockOffset = insertAt + prefix.length;
    final newKeyStart = blockOffset + keyOff.start;
    final newValStart = blockOffset + keyOff.start + newKeyBytes.length + (valOff.start - keyOff.end);
    parent[newKey] = op.value;
    parent[r'$meta_' + newKey] = {
      'key_span': {
        'start': newKeyStart,
        'end':   newKeyStart + newKeyBytes.length,
      },
      'value_span': {
        'start': newValStart,
        'end':   newValStart + newValBytes.length,
      },
      'block_span': {
        'start': blockOffset,
        'end':   blockOffset + entryBytes.length,
      },
    };
  }

  static void _insertList(InsertOp op, _State state, List parent) {
    final idx = (op.keyOrIndex is int)
        ? op.keyOrIndex as int
        : int.tryParse(op.keyOrIndex.toString()) ?? parent.length;
    // Determine insertion byte offset by looking at neighbour element.
    final gpRes = _walkParentByPath(state.tree, op.parentPath);
    if (gpRes == null || gpRes.parent is! Map) return;
    final em = (gpRes.parent as Map)[r'$elem_meta_' + gpRes.arrayKey];
    if (em is! List) return;
    // Convert Dart insertion index → $elem_meta index (skipping in-array
    // pseudo-comm objects, which Zig doesn't track in elem_meta).
    final emInsertAt = _emIndex(parent, idx);
    int byteOffset;
    Uint8List entryBytes;
    bool hasTrailingComma = false;
    if (em.isNotEmpty) {
      // Use previous-real-sibling as template — copy its block, replace value.
      final tplEmIdx = (emInsertAt > 0) ? emInsertAt - 1 : 0;
      final tplEntry = em[tplEmIdx] as Map;
      final tplBlock = _coerceSpan(tplEntry['block_span']);
      final tplVal = _coerceSpan(tplEntry['value_span']);
      if (tplBlock == null || tplVal == null) return;
      final tpl = state.bytes.sublist(tplBlock.start, tplBlock.end);
      final valOff = (start: tplVal.start - tplBlock.start, end: tplVal.end - tplBlock.start);
      final newValBytes = utf8.encode(_emitScalar(op.value));
      final patched = BytesBuilder(copy: false)
        ..add(tpl.sublist(0, valOff.start))
        ..add(newValBytes)
        ..add(tpl.sublist(valOff.end));
      entryBytes = patched.toBytes();
      byteOffset = tplBlock.end;
      // When the template is the array's last element it has no trailing `,`
      // — emit one before the new entry to keep JSON5 syntax valid.
      for (int i = tplVal.end; i < tplBlock.end; i++) {
        if (state.bytes[i] == 0x2C /* , */) { hasTrailingComma = true; break; }
      }
    } else {
      // Empty array — fresh emit.
      entryBytes = utf8.encode('  ${_emitScalar(op.value)}');
      // Need to know the array's container_span open_pos to insert after '['.
      // For simplicity, fall back: use parent map's emitted indent... TBD.
      return;
    }
    final prefix = hasTrailingComma ? <int>[0x0A] : <int>[0x2C, 0x0A];
    final inserted = Uint8List(prefix.length + entryBytes.length)
      ..setRange(0, prefix.length, prefix)
      ..setRange(prefix.length, prefix.length + entryBytes.length, entryBytes);
    state.splice(byteOffset, byteOffset, inserted);
    final blockOffset = byteOffset + prefix.length;
    parent.insert(idx, op.value);
    final tplEmIdx = (emInsertAt > 0) ? emInsertAt - 1 : 0;
    final tplEntry = em[tplEmIdx] as Map;
    final tplVal = _coerceSpan(tplEntry['value_span'])!;
    final tplBlock = _coerceSpan(tplEntry['block_span'])!;
    final shift = blockOffset - tplBlock.start;
    em.insert(emInsertAt, {
      'value_span': {
        'start': tplVal.start + shift,
        'end':   tplVal.start + shift + utf8.encode(_emitScalar(op.value)).length,
      },
      'block_span': {
        'start': blockOffset,
        'end':   blockOffset + entryBytes.length,
      },
    });
  }

  static void _insertFresh(InsertOp op, _State state, Map parent) {
    // Empty container insert — out of scope for v1 (deferred).
  }
}

// ── State ───────────────────────────────────────────────────────────────

class _State {
  Uint8List bytes;
  dynamic tree;
  _State({required this.bytes, required this.tree});

  /// Replace bytes [origStart, origEnd) with [newContent], then walk the
  /// tree shifting every meta offset that is at or after `origEnd` by
  /// `delta = newContent.length - (origEnd - origStart)`. Spans that
  /// straddle the splice grow at their tail; spans entirely within the
  /// splice are left as-is (the caller is responsible for fixing them).
  void splice(int origStart, int origEnd, List<int> newContent) {
    final newLen = newContent.length;
    final oldLen = origEnd - origStart;
    final delta = newLen - oldLen;
    final builder = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(bytes, 0, origStart))
      ..add(newContent is Uint8List ? newContent : Uint8List.fromList(newContent))
      ..add(Uint8List.sublistView(bytes, origEnd));
    bytes = builder.toBytes();
    if (delta != 0) _shiftMeta(tree, origEnd, delta);
  }
}

/// Walks every `$meta_*` / `$elem_meta_*` / `$meta_self` recursively in
/// [node] and shifts span offsets ≥ [boundary] by [delta]. Spans that
/// start before but end at or after [boundary] only have their `end`
/// shifted (they grew across the splice).
void _shiftMeta(dynamic node, int boundary, int delta) {
  if (node is Map) {
    for (final entry in node.entries) {
      final k = entry.key.toString();
      if (k.startsWith(r'$meta_') || k == r'$meta_self') {
        final v = entry.value;
        if (v is Map) {
          for (final spanKey in const ['key_span', 'value_span', 'block_span', 'container_span']) {
            final s = v[spanKey];
            if (s is Map) _shiftSpan(s, boundary, delta);
          }
        }
      } else if (k.startsWith(r'$elem_meta_')) {
        final v = entry.value;
        if (v is List) {
          for (final em in v) {
            if (em is Map) {
              for (final spanKey in const ['value_span', 'block_span']) {
                final s = em[spanKey];
                if (s is Map) _shiftSpan(s, boundary, delta);
              }
            }
          }
        }
      } else if (!k.startsWith(r'$comm_') && !k.startsWith(r'$err_')) {
        _shiftMeta(entry.value, boundary, delta);
      }
    }
  } else if (node is List) {
    for (final v in node) {
      _shiftMeta(v, boundary, delta);
    }
  }
}

void _shiftSpan(Map span, int boundary, int delta) {
  final s = span['start'];
  final e = span['end'];
  if (s is int && s >= boundary) span['start'] = s + delta;
  if (e is int && e >= boundary) span['end'] = e + delta;
}

void _grow(Map span, int delta) {
  final e = span['end'];
  if (e is int) span['end'] = e + delta;
}

// ── Path / meta helpers ─────────────────────────────────────────────────

class _Span {
  final int start, end;
  const _Span(this.start, this.end);
}

class _Meta {
  final _Span value;
  final _Span? key;
  final _Span block;
  const _Meta({required this.value, this.key, required this.block});
}

_Span? _coerceSpan(dynamic v) {
  if (v is! Map) return null;
  final s = v['start'];
  final e = v['end'];
  if (s is int && e is int) return _Span(s, e);
  return null;
}

dynamic _walkPath(dynamic tree, ConfigPath path) {
  dynamic node = tree;
  for (final seg in path) {
    if (node is Map) {
      node = node[seg];
    } else if (node is List) {
      final idx = int.tryParse(seg.toString());
      if (idx == null || idx < 0 || idx >= node.length) return null;
      node = node[idx];
    } else {
      return null;
    }
  }
  return node;
}

dynamic _walkParent(dynamic tree, ConfigPath path) {
  if (path.isEmpty) return null;
  return _walkPath(tree, path.sublist(0, path.length - 1));
}

class _ParentTwo {
  final dynamic parent; // grandparent of the leaf
  final String arrayKey;
  _ParentTwo(this.parent, this.arrayKey);
}

_ParentTwo? _walkParentTwo(dynamic tree, ConfigPath path) {
  if (path.length < 2) return null;
  final gp = _walkPath(tree, path.sublist(0, path.length - 2));
  return _ParentTwo(gp, path[path.length - 2].toString());
}

_ParentTwo? _walkParentByPath(dynamic tree, ConfigPath parentPath) {
  if (parentPath.isEmpty) return null;
  final gp = _walkPath(tree, parentPath.sublist(0, parentPath.length - 1));
  return _ParentTwo(gp, parentPath.last.toString());
}

Map? _lookupMetaRaw(dynamic tree, ConfigPath path) {
  if (path.isEmpty) return null;
  final last = path.last.toString();
  final parent = _walkParent(tree, path);
  if (parent is Map) {
    final m = parent[r'$meta_' + last];
    if (m is Map) return m;
  }
  if (parent is List) {
    final idx = int.tryParse(last);
    if (idx == null) return null;
    final gp = _walkParentTwo(tree, path);
    if (gp == null || gp.parent is! Map) return null;
    final em = (gp.parent as Map)[r'$elem_meta_' + gp.arrayKey];
    if (em is List) {
      final emIdx = _emIndex(parent, idx);
      if (emIdx < em.length && em[emIdx] is Map) return em[emIdx] as Map;
    }
  }
  return null;
}

_Meta? _lookupMeta(dynamic tree, ConfigPath path) {
  if (path.isEmpty) {
    if (tree is! Map) return null;
    final ms = tree[r'$meta_self'];
    if (ms is! Map) return null;
    final cs = _coerceSpan(ms['container_span']);
    if (cs == null) return null;
    return _Meta(value: cs, block: cs);
  }
  final raw = _lookupMetaRaw(tree, path);
  if (raw == null) return null;
  final v = _coerceSpan(raw['value_span']);
  final b = _coerceSpan(raw['block_span']);
  final k = _coerceSpan(raw['key_span']);
  if (v == null || b == null) return null;
  return _Meta(value: v, key: k, block: b);
}

// ── Mutation helpers ────────────────────────────────────────────────────

void _setLeaf(dynamic tree, ConfigPath path, Object? newValue) {
  final parent = _walkParent(tree, path);
  if (parent is Map) {
    parent[path.last] = newValue;
  } else if (parent is List) {
    final idx = int.tryParse(path.last);
    if (idx != null && idx >= 0 && idx < parent.length) parent[idx] = newValue;
  }
}

void _removeFromTree(dynamic tree, ConfigPath path) {
  final parent = _walkParent(tree, path);
  if (parent is Map) {
    final key = path.last;
    parent.remove(key);
    parent.remove(r'$meta_' + key);
  } else if (parent is List) {
    final idx = int.tryParse(path.last);
    if (idx == null) return;
    final emIdx = _emIndex(parent, idx);
    parent.removeAt(idx);
    final gp = _walkParentTwo(tree, path);
    if (gp != null && gp.parent is Map) {
      final em = (gp.parent as Map)[r'$elem_meta_' + gp.arrayKey];
      if (em is List && emIdx < em.length) em.removeAt(emIdx);
    }
  }
}

void _swapBlocks(_State state, _Span a, _Span b) {
  final low = a.start < b.start ? a : b;
  final high = a.start < b.start ? b : a;
  final lowS = low.start, lowE = low.end;
  final highS = high.start, highE = high.end;

  // Snapshot every span living strictly INSIDE either block. These are
  // nested children (composite values' inner $meta_*, $meta_self
  // container_span, $elem_meta entries) whose bytes physically move with
  // their parent block when we swap. Splice's _shiftMeta only models
  // position shifts, not swaps, so without this fix-up children of `high`
  // end up pointing into `low`'s post-shift slot (where the OTHER
  // entry's content now sits) and the next op edits the wrong bytes.
  final highChildSpans = <Map>[];
  final lowChildSpans = <Map>[];
  void scan(dynamic node) {
    if (node is Map) {
      for (final e in node.entries) {
        final k = e.key.toString();
        final v = e.value;
        if (k.startsWith(r'$meta_') || k == r'$meta_self') {
          if (v is Map) {
            for (final spanKey in const [
              'key_span',
              'value_span',
              'block_span',
              'container_span',
            ]) {
              final s = v[spanKey];
              if (s is Map) {
                final st = s['start'];
                if (st is int) {
                  if (st > highS && st < highE) {
                    highChildSpans.add(s);
                  } else if (st > lowS && st < lowE) {
                    lowChildSpans.add(s);
                  }
                }
              }
            }
          }
        } else if (k.startsWith(r'$elem_meta_')) {
          if (v is List) {
            for (final em in v) {
              if (em is Map) {
                for (final spanKey in const ['value_span', 'block_span']) {
                  final s = em[spanKey];
                  if (s is Map) {
                    final st = s['start'];
                    if (st is int) {
                      if (st > highS && st < highE) {
                        highChildSpans.add(s);
                      } else if (st > lowS && st < lowE) {
                        lowChildSpans.add(s);
                      }
                    }
                  }
                }
              }
            }
          }
        } else if (!k.startsWith(r'$comm_') && !k.startsWith(r'$err_')) {
          scan(v);
        }
      }
    } else if (node is List) {
      for (final v in node) {
        scan(v);
      }
    }
  }
  scan(state.tree);

  // Content-aware swap: split each block into (value, optional `,`, tail)
  // and recombine so BOTH new contents end with `,` after the value.
  // JSON5 accepts a trailing comma on the last element too, so this is
  // always safe.
  final lowOrig = state.bytes.sublist(lowS, lowE);
  final highOrig = state.bytes.sublist(highS, highE);
  final lowParts = _splitArrayElemBlock(lowOrig);
  final highParts = _splitArrayElemBlock(highOrig);
  final newLow = _joinWithComma(highParts);
  final newHigh = _joinWithComma(lowParts);
  state.splice(high.start, high.end, newHigh);
  state.splice(low.start, low.end, newLow);

  // After the two splices:
  //   * `high` children's spans were shifted by delta2 (splice2 boundary
  //     was lowE, all metas with start >= lowE shifted by delta2). They
  //     now sit in high's post-shift slot, but their bytes physically
  //     live in low's slot. Required additional shift: lowS - highS - d2.
  //   * `low` children's spans were not touched by either splice. Their
  //     bytes now live in high's post-shift slot. Required additional
  //     shift: highS - lowS + delta2 (negation of the above).
  final delta2 = newLow.length - (lowE - lowS);
  final adjustHigh = (lowS - highS) - delta2;
  final adjustLow = -adjustHigh;
  for (final s in highChildSpans) {
    s['start'] = (s['start'] as int) + adjustHigh;
    s['end'] = (s['end'] as int) + adjustHigh;
  }
  for (final s in lowChildSpans) {
    s['start'] = (s['start'] as int) + adjustLow;
    s['end'] = (s['end'] as int) + adjustLow;
  }
}

/// Split block bytes into (valueBytes, hasComma, tailBytes).
///
/// `valueBytes` covers the leading indent + the JSON5 value up to and
/// including the outer `}` / `]` (or to the end of a scalar). `hasComma`
/// is true when a depth-0 `,` immediately follows the value within these
/// bytes; `tailBytes` is everything after that comma — typically inline
/// whitespace + an optional same-line `// comment`. When the source is
/// the array's last element (no trailing comma), `hasComma` is false and
/// `tailBytes` holds whatever followed the value.
({Uint8List value, bool hasComma, Uint8List tail}) _splitArrayElemBlock(
    Uint8List bytes) {
  int depth = 0;
  bool inString = false;
  int? stringQuote;
  bool inLineComment = false;
  bool inBlockComment = false;
  bool seenValueStart = false;
  int? valueEnd; // exclusive position right after the value's outer close
  int i = 0;
  while (i < bytes.length) {
    final c = bytes[i];
    if (inLineComment) {
      if (c == 0x0A) inLineComment = false;
      i++;
      continue;
    }
    if (inBlockComment) {
      if (c == 0x2A && i + 1 < bytes.length && bytes[i + 1] == 0x2F) {
        inBlockComment = false;
        i += 2;
        continue;
      }
      i++;
      continue;
    }
    if (inString) {
      if (c == 0x5C) {
        i += 2;
        continue;
      }
      if (c == stringQuote) inString = false;
      i++;
      continue;
    }
    if (c == 0x22 || c == 0x27) {
      inString = true;
      stringQuote = c;
      seenValueStart = true;
      // For scalar string values at depth 0, the value ends at the
      // closing quote — track that on the inString=false transition.
      i++;
      while (i < bytes.length) {
        final cc = bytes[i];
        if (cc == 0x5C) {
          i += 2;
          continue;
        }
        if (cc == stringQuote) {
          inString = false;
          i++;
          if (depth == 0) valueEnd = i;
          break;
        }
        i++;
      }
      continue;
    }
    if (c == 0x2F && i + 1 < bytes.length) {
      final n = bytes[i + 1];
      if (n == 0x2F) {
        // Trailing `//` comment after the value → stop scanning; rest is tail.
        // Only at depth 0 — `//` inside a nested object/array is just an
        // inner comment and must NOT terminate the outer value scan
        // (otherwise root-level entries like `id: { ... // foo \n ... }`
        // would split right after the outer `:` and corrupt the swap).
        if (depth == 0 && valueEnd != null) {
          return (
            value: bytes.sublist(0, valueEnd),
            hasComma: false,
            tail: bytes.sublist(valueEnd),
          );
        }
        // Inside a nested container (or before any value started): skip the
        // rest of the line as a line comment.
        i += 2;
        while (i < bytes.length && bytes[i] != 0x0A) {
          i++;
        }
        continue;
      }
      if (n == 0x2A) {
        inBlockComment = true;
        i += 2;
        continue;
      }
    }
    if (c == 0x7B || c == 0x5B) {
      depth++;
      seenValueStart = true;
      i++;
      continue;
    }
    if (c == 0x7D || c == 0x5D) {
      depth--;
      if (depth == 0 && seenValueStart) valueEnd = i + 1;
      i++;
      continue;
    }
    if (c == 0x2C && depth == 0 && valueEnd != null) {
      return (
        value: bytes.sublist(0, valueEnd),
        hasComma: true,
        tail: bytes.sublist(i + 1),
      );
    }
    // Scalar literals at depth 0 (numbers, true/false/null): treat any
    // non-ws non-syntax char as advancing the value end so we still know
    // where it stops if no `,` follows.
    if (depth == 0 &&
        c != 0x20 &&
        c != 0x09 &&
        c != 0x0A &&
        c != 0x0D) {
      seenValueStart = true;
      valueEnd = i + 1;
    }
    i++;
  }
  return (
    value: valueEnd != null ? bytes.sublist(0, valueEnd) : bytes,
    hasComma: false,
    tail: valueEnd != null ? bytes.sublist(valueEnd) : Uint8List(0),
  );
}

Uint8List _joinWithComma(({Uint8List value, bool hasComma, Uint8List tail}) p) {
  final b = BytesBuilder(copy: false)
    ..add(p.value)
    ..addByte(0x2C) // always emit `,` after the value
    ..add(p.tail);
  return b.toBytes();
}

/// Swap two map entries in [m] while keeping their meta sibling
/// (`$meta_<key>` for real keys, `$meta_comm_<N>` for `$comm_<N>` keys)
/// adjacent. Either key may be a comment. Public so the live tree mutation
/// in `TraceStore.moveConfigNode` can reuse the same swap logic op_apply
/// uses for the on-disk CST patch — guarantees both views agree on key
/// order before Save replays the ops.
void swapMapKeysInPlace(Map m, String keyA, String keyB) =>
    _swapMapEntriesInPlace(m, keyA, keyB);

String _metaKeyOf(String k) => k.startsWith(r'$comm_')
    ? r'$meta_comm_' + k.substring(r'$comm_'.length)
    : r'$meta_' + k;

void _swapMapEntriesInPlace(Map m, String keyA, String keyB) {
  // Dart Maps are insertion-ordered. Rebuild in place, swapping the two
  // (key, meta) pairs so each pair lands in the OTHER's old slot.
  final metaA = _metaKeyOf(keyA);
  final metaB = _metaKeyOf(keyB);
  final entries = m.entries.toList();
  m.clear();
  for (final e in entries) {
    final k = e.key.toString();
    if (k == keyA) {
      m[keyB] = entries.firstWhere((x) => x.key.toString() == keyB).value;
    } else if (k == keyB) {
      m[keyA] = entries.firstWhere((x) => x.key.toString() == keyA).value;
    } else if (k == metaA) {
      m[metaB] = entries.firstWhere((x) => x.key.toString() == metaB).value;
    } else if (k == metaB) {
      m[metaA] = entries.firstWhere((x) => x.key.toString() == metaA).value;
    } else {
      m[e.key] = e.value;
    }
  }
}

bool _isPseudoComm(dynamic v) {
  if (v is! Map) return false;
  bool sawComm = false;
  for (final k in v.keys) {
    final s = k.toString();
    if (s.startsWith(r'$comm_')) {
      sawComm = true;
      continue;
    }
    if (s.startsWith(r'$meta_comm_')) continue;
    return false;
  }
  return sawComm;
}

/// Sibling reference used by comment-move sibling enumeration. `lastSeg` is
/// the last path segment that resolves the sibling (a real map key, or a
/// `$comm_<N>` key for comments).
class _SiblingRef {
  final String lastSeg;
  final bool isComment;
  _SiblingRef({required this.lastSeg, required this.isComment});
}

/// One `$comm_<N>` location used during global renumbering after a
/// comment-affecting op. `tempIdx` is filled in pass 1 of the rename and
/// consumed in pass 2.
class _CommentEntry {
  final Map parent;
  final String oldN;
  final int blockStart;
  int tempIdx = 0;
  _CommentEntry(this.parent, this.oldN, this.blockStart);
}

/// Map a Dart array index to the corresponding `$elem_meta_<key>` index.
///
/// In-array `$comm_*` pseudo-objects show up as elements in the parsed
/// list, but the Zig parser only emits `$elem_meta` entries for real
/// values. So if `parent[2]` is a `$comm_*` pseudo-object, the real entry
/// at Dart index 3 maps to `$elem_meta` index 2. Use this helper any time
/// we need to read or splice into `em`.
int _emIndex(List parent, int dartIdx) {
  int n = 0;
  for (int i = 0; i < dartIdx && i < parent.length; i++) {
    if (!_isPseudoComm(parent[i])) n++;
  }
  return n;
}

String? _lastRealKey(Map m) {
  String? last;
  for (final k in m.keys) {
    final s = k.toString();
    if (!s.startsWith(r'$')) last = s;
  }
  return last;
}

String _uniqueKey(Map m, String base) {
  if (!m.containsKey('${base}_copy')) return '${base}_copy';
  int n = 2;
  while (m.containsKey('${base}_copy$n')) {
    n++;
  }
  return '${base}_copy$n';
}

dynamic _deepCopy(dynamic v) {
  if (v is Map) {
    final out = <String, dynamic>{};
    v.forEach((k, val) {
      out[k.toString()] = _deepCopy(val);
    });
    return out;
  }
  if (v is List) {
    return v.map(_deepCopy).toList();
  }
  return v;
}

// ── Scalar / key emitters (delegate to Json5Emitter for consistency) ───

String _emitScalar(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) {
    if (v is int) return v.toString();
    if (v == v.truncateToDouble() && v.isFinite) return v.truncate().toString();
    return v.toString();
  }
  if (v is String) return Json5Emitter.emit(v).trim();
  return Json5Emitter.emit(v).trim();
}

String _emitKeyQuoted(String k, String? quote) {
  if (quote == null) {
    // Template was unquoted (JSON5 identifier). Use unquoted if valid,
    // otherwise force double quotes.
    if (RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(k)) return k;
    return '"${k.replaceAll('\\', r'\\').replaceAll('"', r'\"')}"';
  }
  final escaped = k.replaceAll('\\', r'\\').replaceAll(quote, '\\$quote');
  return '$quote$escaped$quote';
}
