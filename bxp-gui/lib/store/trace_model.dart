class VarEntry {
  final String kind; // 'eval' or 'error'
  final String name;
  final String? expr;
  final String? value;
  final String? error;
  final String? detail;

  VarEntry({required this.kind, required this.name, this.expr, this.value, this.error, this.detail});
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
