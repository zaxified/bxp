/// Build a sparse in-memory model from a `.bxtb` binary trace.
///
/// Schema v3 (2026-05-22) btrace is index-only: per-source-row data lives in
/// the original source CSV / output CSVX files and is fetched on demand via
/// [CsvRowFetcher]; per-expression drill-down values are reconstructed via
/// [BxpProcessClient.evalBatch]. This loader is the entry point for that
/// architecture — it walks the btrace stream once and groups frames by kind
/// into a [BtraceModel] the GUI can hold in RAM cheaply.
///
/// Loader is intentionally lean: no decoding of pool indices, no
/// cross-referencing between output_rows and prepass entries. Higher-level
/// services (drill-down panel, file list) compose on top.
library;

import 'dart:io';
import 'dart:typed_data';

import 'btrace.dart';

/// Aggregated view of one `.bxtb` file. All frame types are grouped into
/// dedicated lists; consumers iterate by kind rather than by file position.
///
/// `outputRows` is the master list — every output CSVX row corresponds to
/// exactly one entry, indexed by the row's `outputIdx`. [fileStart] /
/// [fileEnd] / [done] are at most one each per file; in multi-file traces
/// (not yet emitted by bxp-cli but the on-disk format allows it) the model
/// is built per file_start boundary by the caller.
class BtraceModel {
  /// File-level header (template, path, input format, pools, headers).
  /// Null when the trace stream ended before reading file_start — treat
  /// as a parse-time anomaly worth surfacing to the user.
  FileStart? fileStart;

  /// File-level summary (row counts, errors, warnings). Null while the
  /// stream is still being read (or if the producer crashed mid-file).
  FileEnd? fileEnd;

  /// Process-level exit code. Null while still streaming or on producer
  /// crash; non-zero is the GUI's signal to surface an error indicator.
  Done? done;

  /// One entry per emitted output CSVX row, in file order. Length matches
  /// `fileEnd.writtenRows` when the file completes successfully.
  final List<OutputRow> outputRows = [];

  /// One entry per source row dropped by the row_rules first-match.
  /// (Today only emitted when `row_rules_debug_missing` is true in the
  /// template config — see bxp-cli pipeline.zig.)
  final List<FilteredRow> filteredRows = [];

  /// One entry per per-row evaluation error. Empty in a clean run.
  final List<ErrorRow> errorRows = [];

  /// Pre_pass lookup-table entries collected during the producer's first
  /// scan. Cross-row state (e.g. order-id → fee mapping) the GUI needs
  /// when calling `bxp-fmt --expr-batch` with `lookups`.
  final List<PrepassEntry> prepassEntries = [];

  BtraceModel();

  /// Quick stats for the GUI's status bar / "trace loaded" toast.
  int get outputRowCount => outputRows.length;
  int get filteredRowCount => filteredRows.length;
  int get errorCount => errorRows.length;

  /// Memory-footprint estimate in bytes. Useful for the user's "10 MB cap"
  /// budget heuristic — the GUI can surface a warning if a loaded trace
  /// gets too large to hold lean. Doesn't account for Dart object header
  /// overhead per entry; treat as a lower bound (real cost is ~2-3× this
  /// on a 64-bit VM with growable lists).
  int estimatedBytes() {
    // OutputRow: 8 (loc) + 8 (idx) + 4 (rule) + action.length + ~32 (object)
    final outBytes = outputRows.fold<int>(
        0, (acc, r) => acc + 20 + r.action.length + 32);
    final filtBytes = filteredRows.fold<int>(
        0, (acc, r) => acc + 8 + r.reason.length + 32);
    final errBytes = errorRows.fold<int>(
        0,
        (acc, r) =>
            acc +
            8 +
            r.varName.length +
            r.errorKind.length +
            r.detail.length +
            r.origin.length +
            32);
    final ppBytes = prepassEntries.fold<int>(
        0,
        (acc, e) =>
            acc + e.name.length + e.key.length + e.field.length + e.value.length + 32);
    return outBytes + filtBytes + errBytes + ppBytes;
  }
}

class BtraceLoader {
  /// Parse a `.bxtb` byte buffer into a [BtraceModel]. Throws
  /// `FormatException` on malformed magic / version / truncated frame.
  ///
  /// Multi-file trace streams (not yet emitted by bxp-cli; the on-disk
  /// format allows multiple file_start blocks) are collapsed into the
  /// LAST file_start seen. Callers that need per-file granularity should
  /// switch to [streamModels] when the producer starts using it.
  static BtraceModel fromBytes(Uint8List bytes) {
    final reader = BtraceReader.fromBytes(bytes);
    final model = BtraceModel();
    while (reader.hasMore) {
      final frame = reader.nextFrame();
      if (frame == null) break;
      _dispatch(model, frame);
    }
    return model;
  }

  /// Read [path] from disk and parse. Returns null if the file does not
  /// exist; rethrows on malformed content (so callers see the format
  /// error rather than a silent empty model).
  static Future<BtraceModel?> loadFile(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    return fromBytes(bytes);
  }

  static void _dispatch(BtraceModel m, Frame frame) {
    if (frame is FileStart) {
      m.fileStart = frame;
    } else if (frame is FileEnd) {
      m.fileEnd = frame;
    } else if (frame is OutputRow) {
      m.outputRows.add(frame);
    } else if (frame is FilteredRow) {
      m.filteredRows.add(frame);
    } else if (frame is ErrorRow) {
      m.errorRows.add(frame);
    } else if (frame is PrepassEntry) {
      m.prepassEntries.add(frame);
    } else if (frame is Done) {
      m.done = frame;
    }
    // Unknown frame types are skipped by BtraceReader (forward compat); no
    // catch-all needed here.
  }
}
