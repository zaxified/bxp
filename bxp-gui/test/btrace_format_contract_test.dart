// End-to-end format-contract test for the BXTB binary trace stream.
//
// BXTB is a hand-mirrored binary wire contract: bxp-cli writes it
// (bxp-core/src/btrace.zig), the GUI reads it (lib/services/btrace.dart,
// "Mirrors btrace.zig"). The pure-Dart unit tests in btrace_test.dart feed
// the reader HAND-BUILT bytes — they encode the Dart author's belief about
// the layout and therefore cannot catch a Zig-side change the Dart reader
// didn't follow. This test is the only sentinel for that cross-language
// drift: it runs the REAL bxp-cli, then parses its output through the
// production streaming reader (`BtraceReader.streaming` — the exact path
// `TraceStore._streamRunBtrace` feeds at runtime), asserting dataset-agnostic
// structural invariants rather than dataset-specific values.
//
// Feeding the bytes in tiny, deliberately frame-splitting chunks also
// exercises the streaming reassembly path (frames straddling a chunk
// boundary) that the old bulk `fromBytes` loader test never touched.

import 'dart:io';
import 'dart:typed_data';

import 'package:bxp_gui/services/btrace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late final String monoRoot;
  late final String bxpCli;
  late final Directory workDir;
  late final Uint8List traceBytes;

  setUpAll(() async {
    monoRoot = _findMonoRoot();
    final exe = Platform.isWindows ? '.exe' : '';
    bxpCli = p.join(monoRoot, 'bxp-cli', 'zig-out', 'bin', 'bxp-cli$exe');
    expect(File(bxpCli).existsSync(), isTrue,
        reason: 'bxp-cli binary missing — run `cd bxp-cli && zig build` first');

    // Copy a real dataset sample into a temp dir so bxp-cli can run there
    // without polluting the dataset folder with a generated csvx + bxtb.
    workDir = Directory.systemTemp.createTempSync('btrace_contract_test_');
    final sample = File(p.join(monoRoot, 'datasets', 'trading212_to_wealthfolio',
        'sample.csv'));
    final cfg = File(p.join(monoRoot, 'datasets', 'trading212_to_wealthfolio',
        'sample.json'));
    sample.copySync(p.join(workDir.path, 'sample.csv'));
    cfg.copySync(p.join(workDir.path, 'bxp-cli.json'));

    final tracePath = p.join(workDir.path, 'trace.bxtb');
    final result = await Process.run(
      bxpCli,
      ['--trace-file=$tracePath'],
      workingDirectory: workDir.path,
    );
    expect(result.exitCode, 0,
        reason:
            'bxp-cli failed: stderr=${result.stderr} stdout=${result.stdout}');
    traceBytes = File(tracePath).readAsBytesSync();
    expect(traceBytes, isNotEmpty, reason: '--trace-file produced no bytes');
  });

  tearDownAll(() {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  // Drive the PRODUCTION streaming reader with bytes fed in [chunkSize] slices
  // and collect every decoded frame. A small chunkSize forces most frames to
  // straddle a chunk boundary, exercising the reassembly path that bulk
  // `fromBytes` never hits.
  List<Frame> decodeStreaming(Uint8List bytes, int chunkSize) {
    final reader = BtraceReader.streaming();
    final frames = <Frame>[];
    for (var off = 0; off < bytes.length; off += chunkSize) {
      final end = off + chunkSize < bytes.length ? off + chunkSize : bytes.length;
      reader.appendBytes(bytes.sublist(off, end));
      for (Frame? f = reader.nextFrame(); f != null; f = reader.nextFrame()) {
        frames.add(f);
      }
    }
    return frames;
  }

  // Structural fingerprint of a frame — every decoded field, no positional
  // info. Two readers that agree on this for every frame decoded the same
  // bytes the same way.
  String fingerprint(Frame f) => switch (f) {
        FileStart() =>
          'FS|${f.inputFormat.name}|${f.template}|${f.path}|${f.headers.join(",")}',
        FileEnd() =>
          'FE|${f.sourceRows}|${f.writtenRows}|${f.errors}|${f.warnings}',
        OutputRow() =>
          'OR|${f.sourceLocator}|${f.outputIdx}|${f.ruleIdx}|${f.action}',
        FilteredRow() => 'FR|${f.sourceLocator}|${f.reason}',
        ErrorRow() =>
          'ER|${f.sourceLocator}|${f.varName}|${f.errorKind}|${f.detail}|${f.origin}',
        PrepassEntry() => 'PP|${f.name}|${f.key}|${f.field}|${f.value}',
        Done() => 'DN|${f.exitCode}',
      };

  test('real bxp-cli output decodes cleanly through the streaming reader', () {
    // 7-byte chunks straddle nearly every frame boundary. Reaching the end
    // without a FormatException means: magic accepted, every per-type reader
    // consumed exactly its declared pay_len (the `assert(_pos == payloadEnd)`
    // inside nextFrame fires here in debug/test mode if any parser drifts),
    // and the streaming reassembly never lost alignment.
    final frames = decodeStreaming(traceBytes, 7);
    expect(frames, isNotEmpty);
  });

  test('decode is chunk-size invariant (streaming reassembly is lossless)', () {
    // One big chunk == bulk fromBytes; 1-byte drip is the pathological
    // every-field-split case; 7-byte is a realistic mid-frame split. All
    // three must yield byte-for-byte identical frame streams — proves the
    // reassembly neither drops, duplicates, nor corrupts frames at any
    // boundary.
    final whole = decodeStreaming(traceBytes, traceBytes.length).map(fingerprint).toList();
    final drip = decodeStreaming(traceBytes, 1).map(fingerprint).toList();
    final seven = decodeStreaming(traceBytes, 7).map(fingerprint).toList();
    expect(drip, equals(whole));
    expect(seven, equals(whole));
  });

  test('frame stream satisfies the invariants GUI drill-down relies on', () {
    final frames = decodeStreaming(traceBytes, traceBytes.length);

    // Single-file shape bxp-cli emits today: exactly one file_start /
    // file_end / done. The GUI's per-file model build keys off these
    // boundaries.
    expect(frames.whereType<FileStart>(), hasLength(1));
    expect(frames.whereType<FileEnd>(), hasLength(1));
    expect(frames.whereType<Done>(), hasLength(1));

    final fileStart = frames.whereType<FileStart>().single;
    final fileEnd = frames.whereType<FileEnd>().single;
    final done = frames.whereType<Done>().single;

    // file_start carries the source path + a non-empty header row — drill-down
    // resolves source fields against these.
    expect(fileStart.path, isNotEmpty);
    expect(fileStart.headers, isNotEmpty);

    // The core drill-down contract: every emitted output_row is accounted for
    // in file_end.writtenRows (lets row index → mmap offset stay 1:1).
    final outputRows = frames.whereType<OutputRow>().toList();
    expect(outputRows, isNotEmpty);
    expect(outputRows.length, equals(fileEnd.writtenRows),
        reason: 'output_row frame count must match file_end.writtenRows');

    // source_locator is a byte offset into the source CSV, emitted in
    // source-file order → strictly past the header line and monotonically
    // non-decreasing. CsvRowFetcher.lineAt seeks to these offsets.
    int prev = -1;
    for (final r in outputRows) {
      expect(r.sourceLocator, greaterThan(0),
          reason: 'source_locator should skip the CSV header line');
      expect(r.sourceLocator, greaterThanOrEqualTo(prev),
          reason: 'source_locators should be monotonically non-decreasing');
      prev = r.sourceLocator;
    }

    // Clean run over a known-good sample → exit 0, no errors/warnings.
    expect(fileEnd.errors, equals(0));
    expect(fileEnd.warnings, equals(0));
    expect(done.exitCode, equals(0));
  });

  test('streaming reader rejects a stream with bad magic', () {
    final reader = BtraceReader.streaming();
    reader.appendBytes(Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]));
    expect(reader.nextFrame, throwsFormatException);
  });
}

String _findMonoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    final core = Directory(p.join(dir.path, 'bxp-core'));
    final cli = Directory(p.join(dir.path, 'bxp-cli'));
    if (core.existsSync() && cli.existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
      'could not locate monorepo root from ${Directory.current.path}');
}
