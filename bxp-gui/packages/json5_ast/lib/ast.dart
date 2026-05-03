class SourceSpan {
  final int startLine;
  final int startCol;
  final int startOffset;
  final int endLine;
  final int endCol;
  final int endOffset;
  const SourceSpan(this.startLine, this.startCol, this.startOffset,
      this.endLine, this.endCol, this.endOffset);
}

enum CommentStyle { line, block }

class CommentNode {
  final CommentStyle style;
  String text;
  SourceSpan? sourceSpan;
  CommentNode(this.style, this.text, {this.sourceSpan});

  CommentNode clone() => CommentNode(style, text, sourceSpan: sourceSpan);
}

abstract class JsonAstNode {
  // Phase 5e: ALL comments live as `CommentLine` peer entries inside their
  // parent container (`JsonObject.properties` / `JsonArray.elements`). No
  // more `trailingComment` slot — trailing inline comments are encoded as
  // CommentLine with `inlinePlacement: true`. This eliminates the
  // map-vs-array and standalone-vs-trailing asymmetries that required the
  // global $comm_<N> walker to compensate.
  SourceSpan? sourceSpan;

  JsonAstNode clone();
}

class JsonObject extends JsonAstNode {
  final List<JsonAstNode> properties = [];

  @override
  JsonObject clone() {
    final c = JsonObject();
    for (final p in properties) {
      c.properties.add(p.clone());
    }
    return c;
  }
}

class JsonProperty extends JsonAstNode {
  String key;
  JsonAstNode value;
  JsonProperty(this.key, this.value);

  @override
  JsonProperty clone() => JsonProperty(key, value.clone());
}

class JsonArray extends JsonAstNode {
  final List<JsonAstNode> elements = [];

  @override
  JsonArray clone() {
    final c = JsonArray();
    for (final e in elements) {
      c.elements.add(e.clone());
    }
    return c;
  }
}

class JsonString extends JsonAstNode {
  String value;
  JsonString(this.value);

  @override
  JsonString clone() => JsonString(value);
}

class JsonNumber extends JsonAstNode {
  String rawText;
  JsonNumber(this.rawText);

  @override
  JsonNumber clone() => JsonNumber(rawText);
}

class JsonBool extends JsonAstNode {
  bool value;
  JsonBool(this.value);

  @override
  JsonBool clone() => JsonBool(value);
}

class JsonNull extends JsonAstNode {
  @override
  JsonNull clone() => JsonNull();
}

class CommentLine extends JsonAstNode {
  final CommentNode comment;

  /// `true` when this comment was on the same source line as the previous
  /// real entry (e.g. `key: val // c`). The dumper renders it inline,
  /// attached to the preceding row, with a 2-space gap. `false` (default)
  /// = standalone row.
  bool inlinePlacement;

  CommentLine(this.comment, {this.inlinePlacement = false});

  @override
  CommentLine clone() =>
      CommentLine(comment.clone(), inlinePlacement: inlinePlacement);
}

enum Severity { error, warning }

class ParseDiagnostic {
  final Severity severity;
  final String message;
  final SourceSpan span;
  final List<dynamic>? path;
  const ParseDiagnostic(this.severity, this.message, this.span, {this.path});
}

class ParseResult {
  final JsonAstNode? root;
  final List<ParseDiagnostic> diagnostics;
  ParseResult(this.root, this.diagnostics);
  bool get hasErrors =>
      diagnostics.any((d) => d.severity == Severity.error);
}
