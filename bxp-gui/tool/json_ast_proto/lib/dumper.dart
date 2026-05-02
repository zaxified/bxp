import 'ast.dart';

class DumperOptions {
  final String indent;
  final int inlineArrayMax;
  final int inlineObjectMax;
  final int alignKeyMaxLen;
  final int alignKeyGap;
  final String trailingCommentGap;
  const DumperOptions({
    this.indent = '  ',
    this.inlineArrayMax = 80,
    this.inlineObjectMax = 0,
    this.alignKeyMaxLen = 20,
    this.alignKeyGap = 2,
    this.trailingCommentGap = '  ',
  });
}

/// Pre-rendered container entry: either a standalone row (`node` is the
/// thing to emit, `inlineTrail` null) or a row with an inline-placement
/// comment glued to its end (`inlineTrail` present).
///
/// Phase 5e: source-level "trailing inline" comments live as
/// `CommentLine(inlinePlacement: true)` peer entries in the parent
/// container. The dumper restructures consecutive
/// `[mainNode, CommentLine(inlinePlacement: true)]` pairs into one
/// rendered row to preserve the visual `key: val // comment` layout.
class _RenderEntry {
  final JsonAstNode node;
  final CommentLine? inlineTrail;
  _RenderEntry(this.node, this.inlineTrail);
}

List<_RenderEntry> _buildRenderEntries(List<JsonAstNode> raw) {
  final out = <_RenderEntry>[];
  for (var i = 0; i < raw.length; i++) {
    final e = raw[i];
    if (e is CommentLine &&
        e.inlinePlacement &&
        out.isNotEmpty &&
        out.last.inlineTrail == null &&
        out.last.node is! CommentLine) {
      final prev = out.removeLast();
      out.add(_RenderEntry(prev.node, e));
    } else {
      out.add(_RenderEntry(e, null));
    }
  }
  return out;
}

class Dumper {
  final DumperOptions opt;
  // ignore: prefer_final_fields
  StringBuffer _b = StringBuffer();

  Dumper([this.opt = const DumperOptions()]);

  static String dump(JsonAstNode root, [DumperOptions opt = const DumperOptions()]) {
    final d = Dumper(opt);
    d._writeNode(root, 0);
    if (!d._b.toString().endsWith('\n')) d._b.write('\n');
    return d._b.toString();
  }

  void _indent(int depth) => _b.write(opt.indent * depth);

  void _writeNode(JsonAstNode n, int depth) {
    if (n is JsonObject) {
      _writeObject(n, depth);
    } else if (n is JsonArray) {
      _writeArray(n, depth);
    } else if (n is JsonString) {
      _b.write(_encodeString(n.value));
    } else if (n is JsonNumber) {
      _b.write(_emitNumber(n.rawText));
    } else if (n is JsonBool) {
      _b.write(n.value ? 'true' : 'false');
    } else if (n is JsonNull) {
      _b.write('null');
    } else if (n is CommentLine) {
      _writeCommentLine(n.comment, depth);
    } else {
      throw StateError('unknown node type: ${n.runtimeType}');
    }
  }

  void _writeCommentLine(CommentNode c, int depth) {
    _indent(depth);
    if (c.style == CommentStyle.line) {
      _b.write('//');
      _b.write(c.text);
      _b.write('\n');
    } else {
      _b.write('/*');
      _b.write(c.text);
      _b.write('*/\n');
    }
  }

  void _writeObject(JsonObject obj, int depth) {
    if (obj.properties.isEmpty) {
      _b.write('{}');
      return;
    }
    final inline = _inlineObjectIfShort(obj);
    if (inline != null) {
      _b.write(inline);
      return;
    }
    _b.write('{\n');
    final entries = _buildRenderEntries(obj.properties);
    final alignW = _alignKeyWidth(entries);
    final lastPropIdx = _lastJsonPropertyIndexInRender(entries);
    final mainLines = <String?>[];
    final saved = _b;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.node is JsonProperty) {
        final tmp = StringBuffer();
        _b = tmp;
        _writeObjectPropertyMainLine(
            e.node as JsonProperty, depth, alignW, i == lastPropIdx);
        _b = saved;
        mainLines.add(tmp.toString());
      } else {
        mainLines.add(null);
      }
    }
    final commentCol = _commentColumn(entries, mainLines);
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final node = e.node;
      if (node is CommentLine) {
        // Standalone comment row (inline-placement entries are absorbed
        // by _buildRenderEntries into the prev row).
        _writeCommentLine(node.comment, depth + 1);
        continue;
      }
      if (node is JsonProperty) {
        final ml = mainLines[i]!;
        _b.write(ml);
        if (e.inlineTrail != null) {
          final pad = commentCol > ml.length
              ? commentCol - ml.length
              : opt.alignKeyGap;
          _b.write(' ' * pad);
          _writeInlineComment(e.inlineTrail!.comment);
        }
        _b.write('\n');
        continue;
      }
      throw StateError('unexpected object child: ${node.runtimeType}');
    }
    _indent(depth);
    _b.write('}');
  }

  void _writeObjectPropertyMainLine(
      JsonProperty entry, int depth, int alignW, bool isLast) {
    _indent(depth + 1);
    final keyStr = _emitKey(entry.key);
    _b.write(keyStr);
    _b.write(':');
    final isContainer =
        entry.value is JsonObject || entry.value is JsonArray;
    if (!isContainer &&
        alignW > 0 &&
        keyStr.length <= opt.alignKeyMaxLen) {
      final pad = (alignW - keyStr.length) + opt.alignKeyGap;
      _b.write(' ' * pad);
    } else {
      _b.write(' ');
    }
    _writeNode(entry.value, depth + 1);
    if (!isLast) _b.write(',');
  }

  int _lastJsonPropertyIndexInRender(List<_RenderEntry> entries) {
    for (var i = entries.length - 1; i >= 0; i--) {
      if (entries[i].node is JsonProperty) return i;
    }
    return -1;
  }

  int _commentColumn(List<_RenderEntry> entries, List<String?> mainLines) {
    int maxLen = 0;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.inlineTrail != null && mainLines[i] != null) {
        final l = mainLines[i]!.length;
        if (l > maxLen) maxLen = l;
      }
    }
    if (maxLen == 0) return 0;
    return maxLen + opt.alignKeyGap;
  }

  void _writeInlineComment(CommentNode tc) {
    if (tc.style == CommentStyle.line) {
      _b.write('//');
      _b.write(tc.text);
    } else {
      _b.write('/*');
      _b.write(tc.text);
      _b.write('*/');
    }
  }

  void _writeArray(JsonArray arr, int depth) {
    if (arr.elements.isEmpty) {
      _b.write('[]');
      return;
    }
    if (_canInlineArray(arr)) {
      _b.write('[');
      for (var i = 0; i < arr.elements.length; i++) {
        if (i > 0) _b.write(', ');
        _writeNode(arr.elements[i], 0);
      }
      _b.write(']');
      return;
    }
    _b.write('[\n');
    final entries = _buildRenderEntries(arr.elements);
    final lastNonCommentIdx = _lastNonCommentIndexInRender(entries);
    final mainLines = <String?>[];
    final saved = _b;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.node is CommentLine) {
        mainLines.add(null);
      } else {
        final tmp = StringBuffer();
        _b = tmp;
        _indent(depth + 1);
        _writeNode(e.node, depth + 1);
        if (i != lastNonCommentIdx) _b.write(',');
        _b = saved;
        mainLines.add(tmp.toString());
      }
    }
    final commentCol = _commentColumn(entries, mainLines);
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final node = e.node;
      if (node is CommentLine) {
        _writeCommentLine(node.comment, depth + 1);
        continue;
      }
      final ml = mainLines[i]!;
      _b.write(ml);
      if (e.inlineTrail != null) {
        final pad = commentCol > ml.length
            ? commentCol - ml.length
            : opt.alignKeyGap;
        _b.write(' ' * pad);
        _writeInlineComment(e.inlineTrail!.comment);
      }
      _b.write('\n');
    }
    _indent(depth);
    _b.write(']');
  }

  int _lastNonCommentIndexInRender(List<_RenderEntry> entries) {
    for (var i = entries.length - 1; i >= 0; i--) {
      if (entries[i].node is! CommentLine) return i;
    }
    return -1;
  }

  int _alignKeyWidth(List<_RenderEntry> entries) {
    int m = 0;
    for (final e in entries) {
      final node = e.node;
      if (node is! JsonProperty) continue;
      if (node.value is JsonObject || node.value is JsonArray) continue;
      final k = _emitKey(node.key).length;
      if (k > opt.alignKeyMaxLen) continue;
      if (k > m) m = k;
    }
    return m;
  }

  String? _inlineObjectIfShort(JsonObject obj) {
    // Cheap rejection: any inline-trail or standalone comment forces multi-line.
    for (final entry in obj.properties) {
      if (entry is CommentLine) return null;
      if (entry is! JsonProperty) return null;
      final v = entry.value;
      if (v is JsonObject) return null;
      if (v is JsonArray) {
        for (final el in v.elements) {
          if (el is JsonObject) {
            if (el.properties.isEmpty) continue;
            final inner = _inlineObjectIfShort(el);
            if (inner == null) return null;
          } else if (el is JsonArray) {
            return null;
          }
        }
      }
    }
    final probe = StringBuffer('{ ');
    for (var i = 0; i < obj.properties.length; i++) {
      final entry = obj.properties[i] as JsonProperty;
      if (i > 0) probe.write(', ');
      probe.write(_emitKey(entry.key));
      probe.write(': ');
      probe.write(_inlinePrimitiveOrShortContainer(entry.value));
    }
    probe.write(' }');
    if (probe.length > opt.inlineObjectMax) return null;
    return probe.toString();
  }

  String _inlinePrimitiveOrShortContainer(JsonAstNode n) {
    if (n is JsonString) return _encodeString(n.value);
    if (n is JsonNumber) return _emitNumber(n.rawText);
    if (n is JsonBool) return n.value ? 'true' : 'false';
    if (n is JsonNull) return 'null';
    if (n is JsonArray) {
      if (n.elements.isEmpty) return '[]';
      final sb = StringBuffer('[ ');
      for (var i = 0; i < n.elements.length; i++) {
        if (i > 0) sb.write(', ');
        final el = n.elements[i];
        if (el is JsonObject) {
          sb.write(_inlineObjectIfShort(el) ?? '{}');
        } else {
          sb.write(_inlinePrimitiveOrShortContainer(el));
        }
      }
      sb.write(' ]');
      return sb.toString();
    }
    if (n is JsonObject) {
      return _inlineObjectIfShort(n) ?? '{}';
    }
    return '';
  }

  bool _canInlineArray(JsonArray arr) {
    // Any comment (standalone OR inline-trail) forces multi-line.
    for (final e in arr.elements) {
      if (e is CommentLine) return false;
      if (e is JsonObject || e is JsonArray) return false;
    }
    final probe = StringBuffer('[');
    for (var i = 0; i < arr.elements.length; i++) {
      if (i > 0) probe.write(', ');
      final e = arr.elements[i];
      if (e is JsonString) {
        probe.write(_encodeString(e.value));
      } else if (e is JsonNumber) {
        probe.write(_emitNumber(e.rawText));
      } else if (e is JsonBool) {
        probe.write(e.value ? 'true' : 'false');
      } else if (e is JsonNull) {
        probe.write('null');
      }
    }
    probe.write(']');
    return probe.length <= opt.inlineArrayMax;
  }

  static final RegExp _identRx = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

  String _emitKey(String k) {
    if (_identRx.hasMatch(k)) return k;
    return _encodeString(k);
  }

  String _emitNumber(String raw) {
    return raw;
  }

  String _encodeString(String s) {
    final sb = StringBuffer();
    sb.write('"');
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      switch (c) {
        case 0x22: sb.write('\\"'); break;
        case 0x5C: sb.write('\\\\'); break;
        case 0x0A: sb.write('\\n'); break;
        case 0x0D: sb.write('\\r'); break;
        case 0x09: sb.write('\\t'); break;
        case 0x08: sb.write('\\b'); break;
        case 0x0C: sb.write('\\f'); break;
        default:
          if (c < 0x20) {
            sb.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
          } else {
            sb.writeCharCode(c);
          }
      }
    }
    sb.write('"');
    return sb.toString();
  }
}
