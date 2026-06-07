// Smoke test for `BxpProcessClient.evalBatch` — the Dart wrapper around
// `bxp-fmt --expr-batch` that drives GUI drill-down re-eval since schema
// v3 dropped per-row detail frames from btrace.
//
// Verifies the JSON-on-stdin contract end-to-end: spawn the real bxp-fmt
// binary, push a multi-expression request through stdin, parse the JSON
// response off stdout, assert per-result ok/error shape matches what the
// GUI drill-down panel will assume.
//
// The test passes `binPath:` explicitly because `flutter test` runs from a
// CWD that doesn't trigger `BxpProcessClient.findBin`'s dev-tree walk; the
// monorepo root is located by walking up from the test file's CWD.

import 'dart:io';

import 'package:bxp_gui/services/bxp_process_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late final String bxpFmtPath;

  setUpAll(() {
    final monoRoot = _findMonoRoot();
    final exe = Platform.isWindows ? '.exe' : '';
    bxpFmtPath = p.join(monoRoot, 'bxp-fmt', 'zig-out', 'bin', 'bxp-fmt$exe');
    expect(File(bxpFmtPath).existsSync(), isTrue,
        reason: 'bxp-fmt missing at $bxpFmtPath — run '
            '`cd bxp-fmt && zig build` first');

    // On Windows, evalBatch routes through the bridge DLL (dart:io pipe
    // truncation workaround); under `flutter test` it can't self-resolve
    // the DLL (no bxp-gui.exe sibling), so point it at the dev-tree build.
    // Linux/macOS use Process.start directly and need no injection.
    if (Platform.isWindows) {
      final dll = p.join(
          monoRoot, 'bxp-gui-bridge', 'zig-out', 'bin', 'bxp-gui-bridge.dll');
      expect(File(dll).existsSync(), isTrue,
          reason: 'bridge DLL missing at $dll — run '
              '`cd bxp-gui-bridge && zig build` first');
      BxpProcessClient.setBridgeDllPathForTest(dll);
    }
  });

  test('evalBatch returns parallel results for happy path + error mix',
      () async {
    final results = await BxpProcessClient.evalBatch(
      binPath: bxpFmtPath,
      headers: const ['Ticker', 'Qty', 'Price'],
      fields: const ['AGNC', '2', '100.50'],
      tickerMap: const {'AGNC': 'AGNC.NASDAQ'},
      exprs: const [
        'TICKER([Ticker])',
        '[Qty]',
        '[Qty] * [Price]',
        '[NoSuchCol]', // missing column → "" per expr.zig semantics
        'BROKEN((',    // syntax error → ok:false with detail
      ],
    );

    expect(results.length, 5, reason: 'one result per expression');

    expect(results[0].ok, isTrue);
    expect(results[0].value, 'AGNC.NASDAQ');

    expect(results[1].ok, isTrue);
    expect(results[1].value, '2');

    expect(results[2].ok, isTrue);
    expect(results[2].value, '201');

    // Missing column resolves silently to "" — intentional expr.zig contract,
    // see bxp-core CLAUDE.md "No per-template 'N expression errors' summary".
    expect(results[3].ok, isTrue);
    expect(results[3].value, '');

    expect(results[4].ok, isFalse);
    expect(results[4].error, isNotNull);
    expect(results[4].detail, isNotNull);
  });

  test('evalBatch handles empty exprs list', () async {
    final results = await BxpProcessClient.evalBatch(
      binPath: bxpFmtPath,
      headers: const ['A'],
      fields: const ['1'],
      exprs: const [],
    );
    expect(results, isEmpty);
  });

  test('evalBatch returns empty list when binary missing', () async {
    final results = await BxpProcessClient.evalBatch(
      binPath: '/nonexistent/path/to/bxp-fmt',
      headers: const [],
      fields: const [],
      exprs: const ['[X]'],
    );
    expect(results, isEmpty);
  });
}

/// Walk up from CWD until we find a directory containing both `bxp-core/`
/// and `bxp-fmt/` — the monorepo root.
String _findMonoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    final core = Directory(p.join(dir.path, 'bxp-core'));
    final fmt = Directory(p.join(dir.path, 'bxp-fmt'));
    if (core.existsSync() && fmt.existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
      'could not locate monorepo root from ${Directory.current.path}');
}
