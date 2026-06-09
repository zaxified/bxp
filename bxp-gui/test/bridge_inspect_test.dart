// bridge_inspect FFI structural-validity gate.
//
// Exercises BridgeClient.inspect() against the real bxp-gui-bridge .so and
// asserts each op (docs / config / list_templates / fetch_template /
// eval_batch) returns well-formed output through the FFI boundary — the
// in-process inspect path the GUI relies on. Dart-side so the FFI boundary +
// BridgeClient marshalling are exercised, not just the Zig core. (The byte
// shape originates in bxp-core/inspect; bxp-mcp wraps the same core and is
// smoke-tested separately in scripts/test-05-mcp.sh.)

import 'dart:convert';
import 'dart:io';

import 'package:bxp_gui/services/bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late final String monoRoot;
  late final String bridgePath;
  late final String configPath;
  late final BridgeClient bridge;
  const templateId = 'trading212_to_wealthfolio';

  setUpAll(() {
    monoRoot = _findMonoRoot();
    bridgePath = Platform.isWindows
        ? p.join(monoRoot, 'bxp-gui-bridge', 'zig-out', 'bin', 'bxp-gui-bridge.dll')
        : p.join(monoRoot, 'bxp-gui-bridge', 'zig-out', 'lib',
            Platform.isMacOS ? 'libbxp-gui-bridge.dylib' : 'libbxp-gui-bridge.so');
    configPath =
        p.join(monoRoot, 'datasets', templateId, 'sample.json');

    for (final f in [bridgePath, configPath]) {
      expect(File(f).existsSync(), isTrue, reason: 'missing: $f');
    }
    bridge = BridgeClient(bridgePath);
  });

  test('docs op returns the language/schema catalog', () {
    final viaBridge = bridge.inspect('{"op":"docs"}');
    expect(viaBridge, isNotNull);
    final m = jsonDecode(viaBridge!) as Map<String, dynamic>;
    expect(m.containsKey('functions'), isTrue);
    expect(m.containsKey('config_schema'), isTrue);
  });

  test('config op returns the annotated config tree', () {
    final viaBridge =
        bridge.inspect(jsonEncode({'op': 'config', 'path': configPath}));
    expect(viaBridge, isNotNull);
    final m = jsonDecode(viaBridge!) as Map<String, dynamic>;
    expect(m.containsKey('conversion_templates'), isTrue);
    // A clean dataset config must carry no error markers.
    expect(m.keys.any((k) => k.startsWith(r'$err_')), isFalse);
  });

  test('list_templates op lists the template id', () {
    final viaBridge =
        bridge.inspect(jsonEncode({'op': 'list_templates', 'path': configPath}));
    expect(viaBridge, isNotNull);
    final templates = (jsonDecode(viaBridge!) as Map)['templates'] as List;
    expect(templates.map((t) => (t as Map)['id']), contains(templateId));
  });

  test('fetch_template op returns one template block', () {
    final viaBridge = bridge.inspect(
        jsonEncode({'op': 'fetch_template', 'path': configPath, 'id': templateId}));
    expect(viaBridge, isNotNull);
    final m = jsonDecode(viaBridge!) as Map<String, dynamic>;
    expect(m.containsKey(r'$err_1'), isFalse);
    expect(m.isNotEmpty, isTrue);
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
