// Pre-save guard regression gate (`TraceStore._firstErrTraceIn`).
//
// The guard is the ONLY thing standing between a Zig-side-only validation
// error and a broken file on disk: the Dart validator has no counterpart for
// cross-field rules such as "date_filter_from_filename requires '$date' in
// input_schema", so `configHasErrors` stays false, the toolbar SAVE button
// stays enabled, and a successful save would clear the undo stack
// (`_astHistory` / `_historyIndex` / `_isDirty` / `_opLog`) over a config the
// engine rejects.
//
// The guard silently stopped matching when the bridge's marker payloads became
// objects (Phase G1, commit 4fe9dc1) while this walker still required
// `value is String`. This test drives the real bridge end-to-end so the object
// shape can never regress unnoticed again; a second case pins the legacy
// bare-string branch, which the bridge can no longer produce.

import 'dart:io';

import 'package:bxp_gui/services/bxp_process_client.dart';
import 'package:bxp_gui/store/trace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A config that is valid as written: `date_filter_from_filename` is false, so
/// the missing `$date` in `input_schema` is legal. Flipping the flag to true
/// makes it illegal — and ONLY the Zig side knows that rule.
const _config = '''
{
  conversion_templates: {
    demo: {
      data_dir: "data/demo",
      file_type_in: "csv",
      file_type_out: "csv",
      file_pattern_in: ".csv",
      file_pattern_out: ".csvx",
      date_filter_from_filename: false,
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
            '`cd bxp-gui-bridge && zig build -Doptimize=ReleaseSafe` first');
    BxpProcessClient.setBridgeLibPathForTest(bridgePath);
    // Outside the repo on purpose: the save path writes a `.bxp-tmp` sibling
    // and (on success) a timestamped backup next to the config.
    tmp = Directory.systemTemp.createTempSync('bxp-save-guard-');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('saveConfig refuses a bridge-only cross-field error and keeps the file',
      () async {
    // `data_dir` is resolved relative to the config and existence-checked by
    // the bridge's FS pass — create it so the baseline is genuinely clean and
    // the only finding under test is the cross-field rule.
    Directory(p.join(tmp.path, 'data', 'demo')).createSync(recursive: true);
    final cfg = File(p.join(tmp.path, 'bxp-cli.json'));
    cfg.writeAsStringSync(_config);
    final before = cfg.readAsBytesSync();

    final store = TraceStore();
    addTearDown(store.dispose);
    await _awaitInit(store);

    store.setConfigPath(cfg.path);
    await store.loadConfig();
    expect(store.configError, isNull,
        reason: 'baseline config must load cleanly');
    expect(store.configHasErrors, isFalse,
        reason: 'baseline config must validate clean; '
            'got ${store.validationSummary()}');

    // The single edit that makes the config illegal for the engine while
    // leaving it perfectly valid JSON5 — the Dart validator sees nothing.
    store.editConfigNode(
        ['conversion_templates', 'demo', 'date_filter_from_filename'], true);
    expect(store.isDirty, isTrue, reason: 'the edit must have applied');

    await store.saveConfig();

    expect(store.configSaveError, isNotNull,
        reason: 'the pre-save guard must block the write');
    expect(store.configSaveError, contains('pre-save validation failed'));
    expect(store.configSaveError, contains('date_filter_from_filename'));
    expect(cfg.readAsBytesSync(), before,
        reason: 'the on-disk config must be byte-identical');
    expect(store.isDirty, isTrue,
        reason: 'a refused save must not clear the dirty flag / undo stack');
    expect(File('${cfg.path}.bxp-tmp').existsSync(), isFalse,
        reason: 'the staged tmp file must be cleaned up');
    // A refused save must not leave a timestamped backup behind either.
    expect(
        tmp
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith('bxp-cli.json_'))
            .isEmpty,
        isTrue,
        reason: 'no backup should be written when the save is refused');
  });

  test('the guard extracts both marker payload shapes', () {
    // Object shape (what the bridge emits since Phase G1).
    expect(
      TraceStore.firstErrTraceForTest({
        'conversion_templates': {
          r'$err_1': {'message': 'boom', 'line': 3, 'col': 7},
          'demo': {},
        },
      }),
      'boom',
    );
    // Legacy bare-string shape — still accepted for forward-compat.
    expect(
      TraceStore.firstErrTraceForTest({
        'conversion_templates': {r'$err_1': 'legacy boom'},
      }),
      'legacy boom',
    );
    // Object without a `message`: still blocks (non-null) and names the
    // marker rather than rendering an empty banner.
    expect(
      TraceStore.firstErrTraceForTest({
        r'$err_2': {'off': 1, 'len': 2},
      }),
      r'$err_2',
    );
    // Markers nested under a user `$variable` key must still be found —
    // the walker skips only the four annotation prefixes.
    expect(
      TraceStore.firstErrTraceForTest({
        'input_schema': {
          r'$date': {r'$err_3': 'nested boom'},
        },
      }),
      'nested boom',
    );
    // Warnings/info/comments alone are not errors.
    expect(
      TraceStore.firstErrTraceForTest({
        r'$warn_1': {'message': 'w'},
        r'$info_1': {'message': 'i'},
        r'$comm_1': 'c',
      }),
      isNull,
    );
  });
}

/// Wait for `TraceStore._init` (prefs + the bridge docs catalog) to settle.
Future<void> _awaitInit(TraceStore store) async {
  for (var i = 0; i < 400 && !store.initialized; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(store.initialized, isTrue, reason: 'TraceStore init timed out');
  expect(store.fatalStartupError, isNull);
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
