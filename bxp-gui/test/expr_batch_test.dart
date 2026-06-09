// Smoke test for `BxpProcessClient.evalBatch` — the Dart wrapper that drives
// GUI drill-down re-eval (schema v3 dropped per-row detail frames from btrace).
//
// evalBatch runs in-process through the bxp-gui-bridge `bridge_inspect`
// eval_batch op now (the bxp-fmt subprocess path was retired). This test
// injects the dev-tree bridge library and verifies the end-to-end Dart
// contract: build a multi-expression request, marshal it through the FFI,
// parse the JSON response, and assert per-result ok/error shape matches what
// the GUI drill-down panel assumes.
//
// `flutter test` runs from a CWD where `Platform.resolvedExecutable` points at
// the test runner (no `bxp-gui` sibling), so the bridge can't self-resolve —
// hence the explicit `setBridgeLibPathForTest`.

import 'dart:io';

import 'package:bxp_gui/services/bxp_process_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  setUpAll(() {
    final monoRoot = _findMonoRoot();
    final bridgePath = Platform.isWindows
        ? p.join(monoRoot, 'bxp-gui-bridge', 'zig-out', 'bin',
            'bxp-gui-bridge.dll')
        : p.join(monoRoot, 'bxp-gui-bridge', 'zig-out', 'lib',
            Platform.isMacOS
                ? 'libbxp-gui-bridge.dylib'
                : 'libbxp-gui-bridge.so');
    expect(File(bridgePath).existsSync(), isTrue,
        reason: 'bridge library missing at $bridgePath — run '
            '`cd bxp-gui-bridge && zig build` first');
    BxpProcessClient.setBridgeLibPathForTest(bridgePath);
  });

  test('evalBatch returns parallel results for happy path + error mix',
      () async {
    final results = await BxpProcessClient.evalBatch(
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
      headers: const ['A'],
      fields: const ['1'],
      exprs: const [],
    );
    expect(results, isEmpty);
  });
}

/// Walk up from CWD until we find a directory containing both `bxp-core/`
/// and `bxp-gui-bridge/` — the monorepo root.
String _findMonoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    final core = Directory(p.join(dir.path, 'bxp-core'));
    final bridge = Directory(p.join(dir.path, 'bxp-gui-bridge'));
    if (core.existsSync() && bridge.existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
      'could not locate monorepo root from ${Directory.current.path}');
}
