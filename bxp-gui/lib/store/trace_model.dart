/// One variable evaluation entry from a `var_eval` or `var_error` trace event.
///
/// A single CSV row can produce multiple VarEntries for the same variable name
/// when row_rules override blocks re-evaluate it with a different expression.
/// Callers group entries by [name] and filter by [origin] to separate the
/// top-level Variables table from the Rule-Results breakdown.
class VarEntry {
  /// `'eval'` for a successful evaluation, `'error'` for a failed one.
  /// Drives the cell background colour in the Variables table.
  final String kind;
  final String name;
  /// The expression source text, as recorded in the trace event. Displayed
  /// in the expr column of the Variables table; null for synthetic variables.
  final String? expr;
  /// Evaluated string value, populated on `kind == 'eval'`. May be the
  /// empty string — that's a valid output value, not a missing one.
  final String? value;
  /// Short error code from the expression evaluator, populated on
  /// `kind == 'error'`. Human-readable title, e.g. "UnexpectedToken".
  final String? error;
  /// Longer detail string accompanying [error] where available.
  final String? detail;
  /// Where this variable was defined. `'input_schema'` (default) for vars
  /// declared at the top of a conversion template, `'row_rules'` for vars
  /// defined inside the matched `row_rules[ruleIndex].rows[*]` override block.
  /// Drives the split between the Variables table and the Rule-Results
  /// panel in row_detail.dart.
  final String origin;
  /// Which row_rule index this variable came from. Null for `input_schema`
  /// vars. Matches `rule_index` in the trace event (real-only count).
  final int? ruleIndex;
  /// Index inside `row_rules[ruleIndex].rows[]` for vars that came from a
  /// rule's per-output-row override block. Null for input_schema vars (and
  /// for older trace files without the field).
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

/// One rule evaluation entry from a `rule_match` or `rule_no_match` event.
///
/// All rules for a given CSV row are recorded regardless of whether they
/// matched — the UI shows the full decision tree so the user can debug
/// why a specific rule did or didn't fire. Only the FIRST matched rule's
/// [rows] are used for output generation; subsequent rule matches are
/// informational.
class RuleEntry {
  /// The real-only rule index (position in `row_rules` excluding comments),
  /// matching `rule_index` in the trace event.
  final int ruleIndex;
  /// The `when` expression text as written in the config. Displayed in the
  /// rule-match table header.
  final String when;
  /// True if the `when` expression evaluated to a non-empty, non-zero string
  /// for this row.
  final bool matched;
  /// Output row templates from the `rows` array — each entry maps output-
  /// schema variable names to expression strings. Empty for unmatched rules
  /// and for rules with no `rows` block (filter-only rules).
  final List<Map<String, String>> rows;

  RuleEntry({required this.ruleIndex, required this.when, required this.matched, required this.rows});
}

/// All trace data collected for one input CSV row.
///
/// Populated incrementally as `var_eval`, `var_error`, `rule_match`,
/// `rule_no_match`, `row_filtered`, and `row_output` events arrive. The
/// [id] is a local synthetic key (`r0`, `r1`, …) assigned by `TraceBuilder`;
/// it has no relation to `file_row` which is the 1-based physical line number
/// in the source CSV.
class RowModel {
  /// Synthetic row key assigned by `TraceBuilder` in the order rows are
  /// encountered across all files in this run. Used as the map key in
  /// `TraceModel.rows`.
  final String id;
  /// The parent `FileModel.id` this row belongs to.
  final String fileId;
  /// 1-based physical row number in the source CSV (as reported by bxp-cli's
  /// `file_row` field). Used for display; may differ from the position in
  /// `FileModel.rowIds` if rows were filtered before tracing started.
  final int fileRow;
  /// Raw CSV field values for this row, in column order matching
  /// `FileModel.headers`. NDJSON mode populates this from `row_start`;
  /// btrace mode leaves it empty until file activation populates it (small
  /// files: full sweep at click time, large files: lazy on visible-window
  /// entry or filter scan). Track populated-vs-empty via [fieldsPopulated]
  /// — an empty `fields` list could mean either "no source columns" or
  /// "deferred lazy populate", and the latter must not be confused for the
  /// former by renderers / filter predicates.
  List<String> fields;
  /// True when [fields] holds the actual source-row content (or has been
  /// confirmed empty for a row with no source columns). False means the
  /// content is still on disk and a sync read via the active
  /// `RandomAccessFile` is required to materialise it. Set by
  /// `TraceStore._populateRowSync` / activation sweep; cleared by
  /// `TraceStore._deactivateFile` for small files (RAM reclaim — re-populate
  /// on re-activation is cheap).
  bool fieldsPopulated = false;
  /// Variable evaluations (input_schema + row_rules overrides), appended as
  /// trace events arrive. May be empty for filtered rows.
  final List<VarEntry> vars = [];
  /// Rule evaluations for this row. Includes both matched and unmatched rules
  /// so the user can inspect the full decision tree.
  final List<RuleEntry> rules = [];
  /// Non-null when this row was dropped by a filter expression; contains the
  /// filter reason string from the `row_filtered` event.
  String? filteredReason;
  /// Output rows produced by the matched rule's `rows` block. Each inner list
  /// is one output CSV row, parallel to `FileModel.outputHeaders`.
  final List<List<String>> outputs = [];
  /// Index of the first rule that matched, or null for filtered/unmatched rows.
  int? matchedRuleIndex;
  /// True when any `var_error` event / `error_row` btrace frame was
  /// received for this row. Semantically a WARNING in bxp-cli's
  /// vocabulary (legacy field name preserved for backward compatibility).
  bool hasError = false;
  /// Human-readable details collected from `error_row` frames for this
  /// row — `"<errorKind>: <detail> (in <varName>)"` per failed
  /// expression. Surfaced in the RowList tooltip + RowDetail banner so
  /// the user sees *why* the row was flagged without drilling down.
  /// Empty when no warnings landed on this row.
  final List<String> warningDetails = [];

  // ── Btrace mode metadata ───────────────────────────────────────────────
  // Populated by `TraceStore._streamRunBtrace` from `output_row` frames so
  // drill-down can lazy-fetch the source/output rows + re-eval expressions
  // on demand. Default values match what NDJSON mode would leave them at
  // (NDJSON populates everything synchronously, so `detailLoaded` stays
  // true and these locator fields are never consulted).

  /// Byte offset of the source CSV row this trace row was built from.
  /// Used by [CsvRowFetcher.lineAt] to fetch the raw source line during
  /// btrace-mode drill-down. -1 in NDJSON mode.
  int sourceLocator = -1;
  /// Per-file 0-based output-row index (`output_row.outputIdx`). Used as
  /// the index into `FileModel.outputOffsets[]` to derive the byte offset
  /// of the corresponding output.csvx line. -1 in NDJSON mode. Set from
  /// the FIRST `output_row` frame received for this source row — for
  /// 1:N templates (single source producing N outputs) `outputIdxs`
  /// below carries the full list.
  int outputIdx = -1;
  /// Action label carried by the `output_row` frame (e.g. "BUY", "SELL").
  /// Surfaces in master row lists without paying for a drill-down. Null
  /// in NDJSON mode (where it can be derived from outputs[0]).
  String? btraceAction;
  /// All per-file output-row indices for this source row. Length 1 for
  /// single-output templates; >1 for 1:N expansion (trading212 currency
  /// conversion expands one source row into BUY + SELL + FEE outputs).
  /// Drill-down iterates this list when reading from `output.csvx`.
  /// First element matches [outputIdx]; empty when no output was emitted
  /// (filtered / unmatched / skipped rows).
  List<int> outputIdxs = [];
  /// Per-output action labels parallel to [outputIdxs]. First element
  /// matches [btraceAction].
  List<String> btraceActions = [];

  /// False until [TraceStore.ensureDetailLoaded] has populated `vars`,
  /// `rules`, `fields`, and `outputs` for this row. NDJSON mode populates
  /// everything synchronously and never flips this — defaults true to
  /// preserve that behaviour for callers that don't know about lazy load.
  bool detailLoaded = true;

  /// True while an ensureDetailLoaded() coroutine for this row is in
  /// flight. Lets the UI render a spinner without thrashing notifyListeners
  /// for transient state changes.
  bool detailLoading = false;

  RowModel({required this.id, required this.fileId, required this.fileRow, required this.fields});
}

/// One entry from a `prepass_set` trace event, emitted by bxp-cli before
/// the main row loop when a `pre_pass` block is configured.
///
/// The pre-pass builds a lookup table keyed by a CSV field's value (`key`);
/// `field` is the column name that was indexed, `value` is the aggregate
/// or verbatim value stored under that key for LOOKUP() access.
class PrepassEntry {
  /// Pre-pass namespace name. Legacy single-block form gets the synthetic
  /// `_default`; named blocks carry the explicit name (e.g. `orders`). The
  /// GUI uses this to namespace lookups when re-evaluating expressions in
  /// drill-down and to derive the single-block name passed to bxp-fmt.
  final String name;
  /// The lookup key (value of the indexed CSV column for this entry).
  final String key;
  /// The CSV column (header name) whose values were indexed to build this entry.
  final String field;
  /// The stored aggregate or verbatim value, accessible via `LOOKUP(key)`.
  final String value;
  const PrepassEntry({this.name = '_default', required this.key, required this.field, required this.value});
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

/// All trace data for one input file processed during a dry-run or full run.
///
/// The [id] is `"$template::$path"` — unique within a single run because
/// the same physical file can appear under different templates if the user
/// runs all templates. [rows] is the row count as reported in `file_start`
/// (may differ from `rowIds.length` when rows are filtered before tracing).
class FileModel {
  /// Composite key: `"<templateId>::<filePath>"`.
  final String id;
  /// The conversion template that processed this file.
  final String template;
  /// Absolute path to the input CSV/XLSX file.
  final String path;
  /// Row count as reported by bxp-cli in the `file_start` event. Includes
  /// rows that will later be filtered; compare with `rowIds.length` to see
  /// how many survived.
  final int rows;
  /// Input CSV column headers in source order, from the `file_start` event.
  final List<String> headers;
  /// Output schema column headers, populated from the first `row_output`
  /// event (all output rows share the same schema for a given file).
  List<String> outputHeaders = [];
  /// Ordered list of [RowModel.id] values for rows that were traced for
  /// this file. Filtered rows are absent.
  final List<String> rowIds = [];
  /// Pre-pass lookup table entries collected from `prepass_set` events
  /// before the main row loop. Surfaced in the UI via FileList expandable
  /// detail / future LOOKUP debug pane; for now we capture them so the
  /// trace round-trip is lossless.
  final List<PrepassEntry> prepass = [];
  /// File-level stats from the `file_end` event (e.g. rows written, rows
  /// filtered, warnings). Null until the event arrives.
  Map<String, dynamic>? stats;

  // ── Btrace mode metadata ───────────────────────────────────────────────
  // Populated by `TraceStore._streamRunBtrace`; used by
  // `ensureDetailLoaded(rowId)` to map output-row idx → byte offset and
  // open file-handle fetchers. All-empty / null in NDJSON mode.

  /// Resolved path to the source CSV (the input file bxp-cli processed).
  /// Differs from [path] only when the runtime CWD turned a relative
  /// declared path into an absolute one.
  String sourceCsvPath = '';
  /// Resolved path to the output CSVX (sibling of the source CSV, with the
  /// template's `file_pattern_out` suffix applied — defaults to `.csvx`).
  String outputCsvxPath = '';
  /// Byte offset into `outputCsvxPath` for every emitted output row, in
  /// file order. Index N is the byte position of the start of the Nth
  /// data row (header offset is implicit and not stored). Populated once
  /// at trace-load time by a single sequential scan.
  List<int> outputOffsets = const [];
  /// Size of [sourceCsvPath] in bytes, captured once at `file_start` via
  /// `File.statSync().size`. Drives the eager-vs-lazy decision in
  /// `TraceStore._activateFile` — files below `kEagerFileLoadBytes` get
  /// slurped at activation, above stay on disk and populate per-row.
  int sourceCsvSizeBytes = 0;
  /// True when this file's source CSV fits under `kEagerFileLoadBytes`
  /// and should be slurped into a temporary `Uint8List` on activation;
  /// false for the lazy path. Set once at `file_start` based on
  /// [sourceCsvSizeBytes]; never mutated after.
  bool sourceLoadEager = false;
  /// Monotonic counter bumped each time `TraceStore._populateRangeSync`
  /// fills `row.fields` for a batch of rows in this file. RowList folds
  /// this value into its widget key so the second build after activation
  /// (post-populate) forces a PlutoGrid remount and the row cells get
  /// repainted with real values instead of the `…` placeholder shown
  /// while data was still being read from disk.
  int populateGen = 0;

  FileModel({required this.id, required this.template, required this.path, required this.rows, required this.headers});
}

/// Top-level container for all data produced by one bxp-cli `--trace` run.
///
/// Populated incrementally by `TraceBuilder.parseLine` as NDJSON events
/// arrive from the streaming process. Consumers (RowList, FileList,
/// OutputPanel) read from this model via `TraceStore.traceModel`; they must
/// not hold direct references across runs because `TraceStore._streamRun`
/// replaces the whole model at the start of each new run.
class TraceModel {
  /// Raw `start` event payload, null until the event arrives.
  Map<String, dynamic>? start;
  /// Raw `done` event payload collapsed to `{exitCode: N}`, null until
  /// the pipeline finishes.
  Map<String, dynamic>? done;
  /// FileModel registry keyed by `FileModel.id` (composite template::path).
  final Map<String, FileModel> files = {};
  /// Insertion-order list of file ids — used by FileList to maintain stable
  /// display order independent of hash iteration.
  final List<String> fileOrder = [];
  /// RowModel registry keyed by synthetic id (`r0`, `r1`, …).
  final Map<String, RowModel> rows = {};
  /// Parse errors from malformed NDJSON lines, capped at `_kMaxIssues` to
  /// prevent runaway producers from exhausting memory.
  final List<String> issues = [];

  /// True when this model was built by loading a `.bxtb` file (schema v3
  /// index-only emit). Per-row vars/rules/outputs are populated lazily via
  /// [TraceStore.ensureDetailLoaded] when the user selects a row. False
  /// when the model came from the NDJSON `bxp-cli --trace` stream
  /// (everything is in memory up front).
  bool fromBtrace = false;
}
