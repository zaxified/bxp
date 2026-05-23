import 'dart:convert';
import 'trace_model.dart';

/// Parses the NDJSON stream emitted by `bxp-cli --trace` and populates a
/// [TraceModel] in real time.
///
/// Events arrive one JSON object per line. The builder keeps a small amount
/// of transient context (`currentFileId`, `currentRowId`) to associate
/// subsequent per-row events with their parent file and row without repeating
/// those ids on every event (following the bxp-cli trace protocol spec).
class TraceBuilder {
  final TraceModel model;

  /// The `FileModel.id` of the file currently being processed, set by
  /// `file_start` and cleared by `file_end`. Null between files or before
  /// the first `file_start`.
  String? currentFileId;

  /// The `RowModel.id` of the row currently being traced, set by `row_start`
  /// and cleared by `row_end`. Null between rows.
  String? currentRowId;

  /// Monotonically increasing counter for assigning synthetic row IDs
  /// (`r0`, `r1`, …). Never resets within a builder's lifetime so IDs are
  /// stable across file boundaries.
  int rowCounter = 0;

  TraceBuilder() : model = TraceModel();

  /// Parse a multi-line NDJSON blob (e.g. from a completed process run where
  /// the full stdout was captured at once). Forwards each line to [parseLine].
  void parseAndApply(String ndjson) {
    for (final line in ndjson.split('\n')) {
      parseLine(line);
    }
  }

  /// Parse a single NDJSON line and dispatch it through [apply].
  /// Used by the streaming client — every line delivered by
  /// `bxp-cli --trace` flows through this method.
  void parseLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final ev = jsonDecode(line) as Map<String, dynamic>;
      apply(ev);
    } catch (e) {
      // Cap retained parse-error strings — a runaway producer (e.g.
      // bxp-cli emitting non-NDJSON) must not let us OOM the store.
      // We keep the first batch (most diagnostically useful) and drop
      // the rest silently after the cap.
      if (model.issues.length < _kMaxIssues) {
        model.issues.add('Parse error: $e on line: $line');
      }
    }
  }

  static const int _kMaxIssues = 100;

  /// Dispatch a single parsed trace event to the appropriate handler.
  ///
  /// Unknown event types are silently ignored — forward-compat with future
  /// bxp-cli trace protocol additions that the GUI doesn't need to render.
  void apply(Map<String, dynamic> ev) {
    final t = ev['t'] as String?;
    if (t == null) return;

    switch (t) {
      case 'start':
        model.start = ev;
        break;
      case 'file_start':
        final template = ev['template'] as String;
        final path = ev['path'] as String;
        // Composite id keeps files from different templates apart when the
        // user runs all templates against overlapping file sets.
        final id = '$template::$path';
        final rawHeaders = ev['headers'];
        final headers = rawHeaders is List
            ? List<String>.from(rawHeaders)
            : <String>[];
        final rawOutHeaders = ev['output_headers'];
        final outHeaders = rawOutHeaders is List
            ? List<String>.from(rawOutHeaders)
            : <String>[];
        final file = FileModel(
          id: id,
          template: template,
          path: path,
          rows: ev['rows'] as int? ?? 0,
          headers: headers,
        );
        file.outputHeaders = outHeaders;
        model.files[id] = file;
        model.fileOrder.add(id);
        currentFileId = id;
        break;
      case 'prepass_set':
        // Captured on the current FileModel for inspection / debugging.
        // Event shape (`{key, field, value}`) is the bxp-cli contract for
        // pre_pass entries emitted before any row_start fires.
        final fileId = currentFileId;
        if (fileId == null) return;
        model.files[fileId]?.prepass.add(PrepassEntry(
          name: ev['name']?.toString() ?? '_default',
          key: ev['key']?.toString() ?? '',
          field: ev['field']?.toString() ?? '',
          value: ev['value']?.toString() ?? '',
        ));
        break;
      case 'row_start':
        // Guard against a malformed trace where row_start fires outside a
        // file context. Harmless to drop — the row would have no file parent.
        if (currentFileId == null) return;
        final id = 'r${rowCounter++}';
        final rawFields = ev['fields'];
        final fields = rawFields is List ? List<String>.from(rawFields) : <String>[];
        final row = RowModel(
          id: id,
          fileId: currentFileId!,
          fileRow: ev['file_row'] as int? ?? rowCounter,
          fields: fields,
        );
        model.rows[id] = row;
        model.files[currentFileId!]?.rowIds.add(id);
        currentRowId = id;
        break;
      case 'var_eval':
        final row = _row();
        if (row == null) return;
        row.vars.add(VarEntry(
          kind: 'eval',
          name: ev['name'] as String? ?? '',
          expr: ev['expr'] as String?,
          value: ev['value'] as String?,
          origin: ev['origin'] as String? ?? 'input_schema',
          ruleIndex: ev['rule_index'] as int?,
          outputRowIndex: ev['output_row_index'] as int?,
        ));
        break;
      case 'var_error':
        final row = _row();
        if (row == null) return;
        row.vars.add(VarEntry(
          kind: 'error',
          name: ev['name'] as String? ?? '',
          expr: ev['expr'] as String?,
          error: ev['error'] as String?,
          detail: ev['detail'] as String?,
          origin: ev['origin'] as String? ?? 'input_schema',
          ruleIndex: ev['rule_index'] as int?,
          outputRowIndex: ev['output_row_index'] as int?,
        ));
        row.hasError = true;
        break;
      case 'rule_match':
        _applyRuleMatch(ev, true);
        break;
      case 'rule_no_match':
        _applyRuleMatch(ev, false);
        break;
      case 'row_filtered':
        _row()?.filteredReason = ev['reason'] as String?;
        break;
      case 'row_output':
        // One row_output event = one output CSV row. A single input row can
        // produce multiple output rows when the matched rule's `rows` block
        // has multiple entries (e.g. a fee split into a BUY + FEE pair).
        final rawVals = ev['values'];
        if (rawVals is List) {
          _row()?.outputs.add(List<String>.from(rawVals));
        }
        break;
      case 'row_end':
        // Clear the row context so subsequent events outside a row context
        // are dropped by `_row()` returning null.
        currentRowId = null;
        break;
      case 'file_end':
        final template = ev['template'] as String? ?? '';
        final path = ev['path'] as String? ?? '';
        final id = '$template::$path';
        // Stats arrive at file_end, not file_start — they summarise the
        // completed file (rows written, filtered, warnings). The GUI uses
        // non-null stats as the signal for "auto-select this file" during
        // streaming (see TraceStore._streamRun).
        final rawStats = ev['stats'];
        if (rawStats is Map) {
          model.files[id]?.stats = Map<String, dynamic>.from(rawStats);
        }
        currentFileId = null;
        break;
      case 'done':
        // Collapse the done payload to just exit_code — the GUI only needs
        // the code for status colouring; the full event is not displayed.
        model.done = {'exitCode': ev['exit_code']};
        break;
    }
  }

  /// Return the current row, or null when called outside a row context
  /// (e.g. between `row_end` and the next `row_start`).
  RowModel? _row() {
    return currentRowId != null ? model.rows[currentRowId] : null;
  }

  /// Shared handler for `rule_match` and `rule_no_match` events.
  ///
  /// Both events have identical shape; [matched] is the only difference.
  /// We record unmatched rules too so the GUI can render the full decision
  /// tree and explain WHY a row wasn't captured by earlier rules.
  ///
  /// The first matched rule wins: [RowModel.matchedRuleIndex] is set only
  /// once (on the first match) so subsequent fallthrough rules that also
  /// happen to evaluate true don't overwrite the primary match.
  void _applyRuleMatch(Map<String, dynamic> ev, bool matched) {
    final row = _row();
    if (row == null) return;

    final rawRows = ev['rows'];
    // Coerce all values to String — the trace JSON may carry numbers or
    // booleans in expression-result fields, but the GUI always renders them
    // as strings in the Rule-Results table.
    final rowsList = rawRows is List
        ? rawRows.map((e) {
            final map = e as Map<String, dynamic>;
            return map.map((k, v) => MapEntry(k, v?.toString() ?? ''));
          }).toList()
        : <Map<String, String>>[];

    row.rules.add(RuleEntry(
      ruleIndex: ev['rule_index'] as int? ?? 0,
      when: ev['when'] as String? ?? '',
      matched: matched,
      rows: rowsList,
    ));

    // Record the first matched rule index for the jump-to-config shortcut.
    // Subsequent matches are visible in the rules list but don't override.
    if (matched && row.matchedRuleIndex == null) {
      row.matchedRuleIndex = ev['rule_index'] as int?;
    }
  }
}
