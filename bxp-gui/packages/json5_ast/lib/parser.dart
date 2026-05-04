import 'ast.dart';
import 'src/tokenizer.dart';

class ParserError implements Exception {
  final String message;
  final SourceSpan span;
  ParserError(this.message, this.span);
  @override
  String toString() => 'ParserError@${span.startLine}:${span.startCol}: $message';
}

class Parser {
  final List<Token> _toks;
  int _p = 0;

  Parser(this._toks);

  static ParseResult parse(String src) {
    final diagnostics = <ParseDiagnostic>[];
    JsonAstNode? root;
    try {
      // Tokenization is inside the try so common user typos (unterminated
      // string, bad `\u` escape, `+` with no digit, unclosed `/* ... */`)
      // surface as a `ParseDiagnostic` rather than crashing the loader.
      final tokens = Tokenizer(src).tokenize();
      final p = Parser(tokens);
      final leadingComments = p._collectStandaloneComments();
      root = p._parseValue();
      // Top-of-file standalone comments: prepend as CommentLine pseudo-entries
      // into the root container (Object/Array) so they live as siblings of
      // the real entries — matching how mid-file standalone comments are
      // represented. This unification is what enables `$comm_<N>` move ops
      // to swap with adjacent rows without leading-vs-standalone special-casing.
      if (root is JsonObject) {
        for (var i = 0; i < leadingComments.length; i++) {
          root.properties.insert(i, CommentLine(leadingComments[i]));
        }
      } else if (root is JsonArray) {
        for (var i = 0; i < leadingComments.length; i++) {
          root.elements.insert(i, CommentLine(leadingComments[i]));
        }
      }
      final tailComments = p._collectStandaloneComments();
      if (root is JsonObject) {
        for (final c in tailComments) {
          root.properties.add(CommentLine(c));
        }
      } else if (root is JsonArray) {
        for (final c in tailComments) {
          root.elements.add(CommentLine(c));
        }
      }
      if (p._peek().kind != TokKind.eof) {
        diagnostics.add(ParseDiagnostic(
          Severity.error,
          'unexpected token after root: ${p._peek().kind}',
          p._peek().span,
        ));
      }
    } on ParserError catch (e) {
      diagnostics.add(ParseDiagnostic(Severity.error, e.message, e.span));
    } on TokenizerError catch (e) {
      diagnostics.add(ParseDiagnostic(
        Severity.error,
        e.message,
        SourceSpan(e.line, e.col, e.offset, e.line, e.col, e.offset),
      ));
    }
    return ParseResult(root, diagnostics);
  }

  Token _peek([int delta = 0]) => _toks[_p + delta];

  Token _advance() => _toks[_p++];

  void _skipNewlines() {
    while (_peek().kind == TokKind.newline) {
      _advance();
    }
  }

  /// Consume any mix of newline / line-comment / block-comment tokens
  /// and return the comments captured along the way. Used at every
  /// inter-token whitespace position the JSON5 grammar permits — the
  /// spec says "comments may appear before and after any JSON5Token",
  /// so the parser captures them rather than rejecting at positions
  /// like `key /*c*/ :` or `value /*c*/ ,`. Captured comments are
  /// added by the caller to the nearest container as standalone
  /// `CommentLine` peer entries (canonicalised to their own line on
  /// the next dump; round-trip stays idempotent because the second
  /// parse re-captures them in the same place).
  List<CommentNode> _skipNewlinesAndComments() {
    final out = <CommentNode>[];
    while (true) {
      final k = _peek().kind;
      if (k == TokKind.newline) {
        _advance();
        continue;
      }
      if (k == TokKind.commentLine || k == TokKind.commentBlock) {
        final tok = _advance();
        out.add(CommentNode(
          tok.kind == TokKind.commentLine
              ? CommentStyle.line
              : CommentStyle.block,
          tok.value ?? '',
          sourceSpan: tok.span,
        ));
        continue;
      }
      break;
    }
    return out;
  }

  /// Collects sequence of comments that appear on their own lines.
  /// "Standalone" = preceded by a newline (or start of stream).
  /// Stops at the first real token.
  List<CommentNode> _collectStandaloneComments() {
    final out = <CommentNode>[];
    _skipNewlines();
    while (_peek().kind == TokKind.commentLine ||
        _peek().kind == TokKind.commentBlock) {
      final tok = _advance();
      out.add(CommentNode(
        tok.kind == TokKind.commentLine
            ? CommentStyle.line
            : CommentStyle.block,
        tok.value ?? '',
        sourceSpan: tok.span,
      ));
      _skipNewlines();
    }
    return out;
  }

  /// Returns trailing comment if next token (before any newline) is a comment.
  CommentNode? _maybeTrailingComment() {
    if (_peek().kind == TokKind.commentLine ||
        _peek().kind == TokKind.commentBlock) {
      final tok = _advance();
      return CommentNode(
        tok.kind == TokKind.commentLine
            ? CommentStyle.line
            : CommentStyle.block,
        tok.value ?? '',
        sourceSpan: tok.span,
      );
    }
    return null;
  }

  JsonAstNode _parseValue() {
    _skipNewlines();
    final tok = _peek();
    switch (tok.kind) {
      case TokKind.lbrace:
        return _parseObject();
      case TokKind.lbracket:
        return _parseArray();
      case TokKind.string:
        _advance();
        final n = JsonString(tok.value ?? '');
        n.sourceSpan = tok.span;
        return n;
      case TokKind.number:
        _advance();
        final n = JsonNumber(tok.raw);
        n.sourceSpan = tok.span;
        return n;
      case TokKind.trueLit:
        _advance();
        final n = JsonBool(true);
        n.sourceSpan = tok.span;
        return n;
      case TokKind.falseLit:
        _advance();
        final n = JsonBool(false);
        n.sourceSpan = tok.span;
        return n;
      case TokKind.nullLit:
        _advance();
        final n = JsonNull();
        n.sourceSpan = tok.span;
        return n;
      case TokKind.infinityLit:
      case TokKind.nanLit:
        _advance();
        final n = JsonNumber(tok.raw);
        n.sourceSpan = tok.span;
        return n;
      default:
        throw ParserError(
            "unexpected token '${tok.raw}' (${tok.kind})", tok.span);
    }
  }

  JsonObject _parseObject() {
    final start = _advance();
    final obj = JsonObject();
    obj.sourceSpan = start.span;
    while (true) {
      // Standalone comments (between props OR before close brace) are
      // emitted as CommentLine pseudo-entries — same shape as in arrays,
      // so move/edit/delete on `$comm_<N>` can treat the parent map and
      // its children uniformly as a single insertion-ordered container.
      final leading = _collectStandaloneComments();
      for (final c in leading) {
        obj.properties.add(CommentLine(c));
      }
      _skipNewlines();
      if (_peek().kind == TokKind.rbrace) {
        _advance();
        return obj;
      }
      final keyTok = _peek();
      String key;
      if (keyTok.kind == TokKind.string) {
        _advance();
        key = keyTok.value ?? '';
      } else if (keyTok.kind == TokKind.ident) {
        _advance();
        key = keyTok.value ?? '';
      } else {
        throw ParserError(
            "expected key, got '${keyTok.raw}' (${keyTok.kind})",
            keyTok.span);
      }
      // Phase 4D: spec allows comments anywhere whitespace can appear,
      // including between key and ':' / ':' and value / value and ','.
      // Capture each gap and route into the parent container as
      // standalone CommentLine peer entries; placement before vs after
      // the property is chosen so the canonical dump renders the
      // comment closest to where it was in the source.
      final betweenKeyAndColon = _skipNewlinesAndComments();
      for (final c in betweenKeyAndColon) {
        obj.properties.add(CommentLine(c));
      }
      if (_peek().kind != TokKind.colon) {
        throw ParserError(
            "expected ':' after key '$key', got '${_peek().raw}'",
            _peek().span);
      }
      _advance();
      final betweenColonAndValue = _skipNewlinesAndComments();
      for (final c in betweenColonAndValue) {
        obj.properties.add(CommentLine(c));
      }
      final value = _parseValue();
      final prop = JsonProperty(key, value);
      // Phase 4D: the gap between value and the comma/closer can contain
      // both an inline same-line comment (e.g. `value // trail`) AND
      // newline-separated standalone comments (e.g.
      // `value\n  // alone\n  ,`). Order matters for round-trip:
      //   1. `_maybeTrailingComment` — captures only if next token is a
      //      comment immediately on the same line; preserves inline-trail
      //      visual placement.
      //   2. `_skipNewlinesAndComments` — captures any standalone
      //      comments that follow on their own lines.
      final inlineBeforeDelim = _maybeTrailingComment();
      final standaloneBeforeDelim = _skipNewlinesAndComments();
      // optional trailing comma
      bool hadComma = false;
      if (_peek().kind == TokKind.comma) {
        _advance();
        hadComma = true;
      }
      obj.properties.add(prop);
      if (inlineBeforeDelim != null) {
        obj.properties.add(CommentLine(inlineBeforeDelim, inlinePlacement: true));
      }
      for (final c in standaloneBeforeDelim) {
        obj.properties.add(CommentLine(c));
      }
      // Phase 5e: trailing inline comment on same line as the comma is
      // emitted as a CommentLine with inlinePlacement=true — peer entry
      // in the container, NOT a slot inside the property. Dumper
      // restores the visual "key: val, // comment" layout via the flag.
      final trailing = _maybeTrailingComment();
      if (trailing != null) {
        obj.properties.add(CommentLine(trailing, inlinePlacement: true));
      }
      if (!hadComma) {
        _skipNewlines();
        if (_peek().kind == TokKind.rbrace) {
          _advance();
          return obj;
        }
      }
    }
  }

  JsonArray _parseArray() {
    final start = _advance();
    final arr = JsonArray();
    arr.sourceSpan = start.span;
    while (true) {
      final leading = _collectStandaloneComments();
      // For arrays, standalone comments are pseudo-elements.
      for (final c in leading) {
        arr.elements.add(CommentLine(c));
      }
      _skipNewlines();
      if (_peek().kind == TokKind.rbracket) {
        _advance();
        return arr;
      }
      final el = _parseValue();
      // Phase 4D: same as object's after-value handling — capture
      // inline same-line trail first (preserves `value // trail` layout
      // through the round-trip), then standalone comments before the
      // delimiter.
      final inlineBeforeDelim = _maybeTrailingComment();
      final standaloneBeforeDelim = _skipNewlinesAndComments();
      bool hadComma = false;
      if (_peek().kind == TokKind.comma) {
        _advance();
        hadComma = true;
      }
      arr.elements.add(el);
      if (inlineBeforeDelim != null) {
        arr.elements.add(CommentLine(inlineBeforeDelim, inlinePlacement: true));
      }
      for (final c in standaloneBeforeDelim) {
        arr.elements.add(CommentLine(c));
      }
      // Phase 5e: trailing inline as peer CommentLine, not slot on `el`.
      final trailing = _maybeTrailingComment();
      if (trailing != null) {
        arr.elements.add(CommentLine(trailing, inlinePlacement: true));
      }
      if (!hadComma) {
        _skipNewlines();
        if (_peek().kind == TokKind.rbracket) {
          _advance();
          return arr;
        }
      }
    }
  }
}
