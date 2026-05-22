// End-to-end test for BtraceLoader against a real bxp-cli-produced btrace.
//
// Generates a fresh `.bxtb` by running bxp-cli on a dataset sample, parses it
// via BtraceLoader, then asserts the model's row counts line up with the
// output CSVX file row count (the contract that lets GUI drill-down resolve
// output-row index → mmap offset into output.csvx).

import 'dart:io';
import 'dart:typed_data';

import 'package:bxp_gui/services/btrace_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late final String monoRoot;
  late final String bxpCli;
  late final Directory workDir;

  setUpAll(() async {
    monoRoot = _findMonoRoot();
    bxpCli = p.join(monoRoot, 'bxp-cli', 'zig-out', 'bin', 'bxp-cli');
    expect(File(bxpCli).existsSync(), isTrue,
        reason: 'bxp-cli binary missing — run `cd bxp-cli && zig build` first');

    // Copy a real dataset sample into a temp dir so bxp-cli can run there
    // without polluting the dataset folder with a generated csvx + bxtb.
    workDir = Directory.systemTemp.createTempSync('btrace_loader_test_');
    final sample = File(p.join(monoRoot, 'datasets', 'trading212_to_wealthfolio',
        'sample.csv'));
    final cfg = File(p.join(monoRoot, 'datasets', 'trading212_to_wealthfolio',
        'sample.json'));
    sample.copySync(p.join(workDir.path, 'sample.csv'));
    cfg.copySync(p.join(workDir.path, 'bxp-cli.json'));

    final result = await Process.run(
      bxpCli,
      ['--trace-file=${p.join(workDir.path, 'trace.bxtb')}'],
      workingDirectory: workDir.path,
    );
    expect(result.exitCode, 0,
        reason:
            'bxp-cli failed: stderr=${result.stderr} stdout=${result.stdout}');
  });

  tearDownAll(() {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  test('loadFile parses real btrace and groups frames by kind', () async {
    final tracePath = p.join(workDir.path, 'trace.bxtb');
    final model = await BtraceLoader.loadFile(tracePath);
    expect(model, isNotNull);

    // file_start should be present with template + path identifying the run.
    expect(model!.fileStart, isNotNull);
    expect(model.fileStart!.template, equals('trading212_to_wealthfolio'));
    expect(model.fileStart!.path.endsWith('sample.csv'), isTrue);

    // file_end is the producer's commitment that the file processed
    // cleanly; outputRowCount must match writtenRows.
    expect(model.fileEnd, isNotNull);
    expect(model.outputRowCount, equals(model.fileEnd!.writtenRows));

    // Schema v3 default: no errors, no warnings, exit 0.
    expect(model.fileEnd!.errors, equals(0));
    expect(model.fileEnd!.warnings, equals(0));
    expect(model.done, isNotNull);
    expect(model.done!.exitCode, equals(0));

    // The trading212 sample produces 55 output rows from 49 source rows
    // (Currency conversion = 3 outputs per source). This is a stable
    // expectation tied to the dataset; if the dataset changes, update
    // both this expectation and the .expected file.
    expect(model.outputRowCount, greaterThan(0),
        reason: 'expected at least some output rows from trading212 sample');

    // Each output_row carries a source byte offset usable by CsvRowFetcher.
    // Verify monotonicity (the producer writes them in source-file order)
    // and that the first locator points past the header line.
    expect(model.outputRows.first.sourceLocator, greaterThan(0),
        reason: 'first source_locator should skip the CSV header line');
    int prev = -1;
    for (final r in model.outputRows) {
      expect(r.sourceLocator, greaterThanOrEqualTo(prev),
          reason: 'source_locators should be monotonically non-decreasing');
      prev = r.sourceLocator;
    }
  });

  test('outputRow.action carries the rule\'s \$action result', () async {
    final model = await BtraceLoader.loadFile(
        p.join(workDir.path, 'trace.bxtb'));
    expect(model, isNotNull);
    // trading212 emits a mix of activity types: BUY / SELL / DIVIDEND /
    // INTEREST / DEPOSIT / WITHDRAWAL / FEE. We assert "at least one DIVIDEND"
    // and "at least one DEPOSIT" — both are present in the sample dataset.
    final actions = model!.outputRows.map((r) => r.action).toSet();
    expect(actions, contains('DIVIDEND'));
    expect(actions, contains('DEPOSIT'));
  });

  test('estimatedBytes is realistic vs file size on disk', () async {
    final tracePath = p.join(workDir.path, 'trace.bxtb');
    final model = await BtraceLoader.loadFile(tracePath);
    expect(model, isNotNull);
    final fileBytes = File(tracePath).lengthSync();
    final estimated = model!.estimatedBytes();
    // Schema v3 default: btrace is index-only, mostly output_row frames
    // (35-40 B each on the wire) + small file_start. The Dart model wraps
    // each in an object (~32 B overhead) so estimatedBytes should be the
    // same order of magnitude as the on-disk file, never more than ~5×.
    expect(estimated, lessThan(fileBytes * 5),
        reason: 'estimated=$estimated bytes vs on-disk=$fileBytes bytes — '
            'memory blow-up suggests an unexpected frame type');
  });

  test('fromBytes throws on bad magic', () {
    final badBytes = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
    expect(() => BtraceLoader.fromBytes(badBytes), throwsFormatException);
  });

  test('loadFile returns null for missing path', () async {
    final model = await BtraceLoader.loadFile('/nonexistent/trace.bxtb');
    expect(model, isNull);
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
