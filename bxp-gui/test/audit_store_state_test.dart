// TraceStore state-machine regressions (audit 2026-10-19): loadConfig early
// exits and re-entrancy, save-vs-edit race, expression-validation staleness.
// Drives the real bridge like save_guard_test.dart.

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
      input_schema: {
        \$symbol: "[Sym]",
      },
      row_rules: [
        { when: "1", rows: [ { \$action: "'BUY'" } ] },
      ],
      output_schema: { symbol: "\$symbol" },
    },
  },
}
''';

const _symPath = ['conversion_templates', 'demo', 'input_schema', r'$symbol'];

void main() {
  late Directory tmp;
  late File good;
  late File bad;

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
    tmp = Directory.systemTemp.createTempSync('bxp-audit-store-');
    Directory(p.join(tmp.path, 'data', 'demo')).createSync(recursive: true);
    good = File(p.join(tmp.path, 'good.json'))..writeAsStringSync(_config);
    bad = File(p.join(tmp.path, 'bad.json'))..writeAsStringSync('{ a: ');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<TraceStore> newStore() async {
    final store = TraceStore();
    addTearDown(store.dispose);
    for (var i = 0; i < 400 && !store.initialized; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(store.initialized, isTrue);
    expect(store.fatalStartupError, isNull);
    return store;
  }

  test('a failed parse notifies listeners with isLoadingConfig cleared and '
      'drops the previous file history', () async {
    final store = await newStore();
    store.setConfigPath(good.path);
    await store.loadConfig();
    store.editConfigNode([...(_symPath)], '1+1');
    expect(store.canUndo, isTrue);

    final seen = <bool>[];
    store.addListener(() => seen.add(store.isLoadingConfig));
    store.setConfigPath(bad.path);
    seen.clear();
    await store.loadConfig();

    expect(store.astRoot, isNull);
    expect(store.configError, isNotNull);
    expect(seen, isNotEmpty);
    expect(seen.last, isFalse,
        reason: 'last notification must not still say "loading"');
    expect(store.canUndo, isFalse, reason: 'Undo must not resurrect old file');
    expect(store.isDirty, isFalse);
  });

  test('overlapping loads: the newer one wins and clears the loading flag',
      () async {
    final store = await newStore();
    store.setConfigPath(bad.path);
    final first = store.loadConfig();
    store.setConfigPath(good.path);
    final second = store.loadConfig();
    await Future.wait([first, second]);
    expect(store.astRoot, isNotNull);
    expect(store.configError, isNull);
    expect(store.isLoadingConfig, isFalse);
  });

  test('saveConfig refuses to write when the config is edited mid-save',
      () async {
    final cfg = File(p.join(tmp.path, 'save.json'))..writeAsStringSync(_config);
    final before = cfg.readAsBytesSync();
    final store = await newStore();
    store.setConfigPath(cfg.path);
    await store.loadConfig();
    store.editConfigNode(_symPath, '1+1');
    final saving = store.saveConfig();
    store.editConfigNode(_symPath, '2+2'); // lands during the save's awaits
    await saving;
    expect(store.configSaveError, contains('edited while saving'));
    expect(cfg.readAsBytesSync(), before);
    expect(store.isDirty, isTrue, reason: 'edits must stay pending');
    expect(File('${cfg.path}.bxp-tmp').existsSync(), isFalse);
  });

  test('undo re-validates the selected expression (no stuck "checking")',
      () async {
    final store = await newStore();
    store.setConfigPath(good.path);
    await store.loadConfig();
    store.editConfigNode(_symPath, '1+1');
    store.setSelectedExpr(_symPath, '1+1');
    store.undo();
    for (var i = 0;
        i < 100 && store.exprValidationState == ExprValidationState.pending;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(store.exprValidationState, isNot(ExprValidationState.pending));
  });

  test('a multi-line expression leaf still gets a validation verdict',
      () async {
    final store = await newStore();
    store.setConfigPath(good.path);
    await store.loadConfig();
    store.setSelectedExpr(_symPath, '1 +\n2');
    for (var i = 0;
        i < 100 && store.exprValidationState == ExprValidationState.pending;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(store.exprValidationState, isNot(ExprValidationState.pending));
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
