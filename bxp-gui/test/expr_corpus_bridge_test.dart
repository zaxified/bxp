// Cross-runner corpus parity gate.
//
// Walks `scripts/test-06-expr-corpus.txt` through both expression
// evaluators that ship in bxp-gui:
//   1. `bridge_eval_expr` via FFI (BridgeClient.evalExpr) — primary
//      cross-platform editor path since 2026-05-11.
//   2. `bxp-fmt --expr` subprocess — fallback path, also exercised by
//      `scripts/test-06-expr-corpus.sh`.
//
// Per corpus line, asserts both runners agree with each other AND with
// the corpus's expected outcome. A divergence between the two means
// either bridge or bxp-fmt drifted from the shared `bxp-core/src/expr.zig`
// behaviour and must be fixed before ship.
//
// The test is intentionally Dart-side (not pure shell) so the FFI
// boundary itself is exercised; a shell-only check would never catch a
// JSON serialisation regression in `writeStaticErrorJson` /
// `writeExprErrorJson`.

import 'dart:convert';
import 'dart:io';

import 'package:bxp_gui/services/bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  // The corpus, bridge .so, and bxp-fmt binary all live at known
  // locations relative to the monorepo root. Resolve once.
  late final String monoRoot;
  late final String corpusPath;
  late final String bridgePath;
  late final String bxpFmtPath;
  late final BridgeClient bridge;

  setUpAll(() {
    monoRoot = _findMonoRoot();
    corpusPath = p.join(monoRoot, 'scripts', 'test-06-expr-corpus.txt');
    // Zig emits the shared library under zig-out/bin on Windows (DLL
    // convention) and zig-out/lib on POSIX (.so/.dylib) — mirror
    // findBridgeLibrary()'s platform-aware probe so the test runs on
    // every host (the planned CI-hardening flutter run includes Windows).
    bridgePath = Platform.isWindows
        ? p.join(monoRoot, 'bxp-gui-bridge', 'zig-out', 'bin',
            'bxp-gui-bridge.dll')
        : p.join(
            monoRoot,
            'bxp-gui-bridge',
            'zig-out',
            'lib',
            Platform.isMacOS
                ? 'libbxp-gui-bridge.dylib'
                : 'libbxp-gui-bridge.so',
          );
    final exe = Platform.isWindows ? '.exe' : '';
    bxpFmtPath = p.join(monoRoot, 'bxp-fmt', 'zig-out', 'bin', 'bxp-fmt$exe');

    expect(File(corpusPath).existsSync(), isTrue,
        reason: 'corpus missing at $corpusPath');
    expect(File(bridgePath).existsSync(), isTrue,
        reason: 'bridge library missing at $bridgePath — run '
            '`cd bxp-gui-bridge && zig build` first');
    expect(File(bxpFmtPath).existsSync(), isTrue,
        reason: 'bxp-fmt missing at $bxpFmtPath — run '
            '`cd bxp-fmt && zig build` first');

    bridge = BridgeClient(bridgePath);
  });

  test('corpus parity — bridge_eval_expr vs bxp-fmt --expr', () {
    final entries = _parseCorpus(corpusPath);
    expect(entries, isNotEmpty, reason: 'corpus parsed empty');

    final divergences = <String>[];

    for (final e in entries) {
      // Bridge result.
      final bridgeRes = bridge.evalExpr(e.expr);
      final bridgeErr = _stripDetailSuffix(bridgeRes.error);

      // bxp-fmt subprocess result.
      final fmtResult = Process.runSync(bxpFmtPath, ['--expr', e.expr]);
      final fmtErr = _extractFmtErrorName(fmtResult);

      // Cross-runner agreement is the primary gate.
      if (bridgeErr != fmtErr) {
        divergences.add(
          'PARITY: "${e.expr}" → bridge=${_q(bridgeErr)} fmt=${_q(fmtErr)}',
        );
        continue;
      }

      // Both runners agreed; now check against the corpus expectation.
      switch (e.kind) {
        case _Outcome.ok:
          if (bridgeErr != null) {
            divergences.add(
              'EXPECTED ok: "${e.expr}" → both runners returned ${_q(bridgeErr)}',
            );
          }
          break;
        case _Outcome.err:
          if (bridgeErr == null) {
            divergences.add(
              'EXPECTED err(${e.reason}): "${e.expr}" → both runners returned ok',
            );
          } else if (e.reason != null && bridgeErr != e.reason) {
            divergences.add(
              'EXPECTED err(${e.reason}): "${e.expr}" → both runners returned ${_q(bridgeErr)}',
            );
          }
          break;
      }
    }

    expect(divergences, isEmpty,
        reason:
            'Corpus parity failures (${divergences.length} of ${entries.length}):\n  '
            '${divergences.join('\n  ')}');
  });
}

// ── Helpers ─────────────────────────────────────────────────────────────

enum _Outcome { ok, err }

class _CorpusEntry {
  final _Outcome kind;
  final String expr;
  final String? reason;
  const _CorpusEntry(this.kind, this.expr, this.reason);
}

/// Walk up from CWD until we find a directory that contains both
/// `bxp-gui-bridge/` and `scripts/`. Test process CWD is typically
/// `bxp-gui/` when run via `flutter test`.
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
  throw StateError(
    'Could not locate monorepo root from ${Directory.current.path} — '
    'expected to find sibling bxp-gui-bridge/ and scripts/ within 10 levels',
  );
}

List<_CorpusEntry> _parseCorpus(String path) {
  final out = <_CorpusEntry>[];
  for (final raw in File(path).readAsLinesSync()) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) continue;
    final parts = line.split('\t');
    if (parts.length < 3) continue;
    if (parts[0] != 'expr') continue;
    switch (parts[1]) {
      case 'ok':
        out.add(_CorpusEntry(_Outcome.ok, parts[2], null));
        break;
      case 'err':
        final reason = parts.length >= 4 && parts[3].isNotEmpty
            ? parts[3]
            : null;
        out.add(_CorpusEntry(_Outcome.err, parts[2], reason));
        break;
    }
  }
  return out;
}

/// BridgeClient.evalExpr returns `'<ErrorName>: <detail>'` when detail
/// is present; the subprocess JSON gives just `<ErrorName>`. Strip the
/// suffix so the two are comparable.
String? _stripDetailSuffix(String? combined) {
  if (combined == null || combined.isEmpty) return null;
  final colon = combined.indexOf(':');
  return colon < 0 ? combined : combined.substring(0, colon);
}

/// `bxp-fmt --expr` writes `{"error":"<Name>","detail":"...",...}` to
/// stderr on failure (exit=1) and nothing on success (exit=0).
String? _extractFmtErrorName(ProcessResult r) {
  if (r.exitCode == 0) return null;
  final stderr = (r.stderr as String).trim();
  if (stderr.isEmpty) return 'subprocess: empty stderr';
  try {
    final obj = jsonDecode(stderr.split('\n').last);
    if (obj is Map && obj['error'] is String) return obj['error'] as String;
  } catch (_) {
    // fall through to wrapper
  }
  return 'subprocess: malformed stderr';
}

String _q(String? s) => s == null ? 'ok' : "err($s)";
