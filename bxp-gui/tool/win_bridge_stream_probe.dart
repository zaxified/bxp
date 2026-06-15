// Windows bridge STREAMING transport probe (v0.2.5 pre-release sweep).
//
// The single GUI backend on every platform is now the bridge, and bxp-cli runs
// (dry-run / full-run / --version) all flow through `bridge_run_streaming`.
// flutter test covers bridge_inspect + expr-corpus (small, in-proc FFI) but NOT
// a large streamed bxp-cli stdout — exactly the dart-lang/sdk#1727 Windows
// anonymous-pipe ~8 KB truncation risk. This probe drives the REAL
// bxp-gui-bridge.dll through the GUI transport layer (BridgeClient) and asserts:
//
//   S1 spawn+stream a tiny run (--version) returns exit 0 with output
//   S2 a ~4.6 MB BXTB dry-run streams byte-IDENTICAL to a shell-redirected
//      ground truth (proof the pipe drains with no truncation/corruption)
//   S3 cancel mid-stream stops early, doesn't hang, and the child does not
//      exit 0 (TerminateProcess)
//
// Run on Windows (after `zig build` in bxp-gui-bridge and bxp-cli):
//   cd bxp-gui && dart run tool/win_bridge_stream_probe.dart
//
// Fixtures live in DEV/win-prerelease-0.2.5/bridge-test (gitignored scratch):
//   config.json + data/big_*.csv (150k rows) + gt.bin (shell ground truth).

import 'dart:io';
import 'dart:typed_data';

import 'package:bxp_gui/services/bridge_client.dart';
import 'package:path/path.dart' as p;

const int kb = 1024;

void main() async {
  if (!Platform.isWindows) {
    stderr.writeln('win_bridge_stream_probe is Windows-only.');
    exit(2);
  }

  final repo = _findMonoRoot();
  final dll = p.join(
      repo, 'bxp-gui-bridge', 'zig-out', 'bin', 'bxp-gui-bridge.dll');
  final cli = p.join(repo, 'bxp-cli', 'zig-out', 'bin', 'bxp-cli.exe');
  final devDir = p.join(repo, 'DEV', 'win-prerelease-0.2.5', 'bridge-test');
  final cfg = p.join(devDir, 'config.json');
  final gtFile = p.join(devDir, 'gt.bin');

  for (final f in [dll, cli, cfg, gtFile]) {
    if (!File(f).existsSync()) {
      stderr.writeln('MISSING: $f');
      exit(2);
    }
  }

  final bridge = BridgeClient(dll);
  stdout.writeln('bridge version: ${bridge.bridgeVersion}');
  stdout.writeln('repo: $repo\n');

  var pass = 0, fail = 0;
  void check(String name, bool ok, String detail) {
    stdout.writeln('${ok ? "PASS" : "FAIL"}  $name\n        $detail');
    ok ? pass++ : fail++;
  }

  // ---- S1: tiny spawn+stream sanity (--version) ----
  {
    final buf = <int>[];
    final exit = await bridge.runStreamingBinary(
      cli,
      const ['--version'],
      onChunk: (c) => buf.addAll(c),
    );
    final text = String.fromCharCodes(buf).trim();
    check('S1 spawn+stream --version', exit == 0 && text.contains('bxp-cli'),
        'exit=$exit out="$text"');
  }

  // ---- S2: large BXTB stream byte-identical vs shell ground truth ----
  {
    final gt = File(gtFile).readAsBytesSync();
    final got = BytesBuilder(copy: false);
    final firstBytes = <int>[];
    final sw = Stopwatch()..start();
    final exit = await bridge.runStreamingBinary(
      cli,
      ['--config', cfg, '--dry-run', '--trace'],
      cwd: devDir,
      onChunk: (c) {
        got.add(c);
        if (firstBytes.length < 4) {
          firstBytes.addAll(c.take(4 - firstBytes.length));
        }
      },
    );
    sw.stop();
    final gotBytes = got.toBytes();
    final magic = firstBytes.length >= 4 &&
        firstBytes[0] == 0x42 &&
        firstBytes[1] == 0x58 &&
        firstBytes[2] == 0x54 &&
        firstBytes[3] == 0x42; // 'BXTB'
    check(
      'S2 large BXTB stream byte-identical',
      exit == 0 && magic && _bytesEqual(gotBytes, gt) && gotBytes.length > 1024 * kb,
      'exit=$exit bytes=${gotBytes.length} gt=${gt.length} '
      'identical=${_bytesEqual(gotBytes, gt)} magic=$magic '
      'elapsed=${sw.elapsedMilliseconds}ms',
    );
  }

  // ---- S3: cancel mid-stream ----
  {
    final fullSize = File(gtFile).lengthSync();
    var total = 0;
    int? handle;
    var cancelSignaled = false;
    final sw = Stopwatch()..start();
    final exit = await bridge
        .runStreamingBinary(
          cli,
          ['--config', cfg, '--dry-run', '--trace'],
          cwd: devDir,
          onSpawn: (h) => handle = h,
          onChunk: (c) {
            total += c.length;
            if (!cancelSignaled && total > 256 * kb && handle != null) {
              cancelSignaled = bridge.cancel(handle!);
            }
          },
        )
        .timeout(const Duration(seconds: 30), onTimeout: () => -999);
    sw.stop();
    check(
      'S3 cancel mid-stream',
      cancelSignaled && exit != -999 && exit != 0 && total < fullSize,
      'cancelSignaled=$cancelSignaled exit=$exit stoppedAt=$total '
      '(<full=$fullSize) noHang=${exit != -999} elapsed=${sw.elapsedMilliseconds}ms',
    );
  }

  stdout.writeln('\n=== bridge stream probe: $pass passed, $fail failed ===');
  exit(fail == 0 ? 0 : 1);
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _findMonoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory(p.join(dir.path, 'bxp-core')).existsSync() &&
        Directory(p.join(dir.path, 'bxp-gui-bridge')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('monorepo root not found from ${Directory.current.path}');
}
