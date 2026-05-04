import 'dart:convert';
import 'trace_model.dart';

class TraceBuilder {
  final TraceModel model;
  String? currentFileId;
  String? currentRowId;
  int rowCounter = 0;

  TraceBuilder() : model = TraceModel();

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
        // Mirrors bxp-ui's TraceBuilder.applyPrepassSet — same event
        // shape (`{key, field, value}`) emitted by bxp-cli's pre_pass
        // pipeline before any row_start fires.
        final fileId = currentFileId;
        if (fileId == null) return;
        model.files[fileId]?.prepass.add(PrepassEntry(
          key: ev['key']?.toString() ?? '',
          field: ev['field']?.toString() ?? '',
          value: ev['value']?.toString() ?? '',
        ));
        break;
      case 'row_start':
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
        final rawVals = ev['values'];
        if (rawVals is List) {
          _row()?.outputs.add(List<String>.from(rawVals));
        }
        break;
      case 'row_end':
        currentRowId = null;
        break;
      case 'file_end':
        final template = ev['template'] as String? ?? '';
        final path = ev['path'] as String? ?? '';
        final id = '$template::$path';
        final rawStats = ev['stats'];
        if (rawStats is Map) {
          model.files[id]?.stats = Map<String, dynamic>.from(rawStats);
        }
        currentFileId = null;
        break;
      case 'done':
        model.done = {'exitCode': ev['exit_code']};
        break;
    }
  }

  RowModel? _row() {
    return currentRowId != null ? model.rows[currentRowId] : null;
  }

  void _applyRuleMatch(Map<String, dynamic> ev, bool matched) {
    final row = _row();
    if (row == null) return;

    final rawRows = ev['rows'];
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

    if (matched && row.matchedRuleIndex == null) {
      row.matchedRuleIndex = ev['rule_index'] as int?;
    }
  }
}
