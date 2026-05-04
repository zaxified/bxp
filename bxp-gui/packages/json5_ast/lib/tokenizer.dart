import 'ast.dart';

enum TokKind {
  lbrace, rbrace, lbracket, rbracket,
  colon, comma,
  string, ident, number,
  trueLit, falseLit, nullLit, infinityLit, nanLit,
  commentLine, commentBlock,
  newline,
  eof,
}

class Token {
  final TokKind kind;
  final String raw;
  final String? value;
  final SourceSpan span;
  Token(this.kind, this.raw, this.value, this.span);
  @override
  String toString() => '$kind(${value ?? raw})';
}

class TokenizerError implements Exception {
  final String message;
  final int offset;
  final int line;
  final int col;
  TokenizerError(this.message, this.offset, this.line, this.col);
  @override
  String toString() => 'TokenizerError@$line:$col: $message';
}

class Tokenizer {
  final String src;
  int _i = 0;
  int _line = 1;
  int _col = 1;

  Tokenizer(this.src);

  List<Token> tokenize() {
    final out = <Token>[];
    while (_i < src.length) {
      final startLine = _line, startCol = _col, startOff = _i;
      final c = src.codeUnitAt(_i);

      if (c == 0x20 || c == 0x09 || c == 0x0D) {
        _advance();
        continue;
      }
      if (c == 0x0A) {
        _advance();
        out.add(Token(TokKind.newline, '\n', null,
            SourceSpan(startLine, startCol, startOff, _line, _col, _i)));
        continue;
      }
      if (c == 0x2F) {
        if (_peek(1) == 0x2F) {
          out.add(_readLineComment(startLine, startCol, startOff));
          continue;
        }
        if (_peek(1) == 0x2A) {
          out.add(_readBlockComment(startLine, startCol, startOff));
          continue;
        }
        throw TokenizerError(
            "unexpected '/'", _i, _line, _col);
      }
      if (c == 0x7B) {
        _advance();
        out.add(Token(TokKind.lbrace, '{', null,
            SourceSpan(startLine, startCol, startOff, _line, _col, _i)));
        continue;
      }
      if (c == 0x7D) {
        _advance();
        out.add(Token(TokKind.rbrace, '}', null,
            SourceSpan(startLine, startCol, startOff, _line, _col, _i)));
        continue;
      }
      if (c == 0x5B) {
        _advance();
        out.add(Token(TokKind.lbracket, '[', null,
            SourceSpan(startLine, startCol, startOff, _line, _col, _i)));
        continue;
      }
      if (c == 0x5D) {
        _advance();
        out.add(Token(TokKind.rbracket, ']', null,
            SourceSpan(startLine, startCol, startOff, _line, _col, _i)));
        continue;
      }
      if (c == 0x3A) {
        _advance();
        out.add(Token(TokKind.colon, ':', null,
            SourceSpan(startLine, startCol, startOff, _line, _col, _i)));
        continue;
      }
      if (c == 0x2C) {
        _advance();
        out.add(Token(TokKind.comma, ',', null,
            SourceSpan(startLine, startCol, startOff, _line, _col, _i)));
        continue;
      }
      if (c == 0x22 || c == 0x27) {
        out.add(_readString(c, startLine, startCol, startOff));
        continue;
      }
      if (_isDigit(c) || c == 0x2E || c == 0x2D || c == 0x2B) {
        final tok = _maybeReadNumberOrSign(startLine, startCol, startOff);
        if (tok != null) {
          out.add(tok);
          continue;
        }
      }
      if (_isIdentStart(c)) {
        out.add(_readIdent(startLine, startCol, startOff));
        continue;
      }
      throw TokenizerError(
          "unexpected character '${String.fromCharCode(c)}' (0x${c.toRadixString(16)})",
          _i, _line, _col);
    }
    out.add(Token(TokKind.eof, '', null,
        SourceSpan(_line, _col, _i, _line, _col, _i)));
    return out;
  }

  void _advance() {
    final c = src.codeUnitAt(_i);
    _i++;
    if (c == 0x0A) {
      _line++;
      _col = 1;
    } else {
      _col++;
    }
  }

  int _peek(int delta) =>
      (_i + delta < src.length) ? src.codeUnitAt(_i + delta) : -1;

  bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
  bool _isHex(int c) =>
      _isDigit(c) ||
      (c >= 0x41 && c <= 0x46) ||
      (c >= 0x61 && c <= 0x66);
  bool _isIdentStart(int c) =>
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F || c == 0x24;
  bool _isIdentCont(int c) => _isIdentStart(c) || _isDigit(c);

  Token _readLineComment(int sl, int sc, int so) {
    final sb = StringBuffer();
    _advance(); _advance();
    while (_i < src.length && src.codeUnitAt(_i) != 0x0A) {
      sb.writeCharCode(src.codeUnitAt(_i));
      _advance();
    }
    return Token(TokKind.commentLine, '//${sb.toString()}', sb.toString(),
        SourceSpan(sl, sc, so, _line, _col, _i));
  }

  Token _readBlockComment(int sl, int sc, int so) {
    final sb = StringBuffer();
    _advance(); _advance();
    while (_i < src.length) {
      if (src.codeUnitAt(_i) == 0x2A && _peek(1) == 0x2F) {
        _advance(); _advance();
        return Token(TokKind.commentBlock, '/*${sb.toString()}*/',
            sb.toString(),
            SourceSpan(sl, sc, so, _line, _col, _i));
      }
      sb.writeCharCode(src.codeUnitAt(_i));
      _advance();
    }
    throw TokenizerError("unterminated block comment", so, sl, sc);
  }

  Token _readString(int quote, int sl, int sc, int so) {
    _advance();
    final sb = StringBuffer();
    while (_i < src.length) {
      final c = src.codeUnitAt(_i);
      if (c == quote) {
        _advance();
        return Token(TokKind.string,
            String.fromCharCode(quote) + sb.toString() + String.fromCharCode(quote),
            sb.toString(),
            SourceSpan(sl, sc, so, _line, _col, _i));
      }
      if (c == 0x5C) {
        _advance();
        if (_i >= src.length) {
          throw TokenizerError("unterminated escape", _i, _line, _col);
        }
        final e = src.codeUnitAt(_i);
        if (e == 0x0A) {
          _advance();
          continue;
        }
        if (e == 0x0D) {
          _advance();
          if (_i < src.length && src.codeUnitAt(_i) == 0x0A) _advance();
          continue;
        }
        switch (e) {
          case 0x6E: sb.writeCharCode(0x0A); _advance(); break;
          case 0x74: sb.writeCharCode(0x09); _advance(); break;
          case 0x72: sb.writeCharCode(0x0D); _advance(); break;
          case 0x62: sb.writeCharCode(0x08); _advance(); break;
          case 0x66: sb.writeCharCode(0x0C); _advance(); break;
          case 0x76: sb.writeCharCode(0x0B); _advance(); break;
          case 0x30: sb.writeCharCode(0x00); _advance(); break;
          case 0x5C: sb.writeCharCode(0x5C); _advance(); break;
          case 0x27: sb.writeCharCode(0x27); _advance(); break;
          case 0x22: sb.writeCharCode(0x22); _advance(); break;
          case 0x2F: sb.writeCharCode(0x2F); _advance(); break;
          case 0x78: {
            _advance();
            sb.writeCharCode(_readHexChars(2));
            break;
          }
          case 0x75: {
            _advance();
            sb.writeCharCode(_readHexChars(4));
            break;
          }
          default:
            sb.writeCharCode(e);
            _advance();
        }
        continue;
      }
      if (c == 0x0A) {
        throw TokenizerError("unescaped newline in string", _i, _line, _col);
      }
      sb.writeCharCode(c);
      _advance();
    }
    throw TokenizerError("unterminated string", so, sl, sc);
  }

  int _readHexChars(int n) {
    int val = 0;
    for (var k = 0; k < n; k++) {
      if (_i >= src.length) {
        throw TokenizerError("bad hex escape", _i, _line, _col);
      }
      final h = src.codeUnitAt(_i);
      if (!_isHex(h)) {
        throw TokenizerError("bad hex escape", _i, _line, _col);
      }
      val = (val << 4) | _hexVal(h);
      _advance();
    }
    return val;
  }

  int _hexVal(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return 0;
  }

  Token? _maybeReadNumberOrSign(int sl, int sc, int so) {
    final start = _i;
    int c = src.codeUnitAt(_i);
    final hasSign = (c == 0x2D || c == 0x2B);
    if (hasSign) {
      _advance();
      if (_i >= src.length) { _i = start; return null; }
      c = src.codeUnitAt(_i);
    }
    if (c == 0x49) {
      if (_matchKeyword('Infinity')) {
        final raw = src.substring(start, _i);
        return Token(TokKind.infinityLit, raw, raw,
            SourceSpan(sl, sc, so, _line, _col, _i));
      }
      _i = start; _line = sl; _col = sc;
      return null;
    }
    if (c == 0x4E) {
      if (_matchKeyword('NaN')) {
        final raw = src.substring(start, _i);
        return Token(TokKind.nanLit, raw, raw,
            SourceSpan(sl, sc, so, _line, _col, _i));
      }
      _i = start; _line = sl; _col = sc;
      return null;
    }
    if (!_isDigit(c) && c != 0x2E) {
      if (hasSign) {
        throw TokenizerError("expected digit after sign", _i, _line, _col);
      }
      _i = start; _line = sl; _col = sc;
      return null;
    }
    if (c == 0x30 && _i + 1 < src.length) {
      final nx = src.codeUnitAt(_i + 1);
      if (nx == 0x78 || nx == 0x58) {
        _advance(); _advance();
        var any = false;
        while (_i < src.length && _isHex(src.codeUnitAt(_i))) {
          _advance(); any = true;
        }
        if (!any) {
          throw TokenizerError("bad hex literal", _i, _line, _col);
        }
        final raw = src.substring(start, _i);
        return Token(TokKind.number, raw, raw,
            SourceSpan(sl, sc, so, _line, _col, _i));
      }
    }
    while (_i < src.length && _isDigit(src.codeUnitAt(_i))) {
      _advance();
    }
    if (_i < src.length && src.codeUnitAt(_i) == 0x2E) {
      _advance();
      while (_i < src.length && _isDigit(src.codeUnitAt(_i))) {
        _advance();
      }
    }
    if (_i < src.length &&
        (src.codeUnitAt(_i) == 0x65 || src.codeUnitAt(_i) == 0x45)) {
      _advance();
      if (_i < src.length &&
          (src.codeUnitAt(_i) == 0x2B || src.codeUnitAt(_i) == 0x2D)) {
        _advance();
      }
      // ECMAScript ExponentPart requires at least one digit after the
      // exponent indicator (and optional sign). `1e`, `1E+`, `1e-`
      // without a trailing digit are rejected per spec — even though
      // a tolerant reader could ingest them.
      if (_i >= src.length || !_isDigit(src.codeUnitAt(_i))) {
        throw TokenizerError("expected digit after exponent", _i, _line, _col);
      }
      while (_i < src.length && _isDigit(src.codeUnitAt(_i))) {
        _advance();
      }
    }
    final raw = src.substring(start, _i);
    return Token(TokKind.number, raw, raw,
        SourceSpan(sl, sc, so, _line, _col, _i));
  }

  bool _matchKeyword(String kw) {
    if (_i + kw.length > src.length) return false;
    for (var k = 0; k < kw.length; k++) {
      if (src.codeUnitAt(_i + k) != kw.codeUnitAt(k)) return false;
    }
    final after = _i + kw.length;
    if (after < src.length && _isIdentCont(src.codeUnitAt(after))) {
      return false;
    }
    for (var k = 0; k < kw.length; k++) {
      _advance();
    }
    return true;
  }

  Token _readIdent(int sl, int sc, int so) {
    final start = _i;
    while (_i < src.length && _isIdentCont(src.codeUnitAt(_i))) {
      _advance();
    }
    final raw = src.substring(start, _i);
    switch (raw) {
      case 'true':
        return Token(TokKind.trueLit, raw, raw,
            SourceSpan(sl, sc, so, _line, _col, _i));
      case 'false':
        return Token(TokKind.falseLit, raw, raw,
            SourceSpan(sl, sc, so, _line, _col, _i));
      case 'null':
        return Token(TokKind.nullLit, raw, raw,
            SourceSpan(sl, sc, so, _line, _col, _i));
      case 'Infinity':
        return Token(TokKind.infinityLit, raw, raw,
            SourceSpan(sl, sc, so, _line, _col, _i));
      case 'NaN':
        return Token(TokKind.nanLit, raw, raw,
            SourceSpan(sl, sc, so, _line, _col, _i));
      default:
        return Token(TokKind.ident, raw, raw,
            SourceSpan(sl, sc, so, _line, _col, _i));
    }
  }
}
