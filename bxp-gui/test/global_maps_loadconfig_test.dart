// Integration test for the GLOBAL half of drill-down `maps` resolution.
//
// `_BtraceIngestCtx._ensureGlobalMaps` reads the top-level `maps` registry from
// the real annotated `loadConfig` output (the same on-disk source the engine
// uses) and feeds it to `parseMapsRegistry`. This test exercises exactly that
// extraction against the live bxp-gui-bridge so the annotated-tree shape can't
// silently drift away from what the parser expects. Mirrors the bridge wiring
// in expr_batch_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:bxp_gui/services/bxp_process_client.dart';
import 'package:bxp_gui/store/trace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

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
    tmp = Directory.systemTemp.createTempSync('bxp-global-maps-');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('top-level maps survive the annotated loadConfig round-trip', () async {
    // A config whose template references a GLOBAL named map via REMAP — the
    // exact shape the old drill-down failed to resolve.
    final cfg = File(p.join(tmp.path, 'bxp-cli.json'));
    cfg.writeAsStringSync('''
{
  // a top-level shared registry, not template-local
  maps: {
    tickers: { "VOW.DE": "VOW.DE.XETRA", "AGNC": "AGNC.NASDAQ" },
  },
  conversion_templates: {
    demo: {
      data_dir: "data/demo",
      file_pattern_in: ".csv",
      file_pattern_out: ".csvx",
      input_schema: { \$sym: "REMAP([Sym], 'tickers')" },
      row_rules: [ { when: "1", rows: [ { \$action: "'BUY'" } ] } ],
      output_schema: { symbol: "\$sym" },
    },
  },
}
''');

    final tree = jsonDecode(await BxpProcessClient.loadConfig(cfg.path));
    expect(tree, isA<Map>());
    expect((tree as Map)['maps'], isA<Map>(),
        reason: 'annotated tree must keep the top-level maps object');

    final global = parseMapsRegistry(tree['maps'] as Map);
    expect(global, {
      'tickers': {'VOW.DE': 'VOW.DE.XETRA', 'AGNC': 'AGNC.NASDAQ'},
    });
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
