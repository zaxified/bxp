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
    final alignW = _alignKeyWidth(obj);
    final lastPropIdx = _lastJsonPropertyIndex(obj.properties);
    final mainLines = <String?>[];
    final saved = _b;
    for (var i = 0; i < obj.properties.length; i++) {
      final entry = obj.properties[i];
      if (entry is JsonProperty) {
        final tmp = StringBuffer();
        _b = tmp;
        _writeObjectPropertyMainLine(entry, depth, alignW, i == lastPropIdx);
        _b = saved;
        mainLines.add(tmp.toString());
      } else {
        mainLines.add(null);
      }
    }
    final commentCol = _commentColumn(obj.properties, mainLines);
    for (var i = 0; i < obj.properties.length; i++) {
      final entry = obj.properties[i];
      if (entry is CommentLine) {
        _writeCommentLine(entry.comment, depth + 1);
        continue;
      }
      if (entry is JsonProperty) {
        final ml = mainLines[i]!;
        _b.write(ml);
        if (entry.trailingComment != null) {
          final pad = commentCol > ml.length
              ? commentCol - ml.length
              : opt.alignKeyGap;
          _b.write(' ' * pad);
          _writeInlineComment(entry.trailingComment!);
        }
        _b.write('\n');
        continue;
      }
      throw StateError('unexpected object child: ${entry.runtimeType}');
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

  int _lastJsonPropertyIndex(List<JsonAstNode> entries) {
    for (var i = entries.length - 1; i >= 0; i--) {
      if (entries[i] is JsonProperty) return i;
    }
    return -1;
  }

  int _commentColumn(List<JsonAstNode> entries, List<String?> mainLines) {
    int maxLen = 0;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.trailingComment != null && mainLines[i] != null) {
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
    final lastElIdx = _lastNonCommentIndex(arr.elements);
    final mainLines = <String?>[];
    final saved = _b;
    for (var i = 0; i < arr.elements.length; i++) {
      final e = arr.elements[i];
      if (e is CommentLine) {
        mainLines.add(null);
      } else {
        final tmp = StringBuffer();
        _b = tmp;
        _indent(depth + 1);
        _writeNode(e, depth + 1);
        if (i != lastElIdx) _b.write(',');
        _b = saved;
        mainLines.add(tmp.toString());
      }
    }
    final commentCol = _commentColumn(arr.elements, mainLines);
    for (var i = 0; i < arr.elements.length; i++) {
      final e = arr.elements[i];
      if (e is CommentLine) {
        _writeCommentLine(e.comment, depth + 1);
        continue;
      }
      final ml = mainLines[i]!;
      _b.write(ml);
      if (e.trailingComment != null) {
        final pad = commentCol > ml.length
            ? commentCol - ml.length
            : opt.alignKeyGap;
        _b.write(' ' * pad);
        _writeInlineComment(e.trailingComment!);
      }
      _b.write('\n');
    }
    _indent(depth);
    _b.write(']');
  }

  int _lastNonCommentIndex(List<JsonAstNode> entries) {
    for (var i = entries.length - 1; i >= 0; i--) {
      if (entries[i] is! CommentLine) return i;
    }
    return -1;
  }

  int _alignKeyWidth(JsonObject obj) {
    int m = 0;
    for (final entry in obj.properties) {
      if (entry is! JsonProperty) continue;
      if (entry.value is JsonObject || entry.value is JsonArray) continue;
      final k = _emitKey(entry.key).length;
      if (k > opt.alignKeyMaxLen) continue;
      if (k > m) m = k;
    }
    return m;
  }

  String? _inlineObjectIfShort(JsonObject obj) {
    for (final entry in obj.properties) {
      if (entry is! JsonProperty) return null;
      if (entry.trailingComment != null) return null;
      final v = entry.value;
      if (v is JsonObject) return null;
      if (v is JsonArray) {
        for (final el in v.elements) {
          if (el is JsonObject) {
            if (el.properties.isEmpty) continue;
            final inner = _inlineObjectIfShort(el);
            if (inner == null) return null;
          } else if (el is JsonArray || el is CommentLine) {
            return null;
          } else if (el.trailingComment != null) {
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
    for (final e in arr.elements) {
      if (e is CommentLine) return false;
      if (e is JsonObject || e is JsonArray) return false;
      if (e.trailingComment != null) return false;
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
