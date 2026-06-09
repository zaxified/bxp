// Windows bridge smoke harness — drives the four Win-only bridge transport
// paths end-to-end through the REAL bxp-gui-bridge.dll and asserts byte
// completeness against shell-redirected ground truth (the dart-lang/sdk#1727
// ~8 KB Win-pipe-truncation risk).
//
// OBSOLETE pending rework: the expr-batch / --config scenarios below proxied
// the (now-deleted) bxp-fmt binary through bridge_run to exercise the pipe
// drain. With bxp-fmt gone, those stateless ops run in-process via
// bridge_inspect (no subprocess), so only the bxp-cli streaming/cancel paths
// still represent a live bridge_run transport. Repoint the large-payload
// scenarios at bxp-cli before relying on this harness again.
//
// This is a developer smoke tool, NOT a shipped test. Run on Windows:
//   cd bxp-gui && dart run tool/win_bridge_smoke.dart
//
// It exercises exactly the GUI's transport layer (bridge_client.dart), so a
// pass means the GUI's bridge paths drain large stdin / stdout / streaming
// payloads without truncation or corruption. Ground truth for each one-shot /
// streaming scenario is produced by `cmd /c "<bin> ... > file"` — the OS
// shell does the redirect, so the bytes never pass through dart:io's pipe
// layer. A byte-for-byte match proves the bridge transport is faithful.
//
// Prerequisites (build first):
//   cd bxp-gui-bridge && zig build      # → zig-out/bin/bxp-gui-bridge.dll
//   cd bxp-cli        && zig build      # → zig-out/bin/bxp-cli.exe
// Plus a populated DEV/ working tree (DEV/bxp-cli.json + data dirs).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bxp_gui/services/bridge_client.dart';
import 'package:path/path.dart' as p;

const int kb = 1024;

void main() async {
  if (!Platform.isWindows) {
    stderr.writeln('win_bridge_smoke is Windows-only (bridge proxy path).');
    exit(2);
  }

  final repo = _findMonoRoot();
  final dll = p.join(repo, 'bxp-gui-bridge', 'zig-out', 'bin', 'bxp-gui-bridge.dll');
  final fmt = p.join(repo, 'bxp-fmt', 'zig-out', 'bin', 'bxp-fmt.exe');
  final cli = p.join(repo, 'bxp-cli', 'zig-out', 'bin', 'bxp-cli.exe');
  final devCwd = p.join(repo, 'DEV');
  final devCfg = p.join(devCwd, 'bxp-cli.json');
  final work = p.join(Directory.systemTemp.path, 'bxp-smoke-gt');
  Directory(work).createSync(recursive: true);

  for (final f in [dll, fmt, cli, devCfg]) {
    if (!File(f).existsSync()) {
      stderr.writeln('MISSING: $f');
      exit(2);
    }
  }

  final bridge = BridgeClient(dll);
  stdout.writeln('bridge version: ${bridge.bridgeVersion}');
  stdout.writeln('repo: $repo');
  stdout.writeln('work: $work');
  stdout.writeln('');

  var pass = 0, fail = 0;
  void check(String name, bool ok, String detail) {
    stdout.writeln('${ok ? "PASS" : "FAIL"}  $name\n        $detail');
    if (ok) {
      pass++;
    } else {
      fail++;
    }
  }

  // ---- Scenario 1: --expr-batch via bridge stdin, large stdin + response ----
  // 200 string-literal exprs: request body and response both well past the
  // ~8 KB Win anonymous-pipe threshold. Proves stdin write + stdout drain.
  {
    final exprs = <String>[
      for (var i = 0; i < 200; i++)
        '"PADDING_${i}_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"',
    ];
    final reqBytes = Uint8List.fromList(utf8.encode(jsonEncode({
      'headers': ['Ticker', 'Qty', 'Price'],
      'fields': ['AGNC', '2', '100.50'],
      'exprs': exprs,
    })));
    final reqFile = p.join(work, 's1_req.json');
    File(reqFile).writeAsBytesSync(reqBytes);

    final r = bridge.run(fmt, const ['--expr-batch'], stdin: reqBytes);
    final got = Uint8List.fromList(utf8.encode(r.stdout));

    // Ground truth: shell does the stdin+stdout redirect, no dart:io pipe.
    final gtFile = p.join(work, 's1_gt.json');
    final gtCode = _shellRedirect('"$fmt" --expr-batch < "$reqFile" > "$gtFile"');
    final gt = File(gtFile).readAsBytesSync();

    var nResults = -1;
    try {
      nResults = (jsonDecode(r.stdout)['results'] as List).length;
    } catch (_) {}

    check(
      '1 expr-batch via bridge stdin',
      r.exitCode == 0 && gtCode == 0 && _bytesEqual(got, gt) && nResults == exprs.length,
      'exit=${r.exitCode} stdin=${reqBytes.length}B resp=${got.length}B '
      'gt=${gt.length}B identical=${_bytesEqual(got, gt)} results=$nResults/${exprs.length}',
    );
  }

  // ---- Scenario 2: btrace streaming via bridge, full MB stream to exit 0 ----
  // DEV dry-run emits ~16 MB BXTB on stdout (incl. the 59 MB trading212
  // input). Streamed bytes must match shell ground truth byte-for-byte.
  {
    final gtFile = p.join(work, 's2_gt.bin');
    final gtCode = _shellRedirect(
      '"$cli" --config "$devCfg" --dry-run --trace=bin > "$gtFile"',
      cwd: devCwd,
    );
    final gt = File(gtFile).readAsBytesSync();

    final sink = File(p.join(work, 's2_bridge.bin')).openWrite();
    var total = 0;
    final firstBytes = <int>[];
    final sw = Stopwatch()..start();
    final exit = await bridge.runStreamingBinary(
      cli,
      ['--config', devCfg, '--dry-run', '--trace=bin'],
      cwd: devCwd,
      onChunk: (c) {
        total += c.length;
        sink.add(c);
        if (firstBytes.length < 4) firstBytes.addAll(c.take(4 - firstBytes.length));
      },
    );
    sw.stop();
    await sink.close();
    final got = File(p.join(work, 's2_bridge.bin')).readAsBytesSync();

    // BXTB magic 0x42545842 LE on the wire = bytes 'B','X','T','B'.
    final magic = firstBytes.length >= 4 &&
        firstBytes[0] == 0x42 && firstBytes[1] == 0x58 &&
        firstBytes[2] == 0x54 && firstBytes[3] == 0x42;
    check(
      '2 btrace streaming via bridge',
      exit == 0 && gtCode == 0 && magic && _bytesEqual(got, gt) && total > 1024 * kb,
      'exit=$exit bytes=$total gt=${gt.length}B identical=${_bytesEqual(got, gt)} '
      'magic=$magic elapsed=${sw.elapsedMilliseconds}ms',
    );
  }

  // ---- Scenario 3: cancel mid-stream via bridge_cancel ----
  // Re-run the same big dry-run; once >256 KB has streamed, cancel. The
  // 59 MB input guarantees the child is still running. Assert: cancel
  // accepted, future completes promptly (no hang), child did NOT exit 0,
  // and the stream stopped well before the full ~16 MB.
  {
    final fullSize = File(p.join(work, 's2_gt.bin')).lengthSync();
    var total = 0;
    int? handle;
    var cancelSignaled = false;
    final sw = Stopwatch()..start();
    final exit = await bridge
        .runStreamingBinary(
          cli,
          ['--config', devCfg, '--dry-run', '--trace=bin'],
          cwd: devCwd,
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
      '3 cancel mid-stream via bridge_cancel',
      cancelSignaled && exit != -999 && exit != 0 && total < fullSize,
      'cancelSignaled=$cancelSignaled exit=$exit bytesBeforeStop=$total '
      '(<full=$fullSize) elapsed=${sw.elapsedMilliseconds}ms no-hang=${exit != -999}',
    );
  }

  // ---- Scenario 4: --config large annotated output via bridge ----
  // DEV config is ~46 KB; annotated output (--check-fs=2) is larger still —
  // well past 8 KB. `--config` lacks the writeAllToStdoutPipeAware guard
  // that `--docs` has, so this confirms the bridge child's bxp-cli stdout drains
  // natively without truncation/panic. Must match shell ground truth.
  {
    final r = bridge.run(fmt, ['--config', devCfg, '--check-fs=2'], cwd: devCwd);
    final got = Uint8List.fromList(utf8.encode(r.stdout));
    File(p.join(work, 's4_bridge.json')).writeAsBytesSync(got);

    final gtFile = p.join(work, 's4_gt.json');
    final gtCode = _shellRedirect(
      '"$fmt" --config "$devCfg" --check-fs=2 > "$gtFile"',
      cwd: devCwd,
    );
    final gt = File(gtFile).readAsBytesSync();

    check(
      '4 --config large output via bridge',
      r.exitCode == 0 && gtCode == 0 && _bytesEqual(got, gt) && got.length > 16 * kb,
      'exit=${r.exitCode} resp=${got.length}B gt=${gt.length}B '
      'identical=${_bytesEqual(got, gt)}',
    );
  }

  stdout.writeln('');
  stdout.writeln('=== bridge smoke: $pass passed, $fail failed ===');
  exit(fail == 0 ? 0 : 1);
}

/// Run a command line through a generated `.bat` so the OS shell performs
/// the `>` / `<` redirects. The child's bytes go straight to/from the file,
/// never through dart:io's pipe layer — that is what makes the output a
/// trustworthy ground truth for the truncation comparison. A .bat avoids
/// `cmd /c "..."` outer-quote-stripping, which mangles command lines that
/// already contain quoted paths. Returns the child exit code.
var _batSeq = 0;
int _shellRedirect(String cmdline, {String? cwd}) {
  final bat = p.join(Directory.systemTemp.path, 'bxp-smoke-gt', 'gt_${_batSeq++}.bat');
  File(bat).writeAsStringSync('@echo off\r\n$cmdline\r\nexit /b %ERRORLEVEL%\r\n');
  final r = Process.runSync('cmd', ['/c', bat],
      workingDirectory: cwd, runInShell: false);
  return r.exitCode;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Walk up from CWD until we find the monorepo root (has bxp-core + bxp-gui-bridge).
String _findMonoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory(p.join(dir.path, 'bxp-core')).existsSync() &&
        Directory(p.join(dir.path, 'bxp-core')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('could not locate monorepo root from ${Directory.current.path}');
}
