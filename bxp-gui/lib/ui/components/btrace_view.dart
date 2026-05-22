/// Btrace browser — load a `.bxtb` file from disk, browse output rows, and
/// drill down into per-row source / output / expression-eval data on demand.
///
/// This is the live integration of the schema-v3 architecture: btrace stays
/// lean in RAM (one [BtraceLoader] model, no per-row detail), the source CSV
/// and output CSVX are read lazily via [CsvRowFetcher] on click, and
/// expression results are reconstructed via [BxpProcessClient.evalBatch].
/// The whole pipeline must complete within ~500 ms per click for an
/// acceptable drill-down UX.
///
/// View is intentionally separate from the streaming `RUNNER` flow — no
/// TraceStore refactor required. Sits as a third top-bar tab next to
/// CONFIG and RUNNER.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../services/btrace.dart' as btrace_mod;
import '../../services/btrace_loader.dart';
import '../../services/bxp_process_client.dart';
import '../../services/csv_row_fetcher.dart';
import '../../services/dev_trace.dart';
import '../theme/bxp_theme.dart';

class BtraceView extends StatefulWidget {
  const BtraceView({super.key});

  @override
  State<BtraceView> createState() => _BtraceViewState();
}

class _BtraceViewState extends State<BtraceView> {
  // ── Loaded artefacts ───────────────────────────────────────────────────
  BtraceModel? _model;
  CsvRowFetcher? _sourceFetcher;
  CsvRowFetcher? _outputFetcher;
  // Byte-offset index for output.csvx: outputOffsets[N] = byte offset of the
  // start of row N (data row, header at index -1). Pre-computed at load
  // time so on-click lookup is O(1) regardless of file size.
  List<int>? _outputOffsets;
  List<String>? _outputHeaders;
  // Template config for drill-down: maps $var name → expression text. Pulled
  // from `bxp-fmt --fetch-template` after the user supplies a config path
  // (defaults to `bxp-cli.json` sibling of the btrace).
  Map<String, String>? _inputSchema;
  Map<String, String>? _tickerMap;

  // ── UI state ───────────────────────────────────────────────────────────
  final TextEditingController _pathController = TextEditingController();
  String? _loadError;
  bool _loading = false;
  int _selectedIdx = -1;
  _DrillDown? _drillDown;
  Duration? _lastDrillLatency;

  @override
  void dispose() {
    _sourceFetcher?.dispose();
    _outputFetcher?.dispose();
    _pathController.dispose();
    super.dispose();
  }

  // ── Loading ────────────────────────────────────────────────────────────

  Future<void> _load() async {
    final raw = _pathController.text.trim();
    if (raw.isEmpty) {
      setState(() => _loadError = 'enter a .bxtb path');
      return;
    }
    setState(() {
      _loadError = null;
      _loading = true;
      _drillDown = null;
      _selectedIdx = -1;
    });
    try {
      // Dispose any previously-loaded fetchers so we don't leak file handles
      // when the user re-runs Load with a new path.
      await _sourceFetcher?.dispose();
      await _outputFetcher?.dispose();
      _sourceFetcher = null;
      _outputFetcher = null;

      final model = await BtraceLoader.loadFile(raw);
      if (model == null) {
        setState(() {
          _loadError = 'file not found: $raw';
          _loading = false;
        });
        return;
      }
      if (model.fileStart == null) {
        setState(() {
          _loadError = 'btrace missing file_start frame';
          _loading = false;
        });
        return;
      }

      // Resolve sibling source.csv / output.csvx. file_start.path is the
      // input path bxp-cli used (relative to its CWD); the runner usually
      // sets CWD = directory containing the config. We trust the path-as-
      // emitted and try it both as absolute and as relative-to-btrace-dir.
      final btraceDir = p.dirname(raw);
      final declaredPath = model.fileStart!.path;
      String? sourcePath = _firstExisting([
        declaredPath,
        p.join(btraceDir, declaredPath),
        p.join(btraceDir, p.basename(declaredPath)),
      ]);
      if (sourcePath == null) {
        setState(() {
          _loadError = 'source CSV not found (looked for: $declaredPath)';
          _loading = false;
        });
        return;
      }
      // Derive output path: strip the input extension and add .csvx —
      // matches the bxp-cli convention (also configurable via
      // file_pattern_out, but the default suffix-swap covers all shipping
      // templates).
      final outputPath = _deriveOutputPath(sourcePath);

      final sourceF = await CsvRowFetcher.open(sourcePath);
      final outputF = await CsvRowFetcher.open(outputPath);
      if (sourceF == null) {
        setState(() {
          _loadError = 'cannot open source CSV: $sourcePath';
          _loading = false;
        });
        return;
      }
      if (outputF == null) {
        setState(() {
          _loadError = 'cannot open output CSVX: $outputPath';
          _loading = false;
        });
        await sourceF.dispose();
        return;
      }

      // Pre-index output.csvx: build outputOffsets so on-click lookup of
      // output_idx → byte offset is O(1). Reads the file once sequentially.
      final outputOffsets = await _indexOutputOffsets(outputPath);
      final outputHeaderLine = await outputF.headerLine();
      final outputHeaders = outputHeaderLine?.split(',') ?? const <String>[];

      // Try to load the template config: bxp-cli.json sibling of the btrace.
      // Pulls input_schema + ticker_map for drill-down evalBatch calls.
      // Failure to find the config is non-fatal — drill-down works for
      // source/output values without it, just no $var eval column.
      final configPath = p.join(btraceDir, 'bxp-cli.json');
      Map<String, String>? inputSchema;
      Map<String, String>? tickerMap;
      if (File(configPath).existsSync()) {
        final fetched = await _fetchTemplate(
            configPath, model.fileStart!.template);
        inputSchema = fetched.$1;
        tickerMap = fetched.$2;
      }

      setState(() {
        _model = model;
        _sourceFetcher = sourceF;
        _outputFetcher = outputF;
        _outputOffsets = outputOffsets;
        _outputHeaders = outputHeaders;
        _inputSchema = inputSchema;
        _tickerMap = tickerMap;
        _loading = false;
      });
    } catch (e, st) {
      devTrace('btrace.load.error', {'error': e.toString(), 'stack': '$st'});
      setState(() {
        _loadError = 'load failed: $e';
        _loading = false;
      });
    }
  }

  String? _firstExisting(List<String> candidates) {
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  String _deriveOutputPath(String sourcePath) {
    if (sourcePath.endsWith('.csv')) {
      return '${sourcePath.substring(0, sourcePath.length - 4)}.csvx';
    }
    return '$sourcePath.csvx';
  }

  /// Walk output.csvx once, recording byte offsets of every line including
  /// the header. Returns the data-row offsets (header offset is index -1
  /// implicit, dropped from the returned list).
  Future<List<int>> _indexOutputOffsets(String path) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    final offsets = <int>[];
    int pos = 0;
    // Skip header line first.
    final headerLf = bytes.indexOf(0x0A);
    if (headerLf < 0) return offsets;
    pos = headerLf + 1;
    while (pos < bytes.length) {
      offsets.add(pos);
      final nextLf = bytes.indexOf(0x0A, pos);
      if (nextLf < 0) break;
      pos = nextLf + 1;
    }
    return offsets;
  }

  /// Fetch template config via `bxp-fmt --config <path> --fetch-template <id>`.
  /// Returns (input_schema as {var → expr}, ticker_map as {key → value}).
  Future<(Map<String, String>?, Map<String, String>?)> _fetchTemplate(
      String configPath, String templateId) async {
    try {
      final tpl = await BxpProcessClient.fetchTemplate(configPath, templateId);
      if (tpl == null) return (null, null);
      Map<String, String>? schema;
      if (tpl['input_schema'] is Map) {
        schema = <String, String>{};
        (tpl['input_schema'] as Map).forEach((k, v) {
          schema![k.toString()] = v?.toString() ?? '';
        });
      }
      Map<String, String>? tm;
      final rawTm = tpl['ticker_map'];
      if (rawTm is Map) {
        tm = <String, String>{};
        rawTm.forEach((k, v) {
          tm![k.toString()] = v?.toString() ?? '';
        });
      }
      return (schema, tm);
    } catch (e) {
      devTrace('btrace.fetchTemplate.error', {'error': e.toString()});
      return (null, null);
    }
  }

  // ── Drill-down ─────────────────────────────────────────────────────────

  Future<void> _selectRow(int idx) async {
    setState(() {
      _selectedIdx = idx;
      _drillDown = null;
    });
    final stopwatch = Stopwatch()..start();

    final model = _model;
    final outputOffsets = _outputOffsets;
    final outputHeaders = _outputHeaders;
    if (model == null || outputOffsets == null || outputHeaders == null) return;
    if (idx < 0 || idx >= model.outputRows.length) return;

    final row = model.outputRows[idx];

    // Source fields: read source.csv @ sourceLocator, split on header columns.
    final sourceHeaders = model.fileStart!.headers;
    String? sourceLine;
    List<String> sourceFields = const [];
    if (_sourceFetcher != null) {
      sourceLine = await _sourceFetcher!.lineAt(row.sourceLocator);
      if (sourceLine != null) {
        sourceFields = _splitCsvLine(sourceLine, sourceHeaders.length);
      }
    }

    // Output fields: read output.csvx @ outputOffsets[outputIdx].
    String? outputLine;
    List<String> outputFields = const [];
    if (_outputFetcher != null &&
        row.outputIdx >= 0 &&
        row.outputIdx < outputOffsets.length) {
      outputLine = await _outputFetcher!.lineAt(outputOffsets[row.outputIdx]);
      if (outputLine != null) {
        outputFields = _splitCsvLine(outputLine, outputHeaders.length);
      }
    }

    // Eval input_schema expressions in one batch. Skip if template config
    // failed to load (rare; falls back to source/output display only).
    List<MapEntry<String, ExprBatchResult>> varEvals = const [];
    if (_inputSchema != null &&
        _inputSchema!.isNotEmpty &&
        sourceFields.isNotEmpty) {
      final names = _inputSchema!.keys.toList();
      final exprs = _inputSchema!.values.toList();
      final results = await BxpProcessClient.evalBatch(
        headers: sourceHeaders,
        fields: sourceFields,
        exprs: exprs,
        tickerMap: _tickerMap,
      );
      // Align result count to expr count: spawn failure returns empty,
      // which we render as one "spawn failed" row per expr.
      if (results.length == exprs.length) {
        varEvals = [
          for (int i = 0; i < names.length; i++)
            MapEntry(names[i], results[i]),
        ];
      } else {
        varEvals = [
          for (final n in names)
            MapEntry(n, const ExprBatchResult(ok: false, error: 'spawn failed')),
        ];
      }
    }

    stopwatch.stop();
    setState(() {
      _drillDown = _DrillDown(
        outputRow: row,
        sourceHeaders: sourceHeaders,
        sourceFields: sourceFields,
        outputHeaders: outputHeaders,
        outputFields: outputFields,
        varEvals: varEvals,
      );
      _lastDrillLatency = stopwatch.elapsed;
    });
  }

  /// Minimal CSV splitter: handles double-quoted fields with embedded commas.
  /// Schema v3 drill-down uses this to slice a single line; it does not
  /// attempt to match the full bxp-core RFC 4180 parser.
  List<String> _splitCsvLine(String line, int columnHint) {
    final fields = <String>[];
    final buf = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (inQuotes) {
        if (ch == '"') {
          // Escaped `""` inside a quoted field collapses to a single `"`.
          if (i + 1 < line.length && line[i + 1] == '"') {
            buf.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          buf.write(ch);
        }
      } else {
        if (ch == ',') {
          fields.add(buf.toString());
          buf.clear();
        } else if (ch == '"' && buf.isEmpty) {
          inQuotes = true;
        } else {
          buf.write(ch);
        }
      }
    }
    fields.add(buf.toString());
    // Pad to columnHint so the drill-down panel can iterate by index without
    // bounds checks when the row has trailing-comma elision.
    while (fields.length < columnHint) {
      fields.add('');
    }
    return fields;
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Container(
      color: t.surfaceBg,
      child: Column(
        children: [
          _buildLoadBar(t),
          if (_model == null)
            Expanded(child: _buildLoadPrompt(t))
          else
            Expanded(child: _buildBrowser(t)),
        ],
      ),
    );
  }

  Widget _buildLoadBar(BxpTheme t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.borderColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _pathController,
              style: TextStyle(color: t.textPrimary, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'path to .bxtb file',
                hintStyle: TextStyle(color: t.textPrimary.withValues(alpha: 0.4)),
                isDense: true,
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: t.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: t.borderColor),
                ),
              ),
              onSubmitted: (_) => _load(),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _loading ? null : _load,
            child: Text(_loading ? 'Loading…' : 'Load'),
          ),
          if (_model != null) ...[
            const SizedBox(width: 12),
            Text(
              '${_model!.outputRowCount} rows · '
              '~${(_model!.estimatedBytes() / 1024).toStringAsFixed(1)} KB',
              style: TextStyle(color: t.textPrimary.withValues(alpha: 0.7)),
            ),
          ],
          if (_lastDrillLatency != null) ...[
            const SizedBox(width: 12),
            Text(
              'drill-down ${_lastDrillLatency!.inMilliseconds} ms',
              style: TextStyle(
                color: _lastDrillLatency!.inMilliseconds < 500
                    ? Colors.green
                    : Colors.orange,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLoadPrompt(BxpTheme t) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Load a .bxtb file to browse',
            style: TextStyle(color: t.textPrimary.withValues(alpha: 0.6)),
          ),
          if (_loadError != null) ...[
            const SizedBox(height: 12),
            Text(_loadError!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }

  Widget _buildBrowser(BxpTheme t) {
    final rows = _model!.outputRows;
    return Row(
      children: [
        // Left: row list
        SizedBox(
          width: 320,
          child: Container(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: t.borderColor)),
            ),
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (ctx, i) {
                final r = rows[i];
                final selected = i == _selectedIdx;
                return InkWell(
                  onTap: () => _selectRow(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    color: selected ? t.borderColor : null,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text('${r.outputIdx}',
                              style: TextStyle(
                                  color: t.textPrimary.withValues(alpha: 0.5),
                                  fontFamily: 'monospace')),
                        ),
                        Expanded(
                          child: Text(r.action,
                              style: TextStyle(
                                color: t.textPrimary,
                                fontFamily: 'monospace',
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              )),
                        ),
                        SizedBox(
                          width: 80,
                          child: Text('@${r.sourceLocator}',
                              style: TextStyle(
                                  color: t.textPrimary.withValues(alpha: 0.4),
                                  fontFamily: 'monospace',
                                  fontSize: 11)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        // Right: drill-down
        Expanded(child: _buildDrillDown(t)),
      ],
    );
  }

  Widget _buildDrillDown(BxpTheme t) {
    final dd = _drillDown;
    if (dd == null) {
      return Center(
        child: Text(
          _selectedIdx < 0
              ? 'Select a row on the left'
              : 'Loading…',
          style: TextStyle(color: t.textPrimary.withValues(alpha: 0.5)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionHeader(t, 'Source row (@${dd.outputRow.sourceLocator})'),
        _kvTable(t, dd.sourceHeaders, dd.sourceFields),
        const SizedBox(height: 24),
        if (dd.varEvals.isNotEmpty) ...[
          _sectionHeader(t,
              'Variable evaluations (input_schema, re-evaluated via bxp-fmt)'),
          _varTable(t, dd.varEvals),
          const SizedBox(height: 24),
        ],
        _sectionHeader(t,
            'Output row #${dd.outputRow.outputIdx} (action: ${dd.outputRow.action})'),
        _kvTable(t, dd.outputHeaders, dd.outputFields),
      ],
    );
  }

  Widget _sectionHeader(BxpTheme t, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: TextStyle(
          color: t.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _kvTable(BxpTheme t, List<String> keys, List<String> values) {
    return Column(
      children: [
        for (int i = 0; i < keys.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.borderColor.withValues(alpha: 0.3))),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 200,
                  child: Text(
                    keys[i],
                    style: TextStyle(
                      color: t.textPrimary.withValues(alpha: 0.7),
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    i < values.length ? values[i] : '',
                    style: TextStyle(color: t.textPrimary, fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _varTable(
      BxpTheme t, List<MapEntry<String, ExprBatchResult>> entries) {
    return Column(
      children: [
        for (final e in entries)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.borderColor.withValues(alpha: 0.3))),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 200,
                  child: Text(
                    e.key,
                    style: TextStyle(
                      color: t.textPrimary.withValues(alpha: 0.7),
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    e.value.ok
                        ? (e.value.value ?? '')
                        : '⚠ ${e.value.error ?? ''}: ${e.value.detail ?? ''}',
                    style: TextStyle(
                      color: e.value.ok ? t.textPrimary : Colors.orange,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DrillDown {
  final btrace_mod.OutputRow outputRow;
  final List<String> sourceHeaders;
  final List<String> sourceFields;
  final List<String> outputHeaders;
  final List<String> outputFields;
  final List<MapEntry<String, ExprBatchResult>> varEvals;
  _DrillDown({
    required this.outputRow,
    required this.sourceHeaders,
    required this.sourceFields,
    required this.outputHeaders,
    required this.outputFields,
    required this.varEvals,
  });
}
