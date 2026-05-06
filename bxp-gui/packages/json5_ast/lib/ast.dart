/// Half-open character-level range in the original source string.
/// `startOffset` / `endOffset` are byte indices into the UTF-16 code-unit
/// sequence that Dart strings expose (which is the same as char positions
/// for BMP-only content, i.e. the expected JSON5 configs). Line and column
/// are 1-based and only used for human-readable error messages.
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

/// Whether a comment was introduced by `//` (line) or `/* … */` (block).
/// The dumper preserves the original style on round-trip — a block comment
/// written by the user remains a block comment after Save.
enum CommentStyle { line, block }

/// The content of a single comment. Shared between the container's
/// `CommentLine` peer entry and any `CommentLocation` references; mutating
/// `text` via `CommentLocation.replaceText` is immediately visible everywhere
/// that holds a reference to the same [CommentNode] — no cache invalidation
/// needed.
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

  /// Deep copy of this node. The clone tree is fully detached — mutating
  /// the clone never touches the original.
  ///
  /// **Note:** [sourceSpan] is intentionally NOT copied; clones come back
  /// with `sourceSpan == null`. Spans only describe positions in the
  /// originally-parsed source bytes, so a clone (which by definition has
  /// no source location) cannot truthfully carry them. The same applies
  /// to [JsonProperty.clone] and [JsonArray.clone] / [JsonObject.clone]
  /// which propagate this contract recursively. Consumers that rely on
  /// span info (e.g. error reporters) must operate on parsed nodes, not
  /// on cloned ones.
  JsonAstNode clone();
}

/// A JSON5 object `{ … }`. The [properties] list is insertion-ordered and may
/// contain [JsonProperty] entries interleaved with [CommentLine] pseudo-
/// entries. All comment peers live in this flat list (Phase 5e — no separate
/// trailingComment slot).
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

/// A key/value pair inside a [JsonObject]. Keys are always strings (including
/// unquoted identifiers — they are normalised to their bare string value by
/// the tokenizer). The value may be any [JsonAstNode] including a nested
/// [JsonObject] or [JsonArray].
class JsonProperty extends JsonAstNode {
  String key;
  JsonAstNode value;
  JsonProperty(this.key, this.value);

  @override
  JsonProperty clone() => JsonProperty(key, value.clone());
}

/// A JSON5 array `[ … ]`. Like [JsonObject.properties], the [elements] list
/// is a flat ordered sequence that may interleave real values with
/// [CommentLine] peers. Path indices into arrays are RAW (counting CommentLine
/// peers) to stay consistent with the convention in path.dart.
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

/// A JSON5 string scalar. [value] holds the decoded (unescaped) content;
/// the surrounding quotes are NOT stored. The dumper always re-encodes with
/// double quotes on output, normalising any single-quoted input strings.
class JsonString extends JsonAstNode {
  String value;
  JsonString(this.value);

  @override
  JsonString clone() => JsonString(value);
}

/// A JSON5 number scalar. [rawText] is the original source text (e.g.
/// `"1.00"`, `"0xFF"`, `"-Infinity"`) so round-trips preserve the author's
/// chosen notation. Arithmetic on number values should parse [rawText] with
/// `num.parse`; do NOT rely on the text form for numeric semantics.
class JsonNumber extends JsonAstNode {
  String rawText;
  JsonNumber(this.rawText);

  @override
  JsonNumber clone() => JsonNumber(rawText);
}

/// A JSON5 boolean literal (`true` or `false`).
class JsonBool extends JsonAstNode {
  bool value;
  JsonBool(this.value);

  @override
  JsonBool clone() => JsonBool(value);
}

/// A JSON5 `null` literal.
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

/// A single parse diagnostic. The [span] locates the offending source range;
/// [path] (when present) is the JSON path to the node being diagnosed — used
/// by the GUI to map errors back to tree rows.
class ParseDiagnostic {
  final Severity severity;
  final String message;
  final SourceSpan span;
  final List<dynamic>? path;
  const ParseDiagnostic(this.severity, this.message, this.span, {this.path});
}

/// Output of [Parser.parse]. When [root] is non-null the file was partially
/// or fully parsed; [diagnostics] may still be non-empty (e.g. trailing
/// garbage after the root). When [root] is null, the tokenizer or parser
/// threw a hard error and [diagnostics] carries the reason.
class ParseResult {
  final JsonAstNode? root;
  final List<ParseDiagnostic> diagnostics;
  ParseResult(this.root, this.diagnostics);
  bool get hasErrors =>
      diagnostics.any((d) => d.severity == Severity.error);
}
