// bridge_inspect FFI parity gate.
//
// Exercises BridgeClient.inspect() against the real bxp-gui-bridge .so and
// asserts each op produces the same output the corresponding `bxp-fmt`
// subcommand does — i.e. the in-process inspect path the GUI now prefers
// (docs / config / list_templates / fetch_template / eval_batch) is a faithful
// stand-in for the subprocess it replaced. Dart-side so the FFI boundary +
// BridgeClient marshalling are exercised, not just the Zig core.

import 'dart:convert';
import 'dart:io';

import 'package:bxp_gui/services/bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late final String monoRoot;
  late final String bridgePath;
  late final String bxpFmtPath;
  late final String configPath;
  late final BridgeClient bridge;
  const templateId = 'trading212_to_wealthfolio';

  setUpAll(() {
    monoRoot = _findMonoRoot();
    bridgePath = Platform.isWindows
        ? p.join(monoRoot, 'bxp-gui-bridge', 'zig-out', 'bin', 'bxp-gui-bridge.dll')
        : p.join(monoRoot, 'bxp-gui-bridge', 'zig-out', 'lib',
            Platform.isMacOS ? 'libbxp-gui-bridge.dylib' : 'libbxp-gui-bridge.so');
    final exe = Platform.isWindows ? '.exe' : '';
    bxpFmtPath = p.join(monoRoot, 'bxp-fmt', 'zig-out', 'bin', 'bxp-fmt$exe');
    configPath =
        p.join(monoRoot, 'datasets', templateId, 'sample.json');

    for (final f in [bridgePath, bxpFmtPath, configPath]) {
      expect(File(f).existsSync(), isTrue, reason: 'missing: $f');
    }
    bridge = BridgeClient(bridgePath);
  });

  // bxp-fmt stdout carries a trailing newline the inspect cores don't; compare
  // trimmed so we assert content parity, not framing.
  String fmtOut(List<String> args) =>
      (Process.runSync(bxpFmtPath, args).stdout as String).trim();

  test('docs op == bxp-fmt --docs', () {
    final viaBridge = bridge.inspect('{"op":"docs"}');
    expect(viaBridge, isNotNull);
    expect(viaBridge!.trim(), equals(fmtOut(['--docs'])));
    // sanity: it really is the catalog
    final m = jsonDecode(viaBridge) as Map<String, dynamic>;
    expect(m.containsKey('functions'), isTrue);
    expect(m.containsKey('config_schema'), isTrue);
  });

  test('config op == bxp-fmt --config', () {
    final viaBridge =
        bridge.inspect(jsonEncode({'op': 'config', 'path': configPath}));
    expect(viaBridge, isNotNull);
    expect(viaBridge!.trim(), equals(fmtOut(['--config', configPath])));
  });

  test('list_templates op == bxp-fmt --list-templates', () {
    final viaBridge =
        bridge.inspect(jsonEncode({'op': 'list_templates', 'path': configPath}));
    expect(viaBridge, isNotNull);
    expect(viaBridge!.trim(),
        equals(fmtOut(['--config', configPath, '--list-templates'])));
  });

  test('fetch_template op == bxp-fmt --fetch-template', () {
    final viaBridge = bridge.inspect(
        jsonEncode({'op': 'fetch_template', 'path': configPath, 'id': templateId}));
    expect(viaBridge, isNotNull);
    expect(viaBridge!.trim(),
        equals(fmtOut(['--config', configPath, '--fetch-template', templateId])));
  });

  test('eval_batch op evaluates a row', () {
    final viaBridge = bridge.inspect(jsonEncode({
      'op': 'eval_batch',
      'request': {
        'headers': ['P'],
        'fields': ['7'],
        'exprs': ['[P]', 'BADFN()'],
      },
    }));
    expect(viaBridge, isNotNull);
    final results = (jsonDecode(viaBridge!) as Map)['results'] as List;
    expect(results.length, 2);
    expect((results[0] as Map)['value'], '7');
    expect((results[1] as Map)['ok'], false);
  });
}

String _findMonoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 10; i++) {
    if (Directory(p.join(dir.path, 'bxp-gui-bridge')).existsSync() &&
        Directory(p.join(dir.path, 'scripts')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('monorepo root not found from ${Directory.current.path}');
}
