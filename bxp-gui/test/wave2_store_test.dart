// Wave-2 audit regressions in TraceStore: a rejected deleteConfigNode must
// keep the user's selection. Drives the real bridge like save_guard_test.dart.

import 'dart:io';

import 'package:bxp_gui/services/bxp_process_client.dart';
import 'package:bxp_gui/store/trace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _config = '''
{
  conversion_templates: {
    demo: {
      data_dir: "data/demo",
      file_type_in: "csv",
      file_type_out: "csv",
      file_pattern_in: ".csv",
      file_pattern_out: ".csvx",
      input_schema: { \$symbol: "[Sym]" },
      row_rules: [
        { when: "1", rows: [ { \$action: "'BUY'" } ] },
      ],
      output_schema: { symbol: "\$symbol" },
    },
  },
}
''';

void main() {
  late Directory tmp;

  setUpAll(() {
    final root = _findMonoRoot();
    final lib = Platform.isWindows
        ? p.join(root, 'bxp-gui-bridge', 'zig-out', 'bin', 'bxp-gui-bridge.dll')
        : p.join(root, 'bxp-gui-bridge', 'zig-out', 'lib',
            Platform.isMacOS
                ? 'libbxp-gui-bridge.dylib'
                : 'libbxp-gui-bridge.so');
    expect(File(lib).existsSync(), isTrue, reason: 'build the bridge first');
    BxpProcessClient.setBridgeLibPathForTest(lib);
    tmp = Directory.systemTemp.createTempSync('bxp-wave2-store-');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('a rejected deleteConfigNode keeps the selection', () async {
    final cfg = File(p.join(tmp.path, 'c.json'))..writeAsStringSync(_config);
    final store = TraceStore();
    addTearDown(store.dispose);
    for (var i = 0; i < 400 && !store.initialized; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    store.setConfigPath(cfg.path);
    await store.loadConfig();

    const base = ['conversion_templates', 'demo', 'row_rules'];
    final sel = [...base, '0', 'when'];
    store.setSelectedExpr(sel, '1');
    final rev = store.editRevision;

    // Index 99 does not exist: the AST op fails, nothing may change.
    store.deleteConfigNode([...base, '99']);
    expect(store.editRevision, rev);
    expect(store.selectedExprPath, sel);
    expect(store.selectedExprText, '1');

    // A real delete of the selected leaf's ancestor still clears it.
    store.deleteConfigNode([...base, '0']);
    expect(store.selectedExprPath, isNull);
  });
}

String _findMonoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    if (Directory(p.join(dir.path, 'bxp-core')).existsSync() &&
        Directory(p.join(dir.path, 'bxp-gui-bridge')).existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  throw StateError('monorepo root not found');
}
