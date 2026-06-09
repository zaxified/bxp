// Corpus validation gate — bridge runner.
//
// Walks `scripts/test-06-expr-corpus.txt` through `bridge_eval_expr` via FFI
// (BridgeClient.evalExpr) — the cross-platform editor validation path. Per
// corpus line, asserts the bridge verdict matches the corpus's expected
// outcome. A divergence means the bridge drifted from the shared
// `bxp-core/src/inspect.validateExpr` (over `bxp-core/src/expr.zig`) behaviour
// and must be fixed before ship.
//
// The validator core (`inspect.validateExpr`) is also gated through the MCP
// transport by `scripts/test-06-expr-corpus.sh` (bxp_validate_expr). This test
// covers the FFI transport: a shell-only check would never catch a JSON
// serialisation regression in the bridge's `writeStaticErrorJson` /
// `writeExprErrorJson`.

import 'dart:io';

import 'package:bxp_gui/services/bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  // The corpus and bridge .so live at known locations relative to the monorepo
  // root. Resolve once.
  late final String monoRoot;
  late final String corpusPath;
  late final String bridgePath;
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

    expect(File(corpusPath).existsSync(), isTrue,
        reason: 'corpus missing at $corpusPath');
    expect(File(bridgePath).existsSync(), isTrue,
        reason: 'bridge library missing at $bridgePath — run '
            '`cd bxp-gui-bridge && zig build` first');

    bridge = BridgeClient(bridgePath);
  });

  test('corpus validation — bridge_eval_expr vs expected outcome', () {
    final entries = _parseCorpus(corpusPath);
    expect(entries, isNotEmpty, reason: 'corpus parsed empty');

    final divergences = <String>[];

    for (final e in entries) {
      final bridgeRes = bridge.evalExpr(e.expr);
      final bridgeErr = _stripDetailSuffix(bridgeRes.error);

      switch (e.kind) {
        case _Outcome.ok:
          if (bridgeErr != null) {
            divergences.add(
              'EXPECTED ok: "${e.expr}" → bridge returned ${_q(bridgeErr)}',
            );
          }
          break;
        case _Outcome.err:
          if (bridgeErr == null) {
            divergences.add(
              'EXPECTED err(${e.reason}): "${e.expr}" → bridge returned ok',
            );
          } else if (e.reason != null && bridgeErr != e.reason) {
            divergences.add(
              'EXPECTED err(${e.reason}): "${e.expr}" → bridge returned ${_q(bridgeErr)}',
            );
          }
          break;
      }
    }

    expect(divergences, isEmpty,
        reason:
            'Corpus validation failures (${divergences.length} of ${entries.length}):\n  '
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

/// BridgeClient.evalExpr returns `'<ErrorName>: <detail>'` when detail is
/// present; the corpus reason column is just `<ErrorName>`. Strip the suffix so
/// the two are comparable.
String? _stripDetailSuffix(String? combined) {
  if (combined == null || combined.isEmpty) return null;
  final colon = combined.indexOf(':');
  return colon < 0 ? combined : combined.substring(0, colon);
}

String _q(String? s) => s == null ? 'ok' : "err($s)";
