// bridge_verify_minisign FFI gate.
//
// Exercises BridgeClient.verifyMinisign() against the real bxp-gui-bridge .so
// — the in-process minisign signature check the updater runs over SHA256SUMS
// before trusting it. Vectors were produced with minisign 0.11 (`minisign -G
// -W` + `-S`), the same prehashed ("ED" / Blake2b-512) shape the release
// workflow emits. The key here is a THROWAWAY test key, never the release key
// embedded in UpdaterService.minisignPublicKey.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bxp_gui/services/bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late final BridgeClient bridge;

  const pubkey = 'RWQEcu0vt68SdjtYvqFgob3VvMjsOOgNp4I4XXVoz63OSJHAus5CqDVe';
  const file = 'abc123  bxp-desktop-linux-x86_64.AppImage\n';
  const sig =
      'untrusted comment: signature from minisign secret key\n'
      'RUQEcu0vt68Sdpoe4VOmFICkvQaGYDo7PoaSoTidwMK6CoT2pyDdPjtOn1xgmYJfXayf336GWzvgf4Yh+LtL+XypPsX0vUSF0wY=\n'
      'trusted comment: timestamp:1781452539\tfile:SHA256SUMS\thashed\n'
      'bgwWEjryrROXcZzXj13Mm0Oqhw6N+iGJSoTvgVFyZbGaihcEDdTiBIf8zMpLWOmNgxKPkAdzEIB7nurDCRZsAA==\n';

  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  setUpAll(() {
    final monoRoot = _findMonoRoot();
    final bridgePath = Platform.isWindows
        ? p.join(monoRoot, 'bxp-gui-bridge', 'zig-out', 'bin', 'bxp-gui-bridge.dll')
        : p.join(monoRoot, 'bxp-gui-bridge', 'zig-out', 'lib',
            Platform.isMacOS ? 'libbxp-gui-bridge.dylib' : 'libbxp-gui-bridge.so');
    expect(File(bridgePath).existsSync(), isTrue, reason: 'missing: $bridgePath');
    bridge = BridgeClient(bridgePath);
  });

  test('accepts a valid prehashed signature', () {
    expect(bridge.verifyMinisign(b(file), b(sig), pubkey), 0);
  });

  test('rejects a tampered file', () {
    final tampered = b('abc123  bxp-desktop-linux-x86_64.AppImageX\n');
    expect(bridge.verifyMinisign(tampered, b(sig), pubkey), isNot(0));
  });

  test('rejects a different / malformed public key', () {
    expect(bridge.verifyMinisign(b(file), b(sig), 'not-base64!!!'), isNot(0));
  });

  test('rejects empty inputs', () {
    expect(bridge.verifyMinisign(Uint8List(0), b(sig), pubkey), isNot(0));
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
