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
  final List<CommentNode> leadingComments = [];
  CommentNode? trailingComment;
  SourceSpan? sourceSpan;

  JsonAstNode clone();
}

class JsonObject extends JsonAstNode {
  final List<JsonAstNode> properties = [];

  @override
  JsonObject clone() {
    final c = JsonObject();
    c.leadingComments.addAll(leadingComments.map((x) => x.clone()));
    c.trailingComment = trailingComment?.clone();
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
  JsonProperty clone() {
    final c = JsonProperty(key, value.clone());
    c.leadingComments.addAll(leadingComments.map((x) => x.clone()));
    c.trailingComment = trailingComment?.clone();
    return c;
  }
}

class JsonArray extends JsonAstNode {
  final List<JsonAstNode> elements = [];

  @override
  JsonArray clone() {
    final c = JsonArray();
    c.leadingComments.addAll(leadingComments.map((x) => x.clone()));
    c.trailingComment = trailingComment?.clone();
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
  JsonString clone() {
    final c = JsonString(value);
    c.leadingComments.addAll(leadingComments.map((x) => x.clone()));
    c.trailingComment = trailingComment?.clone();
    return c;
  }
}

class JsonNumber extends JsonAstNode {
  String rawText;
  JsonNumber(this.rawText);

  @override
  JsonNumber clone() {
    final c = JsonNumber(rawText);
    c.leadingComments.addAll(leadingComments.map((x) => x.clone()));
    c.trailingComment = trailingComment?.clone();
    return c;
  }
}

class JsonBool extends JsonAstNode {
  bool value;
  JsonBool(this.value);

  @override
  JsonBool clone() {
    final c = JsonBool(value);
    c.leadingComments.addAll(leadingComments.map((x) => x.clone()));
    c.trailingComment = trailingComment?.clone();
    return c;
  }
}

class JsonNull extends JsonAstNode {
  @override
  JsonNull clone() {
    final c = JsonNull();
    c.leadingComments.addAll(leadingComments.map((x) => x.clone()));
    c.trailingComment = trailingComment?.clone();
    return c;
  }
}

class CommentLine extends JsonAstNode {
  final CommentNode comment;
  CommentLine(this.comment);

  @override
  CommentLine clone() => CommentLine(comment.clone());
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
