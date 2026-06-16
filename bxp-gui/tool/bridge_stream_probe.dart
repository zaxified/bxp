// Cross-platform bridge STREAMING-load probe (Zig 0.16 migration verification).
//
// The single GUI backend is the bridge; bxp-cli runs flow through
// `bridge_run_streaming`, whose native reader thread drains the child's stdout
// pipe. On Zig 0.15.2 that path SEGV'd (NULL deref at 0x30) under sustained
// streaming load — the reason `build.zig` used to force Debug→ReleaseSafe. The
// rewrite was dropped on 0.16 (new self-hosted x86 backend); this probe proves
// the streaming drain survives a multi-MB BXTB stream byte-identical under load.
//
//   S1 spawn+stream --version returns exit 0 with output
//   S2 a ~5 MB BXTB --trace stream is byte-IDENTICAL to a shell-redirected
//      ground truth (proof the pipe drains with no truncation/corruption)
//   S3 cancel mid-stream stops early, doesn't hang, child exits non-zero
//
// Run (after building the 0.16 bridge .so + bxp-cli):
//   BXP_PROBE_DIR=/tmp/bxp-stream-probe BXP_CLI=<abs bxp-cli> \
//     dart run tool/bridge_stream_probe.dart
// Fixtures (gitignored scratch): $BXP_PROBE_DIR/{config.json, data/, gt.bin}.

import 'dart:io';
import 'dart:typed_data';

import 'package:bxp_gui/services/bridge_client.dart';
import 'package:path/path.dart' as p;

const int kb = 1024;

void main() async {
  final root = _findMonoRoot();
  final probeDir = Platform.environment['BXP_PROBE_DIR'] ?? '/tmp/bxp-stream-probe';
  final cli = Platform.environment['BXP_CLI'] ??
      p.join(root, 'bxp-cli', 'zig-out', 'bin', 'bxp-cli');
  // `findBridgeLibrary()` walks from the running executable; under `dart run`
  // that's the Dart SDK, not the workspace, so resolve the dev-tree .so
  // explicitly here (BXP_BRIDGE_LIB overrides).
  final libName = Platform.isMacOS ? 'libbxp-gui-bridge.dylib' : 'libbxp-gui-bridge.so';
  final dll = Platform.environment['BXP_BRIDGE_LIB'] ??
      p.join(root, 'bxp-gui-bridge', 'zig-out', 'lib', libName);
  final cfg = p.join(probeDir, 'config.json');
  final gtFile = p.join(probeDir, 'gt.bin');

  if (!File(dll).existsSync()) {
    stderr.writeln('MISSING: bridge library $dll');
    exit(2);
  }
  for (final f in [cli, cfg, gtFile]) {
    if (!File(f).existsSync()) {
      stderr.writeln('MISSING: $f');
      exit(2);
    }
  }

  final bridge = BridgeClient(dll);
  stdout.writeln('bridge version: ${bridge.bridgeVersion}');
  stdout.writeln('dll: $dll\ncli: $cli\n');

  var pass = 0, fail = 0;
  void check(String name, bool ok, String detail) {
    stdout.writeln('${ok ? "PASS" : "FAIL"}  $name\n        $detail');
    ok ? pass++ : fail++;
  }

  final traceArgs = ['--config', cfg, '--template', 't', '--data', 'data', '--dry-run', '--trace'];

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
      traceArgs,
      cwd: probeDir,
      onChunk: (c) {
        got.add(c);
        if (firstBytes.length < 4) firstBytes.addAll(c.take(4 - firstBytes.length));
      },
    );
    sw.stop();
    final gotBytes = got.toBytes();
    final magic = firstBytes.length >= 4 &&
        firstBytes[0] == 0x42 && firstBytes[1] == 0x58 &&
        firstBytes[2] == 0x54 && firstBytes[3] == 0x42; // 'BXTB'
    check(
      'S2 large BXTB stream byte-identical',
      exit == 0 && magic && _bytesEqual(gotBytes, gt) && gotBytes.length > 1024 * kb,
      'exit=$exit bytes=${gotBytes.length} gt=${gt.length} '
      'identical=${_bytesEqual(gotBytes, gt)} magic=$magic elapsed=${sw.elapsedMilliseconds}ms',
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
          traceArgs,
          cwd: probeDir,
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
