class VarEntry {
  final String kind; // 'eval' or 'error'
  final String name;
  final String? expr;
  final String? value;
  final String? error;
  final String? detail;
  // Where this variable was defined. 'input_schema' (default) for vars
  // declared at the top of a conversion template, 'row_rules' for vars
  // defined inside the matched row_rules[ruleIndex].rows[*] override block.
  // Drives the split between the Variables table and the Rule-Results
  // panel in row_detail.dart.
  final String origin;
  final int? ruleIndex;
  // Index inside `row_rules[ruleIndex].rows[]` for vars that came from a
  // rule's per-output-row override block. Null for input_schema vars (and
  // for older trace files without the field).
  final int? outputRowIndex;

  VarEntry({
    required this.kind,
    required this.name,
    this.expr,
    this.value,
    this.error,
    this.detail,
    this.origin = 'input_schema',
    this.ruleIndex,
    this.outputRowIndex,
  });
}

class RuleEntry {
  final int ruleIndex;
  final String when;
  final bool matched;
  final List<Map<String, String>> rows;

  RuleEntry({required this.ruleIndex, required this.when, required this.matched, required this.rows});
}

class RowModel {
  final String id;
  final String fileId;
  final int fileRow;
  final List<String> fields;
  final List<VarEntry> vars = [];
  final List<RuleEntry> rules = [];
  String? filteredReason;
  final List<List<String>> outputs = [];
  int? matchedRuleIndex;
  bool hasError = false;

  RowModel({required this.id, required this.fileId, required this.fileRow, required this.fields});
}

class PrepassEntry {
  final String key;
  final String field;
  final String value;
  const PrepassEntry({required this.key, required this.field, required this.value});
}

/// One entry in the per-call trace produced by `bxp-fmt --expr-trace`. Used
/// by the GUI's hover-on-token feature to surface the evaluated value of a
/// nested function call (e.g. ABS([Fee]) → "1.50") without re-running the
/// whole pipeline. `srcStart`/`srcEnd` are byte offsets into the expression
/// source so the GUI can match a token's position to its trace entry.
class ExprCallTrace {
  final String fn;
  final int srcStart;
  final int srcEnd;
  final String value;
  const ExprCallTrace({
    required this.fn,
    required this.srcStart,
    required this.srcEnd,
    required this.value,
  });
}

class FileModel {
  final String id;
  final String template;
  final String path;
  final int rows;
  final List<String> headers;      // input CSV headers
  List<String> outputHeaders = []; // output schema headers (from row_output event)
  final List<String> rowIds = [];
  // Pre-pass lookup table entries collected from `prepass_set` events
  // before the main row loop. Mirrors bxp-ui's `FileModel.prepass`.
  // Surfaced in the UI via FileList expandable detail / future LOOKUP
  // debug pane; for now we capture them so the trace round-trip is loss-
  // less.
  final List<PrepassEntry> prepass = [];
  Map<String, dynamic>? stats;

  FileModel({required this.id, required this.template, required this.path, required this.rows, required this.headers});
}

class TraceModel {
  Map<String, dynamic>? start;
  Map<String, dynamic>? done;
  final Map<String, FileModel> files = {};
  final List<String> fileOrder = [];
  final Map<String, RowModel> rows = {};
  final List<String> issues = [];
}
