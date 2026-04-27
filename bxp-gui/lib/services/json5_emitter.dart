/// JSON5 emitter with bxp-fmt annotation support.
///
/// Takes an annotated JSON tree (the shape `bxp-fmt --config` produces —
/// comments stored as sibling `$comm_N: {text, placement}` keys in their
/// Map parent) and renders it back as JSON5 text with the comments placed
/// where they belong in the source.
///
/// Key properties:
///   - comments preserved verbatim (leading / trailing / block)
///   - key order preserved (Dart Map keeps insertion order; bxp-fmt emits
///     keys in source order)
///   - `$err_N` nodes are skipped — those are diagnostic markers, never
///     part of the real source
///   - unquoted keys are used for plain identifiers (matches JSON5 idiom;
///     falls back to quoted when the key contains anything unsafe)
///   - 2-space indent; this is NOT a CST-preserving round-trip
///     (whitespace, trailing commas, and original quoting get normalised)
///
/// The full bxp-ui roundtrip (which uses @croct/json5-parser to patch the
/// original source CST) preserves every byte; that would require writing a
/// Dart JSON5 CST parser, far beyond this module's scope. The 95% use case
/// — keep my comments, keep my structure, pretty-print — is covered here.
library;

class Json5Emitter {
  final StringBuffer _buf = StringBuffer();
  static const _indent = '  ';

  /// Convert a parsed, annotated config tree to JSON5 text.
  static String emit(dynamic tree) {
    final e = Json5Emitter._();
    e._value(tree, 0);
    e._buf.write('\n');
    return e._buf.toString();
  }

  /// Emit a subtree at a non-zero indentation depth. Used by [CstSave]
  /// when it falls back to a fresh render for one branch of the tree
  /// (e.g. an array reorder) and needs the inner indent to match the
  /// surrounding file. No trailing newline — the caller pastes the
  /// result into existing text.
  static String emitSubtree(dynamic tree, int depth) {
    final e = Json5Emitter._();
    e._value(tree, depth);
    return e._buf.toString();
  }

  Json5Emitter._();

  void _value(dynamic v, int depth) {
    if (v == null) {
      _buf.write('null');
    } else if (v is bool) {
      _buf.write(v ? 'true' : 'false');
    } else if (v is num) {
      _buf.write(_num(v));
    } else if (v is String) {
      _buf.write(_string(v));
    } else if (v is List) {
      _list(v, depth);
    } else if (v is Map) {
      _map(v, depth);
    } else {
      _buf.write(_string(v.toString()));
    }
  }

  void _map(Map m, int depth) {
    // First pass: group entries by "real key → its leading + trailing
    // comments". $err_ gets dropped entirely. $comm_ nodes attach to the
    // nearest real key (trailing if they follow one with placement="trailing",
    // otherwise they're buffered as leading for the next real key).
    final groups = <_KeyGroup>[];
    final pendingLeading = <String>[];
    _KeyGroup? last;

    for (final e in m.entries) {
      final k = e.key.toString();
      if (k.startsWith(r'$err_') ||
          k.startsWith(r'$span_') ||
          k.startsWith(r'$spans_')) {
        continue;
      }
      if (k.startsWith(r'$comm_')) {
        final info = e.value;
        if (info is! Map) continue;
        final text = info['text']?.toString() ?? '';
        final placement = info['placement']?.toString() ?? 'leading';
        if (placement == 'trailing' && last != null) {
          last.trailing.add(text);
        } else {
          pendingLeading.add(text);
        }
      } else {
        last = _KeyGroup(key: k, value: e.value, leading: List.of(pendingLeading));
        pendingLeading.clear();
        groups.add(last);
      }
    }
    // Orphan leading comments at end of map: stick them onto the last
    // real key as trailing-on-own-line. If the map has no real keys,
    // they'd be dropped — acceptable corner case.
    if (pendingLeading.isNotEmpty && last != null) {
      last.trailing.addAll(pendingLeading);
    }

    if (groups.isEmpty) {
      _buf.write('{}');
      return;
    }

    final childPad = _indent * (depth + 1);
    final closePad = _indent * depth;

    _buf.write('{\n');
    for (int i = 0; i < groups.length; i++) {
      final g = groups[i];
      for (final c in g.leading) {
        _buf.write(childPad);
        _buf.write(c);
        _buf.write('\n');
      }
      _buf.write(childPad);
      _buf.write(_key(g.key));
      _buf.write(': ');
      _value(g.value, depth + 1);
      if (i < groups.length - 1) _buf.write(',');
      // Trailing comments sit on the same line as the value (after the
      // comma, since JSON5 permits it).
      for (final c in g.trailing) {
        _buf.write(' ');
        _buf.write(c);
      }
      _buf.write('\n');
    }
    _buf.write(closePad);
    _buf.write('}');
  }

  void _list(List list, int depth) {
    // Pre-pass: $comm_<N> pseudo-objects (single-key Maps emitted by the Zig
    // preprocessAnnotated for in-array comments) attach to neighbour elements.
    // $err_<N> pseudo-objects are dropped defensively.
    final groups = <_ElemGroup>[];
    final pendingLeading = <String>[];
    _ElemGroup? last;

    for (final e in list) {
      final pseudo = _pseudoCommInfo(e);
      if (pseudo != null) {
        if (pseudo.placement == 'trailing' && last != null) {
          last.trailing.add(pseudo.text);
        } else {
          pendingLeading.add(pseudo.text);
        }
        continue;
      }
      if (_isPseudoErr(e)) continue;
      last = _ElemGroup(value: e, leading: List.of(pendingLeading));
      pendingLeading.clear();
      groups.add(last);
    }
    if (pendingLeading.isNotEmpty && last != null) {
      // Orphan leading-style comments after the last element → render as
      // trailing-on-own-line on that element (mirrors _map).
      last.trailing.addAll(pendingLeading);
    }

    if (groups.isEmpty) {
      _buf.write('[]');
      return;
    }

    _buf.write('[\n');
    final childPad = _indent * (depth + 1);
    final closePad = _indent * depth;

    for (int i = 0; i < groups.length; i++) {
      final g = groups[i];
      for (final c in g.leading) {
        _buf.write(childPad);
        _buf.write(c);
        _buf.write('\n');
      }
      _buf.write(childPad);
      _value(g.value, depth + 1);
      if (i < groups.length - 1) _buf.write(',');
      for (final c in g.trailing) {
        _buf.write(' ');
        _buf.write(c);
      }
      _buf.write('\n');
    }

    _buf.write(closePad);
    _buf.write(']');
  }

  static _PseudoComm? _pseudoCommInfo(dynamic e) {
    if (e is! Map || e.length != 1) return null;
    final k = e.keys.first.toString();
    if (!k.startsWith(r'$comm_')) return null;
    final v = e.values.first;
    if (v is! Map) return null;
    final text = v['text']?.toString() ?? '';
    final placement = v['placement']?.toString() ?? 'leading';
    return _PseudoComm(text, placement);
  }

  static bool _isPseudoErr(dynamic e) {
    if (e is! Map || e.length != 1) return false;
    return e.keys.first.toString().startsWith(r'$err_');
  }

  /// Emit a key: unquoted when it matches the JSON5 identifier rule,
  /// double-quoted otherwise. `$var` identifiers ARE valid unquoted keys
  /// in JSON5 (identifier chars include `$`).
  String _key(String k) => _isBareIdent(k) ? k : _string(k);

  static final _identRe = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');
  bool _isBareIdent(String s) => _identRe.hasMatch(s);

  String _num(num n) {
    if (n is int) return n.toString();
    if (n == n.truncateToDouble() && n.isFinite) return n.truncate().toString();
    return n.toString();
  }

  /// JSON5 allows single- or double-quoted strings. We pick the form that
  /// requires fewer escapes; default to double quotes on a tie.
  String _string(String s) {
    final dq = _countChar(s, '"');
    final sq = _countChar(s, "'");
    final quote = (dq > sq) ? "'" : '"';
    final other = quote == '"' ? "'" : '"';
    final buf = StringBuffer(quote);
    for (int i = 0; i < s.length; i++) {
      final ch = s[i];
      switch (ch) {
        case '\\':
          buf.write(r'\\');
          break;
        case '\n':
          buf.write(r'\n');
          break;
        case '\r':
          buf.write(r'\r');
          break;
        case '\t':
          buf.write(r'\t');
          break;
        default:
          if (ch == quote) {
            buf.write('\\$quote');
          } else if (ch == other) {
            buf.write(other); // bare — no escape needed in JSON5
          } else if (ch.codeUnitAt(0) < 0x20) {
            buf.write(
                '\\u${ch.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}');
          } else {
            buf.write(ch);
          }
      }
    }
    buf.write(quote);
    return buf.toString();
  }

  static int _countChar(String s, String ch) {
    int n = 0;
    for (int i = 0; i < s.length; i++) {
      if (s[i] == ch) n++;
    }
    return n;
  }
}

class _KeyGroup {
  final String key;
  final dynamic value;
  final List<String> leading;
  final List<String> trailing;

  _KeyGroup({
    required this.key,
    required this.value,
    required this.leading,
  }) : trailing = [];
}

class _ElemGroup {
  final dynamic value;
  final List<String> leading;
  final List<String> trailing;

  _ElemGroup({required this.value, required this.leading}) : trailing = [];
}

class _PseudoComm {
  final String text;
  final String placement;
  _PseudoComm(this.text, this.placement);
}
