import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../store/trace_model.dart';
import 'bridge_client.dart';
import 'dev_trace.dart';
import 'diagnostic_log.dart';

/// Spawn-based client for `bxp-cli` and `bxp-fmt`.
///
/// Every call is a short-lived sub-process. `--trace` runs stream stdout
/// line by line (one NDJSON event per line); validation calls capture
/// stdout in full. The old FFI path (zig/bxp-ffi, a separate shared
/// library re-exporting bxp-core) was deleted — keeping a parallel
/// binding duplicated maintenance with zero UX upside now that
/// validateExpr is debounced asynchronously.
class BxpProcessClient {
  /// Resolve a sibling binary. Search order:
  ///   1. Env override: `$BXP_CLI_PATH` / `$BXP_FMT_PATH`
  ///      — when SET (non-empty), this wins absolutely. If the path doesn't
  ///        exist we return null instead of falling through to the other
  ///        candidate: the user explicitly pinned this path and silently
  ///        running a different binary is worse than showing a fatal error.
  ///   2. `<name>` next to the bxp_gui executable.
  ///   3. Dev-tree fallback: when the GUI is launched from a build directory
  ///      inside the monorepo (e.g. `bxp-gui/build/linux/x64/debug/bundle`),
  ///      walk up to find `bxp/<sibling-package>/zig-out/bin/<name>`. This
  ///      lets `flutter run` work without copying/symlinking binaries every
  ///      time the bundle is wiped by an install rebuild.
  ///
  /// Platform-aware binary filename: appends `.exe` on Windows, leaves
  /// other platforms untouched. The release packager copies bxp-cli /
  /// bxp-fmt as `*.exe` into the Windows bundle (release-02-desktop.sh),
  /// so a bare 'bxp-fmt' lookup misses on disk and the GUI used to bail
  /// out at startup with the misleading message
  /// `same directory as bxp_gui = C:\Program Files\BXP/bxp-fmt`.
  static String binaryFileName(String name) =>
      Platform.isWindows ? '$name.exe' : name;

  /// Returns null when no candidate exists on disk.
  static String? findBin(String name) {
    final envVar = switch (name) {
      'bxp-cli' => Platform.environment['BXP_CLI_PATH'],
      'bxp-fmt' => Platform.environment['BXP_FMT_PATH'],
      _ => null,
    };
    if (envVar != null && envVar.isNotEmpty) {
      if (File(envVar).existsSync()) return envVar;
      // Fail loud: the user explicitly pinned this path. Silently falling
      // through to the bundle/dev-tree binary is exactly the failure mode
      // the override exists to prevent. Surface via devTrace so the
      // "(unknown)" / "binary not found" UI state has an explanation in
      // the logs.
      devTrace('findBin.envOverrideMissing',
          {'name': name, 'path': envVar});
      return null;
    }

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sibling = p.join(exeDir, binaryFileName(name));
    if (File(sibling).existsSync()) return sibling;

    // Walk up looking for a `bxp-gui/` directory; its parent is the monorepo
    // root that holds sibling packages `bxp-cli/` and `bxp-fmt/`. Use
    // `p.basename` so the segment compare works on both POSIX (`/`) and
    // Windows (`\`) — `endsWith('/bxp-gui')` would silently miss on
    // Windows and could mismatch a path like `/foo/some-bxp-gui` on
    // POSIX.
    Directory dir = Directory(exeDir);
    for (int i = 0; i < 10; i++) {
      final parent = dir.parent;
      if (parent.path == dir.path) break; // reached filesystem root
      if (p.basename(dir.path) == 'bxp-gui') {
        final candidate =
            p.join(parent.path, name, 'zig-out', 'bin', binaryFileName(name));
        if (File(candidate).existsSync()) return candidate;
        break;
      }
      dir = parent;
    }

    return null;
  }

  // ── One-shot invocations (stdout captured) ─────────────────────────────

  /// Per-call timeouts. A hung child (deadlock, missing-stdin wait, broken
  /// pipe loop) used to freeze the GUI forever — every call below now
  /// surfaces a synthetic non-zero exit code after these durations and
  /// SIGTERMs the child to keep it from leaking. Numbers chosen to be
  /// generous on the slowest realistic input we've seen and still way
  /// shorter than "user gives up and quits the app".
  ///
  /// Note: timeouts also wrap the bridge worker isolate via
  /// `Future.timeout` — if a child invoked through the bridge hangs the
  /// main isolate sees the timeout and falls through. The worker
  /// isolate technically leaks until the OS process exits, which is
  /// fine because bxp-fmt one-shot calls don't hang in practice.
  static const Duration _versionTimeout = Duration(seconds: 5);
  static const Duration _docsTimeout = Duration(seconds: 5);
  static const Duration _exprTimeout = Duration(seconds: 15);
  static const Duration _configTimeout = Duration(seconds: 15);
  static const Duration _listTemplatesTimeout = Duration(seconds: 30);

  /// Cached path to the bridge DLL — null when unavailable (non-Windows,
  /// missing file, probe failed). Resolved once via [_resolveBridgePath]
  /// so we don't re-stat the filesystem on every call. The DLL itself
  /// gets opened freshly inside each worker isolate; we don't keep a
  /// long-lived BridgeClient on the main isolate because all FFI work
  /// must happen off the UI thread (see [_runOneShot]).
  static String? _bridgeDllPath;
  static String? _bridgeVersion;
  static bool _bridgeProbed = false;

  /// DLL self-reported version, populated on first call to
  /// [_resolveBridgePath]. Null until the probe runs (which any
  /// `findBin` / `loadConfig` / `runDryRun` call triggers via
  /// [_runOneShot] / [_runCliTrace]). Surfaced in the
  /// SettingsInspector so a reporter can confirm which bridge build
  /// the GUI is talking to.
  static String? get bridgeVersion => _bridgeVersion;

  /// Cached path of the bridge DLL after a successful probe. Mainly a
  /// diagnostic surface — the SettingsInspector renders it next to
  /// [bridgeVersion] so both endpoints of the FFI pair are visible
  /// when triaging "is the GUI using a stale DLL?" reports.
  static String? get bridgeDllPath => _bridgeDllPath;

  /// Pre-release smoke gate: setting `BXP_FORCE_BRIDGE_PROXY=1` in the
  /// environment opts Linux / macOS dev runs into the bridge subprocess
  /// proxy path (same route Windows always takes), so we can validate
  /// the cross-platform bridge build before shipping it. The flag is
  /// intentionally cumbersome to enable (env var, not a checkbox) — it's
  /// a developer testing knob, not a user-facing toggle. Drop this gate
  /// once the bridge proxy is exercised on Linux/macOS via production
  /// traffic.
  static bool _forceBridgeProxy() =>
      Platform.environment['BXP_FORCE_BRIDGE_PROXY'] == '1';

  static String? _resolveBridgePath() {
    if (_bridgeProbed) return _bridgeDllPath;
    _bridgeProbed = true;
    if (!Platform.isWindows && !_forceBridgeProxy()) return null;
    final dllPath = findBridgeLibrary();
    if (dllPath == null) {
      _lastSubprocessDiag = 'bridge: DLL not found next to bxp-gui';
      return null;
    }
    // One-time probe: load the DLL on the main isolate just to confirm
    // it's loadable and read its version string for diagnostics. The
    // BridgeClient itself is discarded — every actual call is handled
    // by a worker isolate that re-opens the DLL on its own side.
    try {
      final probe = BridgeClient(dllPath);
      _bridgeVersion = probe.bridgeVersion;
      _bridgeDllPath = dllPath;
      return dllPath;
    } catch (e) {
      _lastSubprocessDiag = 'bridge: probe failed: $e';
      return null;
    }
  }

  /// Long-lived [BridgeClient] dedicated to the in-process expression
  /// family (`bridge_eval_expr` / `bridge_eval_expr_trace`). Unlike the
  /// subprocess-proxy path that re-opens the DLL inside each
  /// [Isolate.run] worker, the eval calls are sub-ms and run direct on
  /// the main isolate — keeping one cached client avoids paying the
  /// `DynamicLibrary.open` cost per keystroke.
  ///
  /// Probed independently from [_resolveBridgePath] because the eval
  /// family is intended to land on Linux/macOS too (once the build
  /// pipeline ships the `.so`/`.dylib` alongside the GUI bundle), while
  /// the subprocess proxy stays Win-only. Returns null when the library
  /// can't be located — callers fall back to subprocess.
  static BridgeClient? _evalBridgeClient;
  static bool _evalBridgeProbed = false;

  /// Probe + cache the eval-bridge client. Deliberately does NOT touch
  /// `_bridgeDllPath` — that cache is reserved for the subprocess-proxy
  /// path (Win mandatory + `BXP_FORCE_BRIDGE_PROXY` smoke). Mixing them
  /// caused a Linux crash when `_runCliTrace`'s routing saw a non-null
  /// `_bridgeDllPath` without the env var being set, and tried to route
  /// dry-run through the untested cross-platform proxy code.
  static BridgeClient? _resolveEvalBridgeClient() {
    if (_evalBridgeProbed) return _evalBridgeClient;
    _evalBridgeProbed = true;
    final libPath = findBridgeLibrary();
    if (libPath == null) return null;
    try {
      _evalBridgeClient = BridgeClient(libPath);
      // Mirror the bridge version into the shared `_bridgeVersion`
      // getter (used by SettingsInspector) only if the proxy probe
      // didn't already populate it. The path itself stays out of
      // `_bridgeDllPath` to keep proxy routing predictable.
      _bridgeVersion ??= _evalBridgeClient!.bridgeVersion;
      return _evalBridgeClient;
    } catch (e) {
      _lastSubprocessDiag = 'bridge: eval probe failed: $e';
      return null;
    }
  }

  /// One-shot run. On Windows the FFI bridge is the only path — the DLL
  /// is mandatory; if probe failed we surface a synthetic error result
  /// rather than falling back to dart:io's Process pipes (which would
  /// silently truncate `--docs` / `--config` over the ~8 KB Win pipe
  /// limit, dart-lang/sdk#1727). On Linux / macOS the bridge is dormant
  /// and everything goes through [_runWithTimeout].
  ///
  /// Why a worker isolate: `bridge_run` is synchronous and blocks for
  /// the duration of the child process (50–200 ms typical). Running it
  /// on the main isolate freezes Flutter's frame loop and back-pressure
  /// from queued mouse / keyboard events causes the GUI to stop
  /// responding after a handful of fast hovers. `Isolate.run` offloads
  /// the blocking call to a fresh worker isolate so the UI stays smooth.
  /// The ~5 ms isolate-spawn overhead is negligible compared to the
  /// pipe-drain time we're already paying.
  static Future<ProcessResult> _runOneShot(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    final dllPath = _resolveBridgePath();
    if (Platform.isWindows) {
      if (dllPath == null) {
        // Bridge probe failed at startup — `_lastSubprocessDiag` already
        // describes why. Surface a synthetic non-zero exit so callers
        // hit their existing error-rendering path; no Process.start
        // fallback because dart:io can't be trusted with bxp-fmt's
        // output volume on Windows.
        return ProcessResult(
          0, 1, '',
          'bridge: ${_lastSubprocessDiag ?? "DLL unavailable"}',
        );
      }
      return _runOneShotViaBridge(dllPath, executable, arguments, timeout);
    }
    // Non-Windows: by default dart:io's pipes work, so we stay on
    // Process.start. The pre-release smoke gate (`BXP_FORCE_BRIDGE_PROXY=1`)
    // routes through bridge_run instead to validate the cross-platform
    // bridge build. Gate explicitly on the env var rather than `dllPath`
    // alone — `_resolveEvalBridgeClient` (in-process expr family) also
    // populates `_bridgeDllPath` on all platforms, so a non-null path
    // doesn't imply the user asked for the proxy smoke.
    if (_forceBridgeProxy() && dllPath != null) {
      return _runOneShotViaBridge(dllPath, executable, arguments, timeout);
    }
    return _runWithTimeout(executable, arguments, timeout);
  }

  /// Bridge variant of [_runOneShot]. Hard error on any failure — no
  /// fallback. Wraps [BridgeClient.run] in `Isolate.run` so the
  /// blocking pipe drain doesn't stall the main isolate's frame loop.
  static Future<ProcessResult> _runOneShotViaBridge(
    String dllPath,
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    try {
      final result = await Isolate.run(
        () => _bridgeRunInIsolate(dllPath, executable, arguments),
      ).timeout(timeout);
      if (result.err != null) {
        _lastSubprocessDiag = 'bridge $_bridgeVersion: err=${result.err}';
        return ProcessResult(0, 1, '', 'bridge: ${result.err}');
      }
      _lastSubprocessDiag = 'bridge $_bridgeVersion: '
          'exit ${result.exitCode}, stdout=${result.stdout.length} B'
          ', stderr=${result.stderr.length} B';
      return ProcessResult(
        0,
        result.exitCode,
        result.stdout,
        result.stderr,
      );
    } on TimeoutException {
      _lastSubprocessDiag =
          'bridge $_bridgeVersion: timeout after ${timeout.inSeconds}s';
      return ProcessResult(
        0,
        ProcessRunResult.kExitTimeout,
        '',
        '$executable timed out after ${timeout.inSeconds}s (bridge)',
      );
    } catch (e) {
      // Worker-side exception (bad DLL, OOM allocating the response
      // buffer, …). No fallback — the bridge is the only sanctioned
      // path on Windows. Surface the failure.
      _lastSubprocessDiag = 'bridge $_bridgeVersion: ${e.runtimeType} $e';
      return ProcessResult(
        0, 1, '',
        'bridge ${e.runtimeType}: $e',
      );
    }
  }

  /// `Process.run` + per-call timeout + child-process kill on timeout.
  ///
  /// A naive `Process.run(...).timeout(...)` would leave the child running
  /// in the background after the Future resolves — so we spawn manually,
  /// drain both streams, race the exitCode against the timeout, and kill
  /// the child if it didn't finish. On timeout we synthesise a
  /// `ProcessResult` whose stderr explains what happened so the caller's
  /// existing error-rendering path picks it up unchanged.
  /// Diagnostic trace of the most recent _runWithTimeout fallback chain.
  /// Captures whether the direct call succeeded or whether we had to
  /// retry through the OS shell. Surfaced in fatal startup messages and
  /// the SettingsInspector so a Windows bug reporter can paste the
  /// concrete failure mode instead of "didn't work".
  static String? _lastSubprocessDiag;
  static String? get lastSubprocessDiag => _lastSubprocessDiag;

  static Future<ProcessResult> _runWithTimeout(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    // Three-attempt diagnostic chain (direct → runInShell → Process.run)
    // exists for the dart-lang/sdk#1727 spawn-vs-attach race that makes
    // bxp-fmt's --docs output (~30 KB) trip its own WriteFailed before
    // Dart's stream listener attaches. The race is Windows-only — Linux
    // pipe buffers are ~64 KB and macOS isn't affected. On those hosts
    // a tool like bxp-fmt that legitimately exits 1 with stdout (config
    // validation errors) would triple-run for no benefit, so the retry
    // chain is gated on Platform.isWindows. Windows production is the
    // bridge path anyway; this fallback only executes if the bridge DLL
    // isn't loadable, in which case the retries are a worthwhile last
    // resort before surfacing a hard failure.
    String describe(String tag, ProcessResult r) {
      final out = r.stdout as String;
      final err = (r.stderr as String).trim();
      return '$tag: exit ${r.exitCode}, stdout=${out.length} B'
          ', stderr=${err.length} B'
          '${err.isEmpty ? '' : ' "${_peek(err)}"'}';
    }
    final r1 = await _runOnce(executable, arguments, timeout, runInShell: false);
    if (!Platform.isWindows) {
      _lastSubprocessDiag = describe('direct', r1);
      return r1;
    }
    if (r1.exitCode == 0) {
      _lastSubprocessDiag = describe('direct', r1);
      return r1;
    }
    final diag1 = describe('direct', r1);
    final r2 = await _runOnce(executable, arguments, timeout, runInShell: true);
    if (r2.exitCode == 0) {
      _lastSubprocessDiag = '$diag1\n  ${describe('shell', r2)}';
      return r2;
    }
    final diag2 = describe('shell', r2);
    // Attempt 3: Dart's built-in Process.run, which drains pipes in
    // dart:io's native (C++) code without depending on the Dart event
    // loop attaching a listener. If the failure mode in attempts 1+2
    // really is the dart-lang/sdk#1727 spawn-vs-attach race, this path
    // sidesteps it entirely. We give up kill control here, but for
    // single-shot calls a stuck child is bounded by the Future.timeout.
    try {
      final r3 = await Process.run(executable, arguments).timeout(timeout);
      _lastSubprocessDiag = '$diag1\n  $diag2\n  ${describe('processRun', r3)}';
      return r3;
    } on TimeoutException {
      _lastSubprocessDiag =
          '$diag1\n  $diag2\n  processRun: timeout after ${timeout.inSeconds}s';
      return ProcessResult(
        0,
        ProcessRunResult.kExitTimeout,
        '',
        '$executable timed out after ${timeout.inSeconds}s',
      );
    }
  }

  static Future<ProcessResult> _runOnce(
    String executable,
    List<String> arguments,
    Duration timeout, {
    required bool runInShell,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      runInShell: runInShell,
    );
    // Subscribe to both streams BEFORE any further await. On Windows the
    // anonymous-pipe buffer is only ~4 KB, so a child that writes more
    // than that (e.g. `--docs` emits ~30 KB of JSON) blocks on WriteFile
    // until the parent drains. `.transform(utf8.decoder).join()` returns
    // a Future whose listener subscription is delayed by an event-loop
    // tick; if Flutter's startup work fills that tick the child trips
    // its own flush and exits with `error: WriteFailed` (exit 1) before
    // we even reach the timeout. `Stream.listen` attaches synchronously
    // so the OS pipe is drained from the first byte.
    final stdoutChunks = <List<int>>[];
    final stderrChunks = <List<int>>[];
    final stdoutSub = process.stdout.listen(stdoutChunks.add);
    final stderrSub = process.stderr.listen(stderrChunks.add);
    String decode(List<List<int>> chunks) =>
        utf8.decode(chunks.expand((b) => b).toList(), allowMalformed: true);
    // Yield one event-loop tick after exit so the listener's onData
    // callbacks dispatch any chunks that landed in the OS pipe just
    // before the child exited. We can't use `subscription.asFuture()` /
    // `onDone` to wait for stream completion: on Windows the Stream
    // backing `Process.stdout` doesn't reliably fire onDone after child
    // exit (dart-lang/sdk#1727 has been open since 2012), so awaiting
    // it would hang the call indefinitely.
    Future<ProcessResult> finish(int exitCode, {String? extraStderr}) async {
      await Future<void>.delayed(Duration.zero);
      await stdoutSub.cancel();
      await stderrSub.cancel();
      final stdoutText = decode(stdoutChunks);
      final stderrText = decode(stderrChunks);
      return ProcessResult(
        process.pid,
        exitCode,
        stdoutText,
        extraStderr == null
            ? stderrText
            : (stderrText.isEmpty ? extraStderr : '$stderrText\n$extraStderr'),
      );
    }
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return await finish(exitCode);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      // Best-effort drain: if the child ignores SIGTERM, escalate to
      // SIGKILL after a short grace window so we don't wait forever.
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        try { await process.exitCode; } catch (_) {}
      }
      return await finish(
        ProcessRunResult.kExitTimeout,
        extraStderr: '$executable timed out after ${timeout.inSeconds}s',
      );
    }
  }

  /// Validates config via `bxp-fmt --config <path>`.
  /// Returns stdout (annotated JSON) on exit 0, throws on missing binary.
  /// Non-zero exit with stderr is returned wrapped in `{"error": "..."}`.
  ///
  /// [checkFsSeconds] controls bxp-fmt's optional FS validation pass:
  /// 0 (default) skips it entirely, >0 enables it with that many seconds
  /// total deadline. The TraceStore flips to 0 for the rest of the
  /// session if a previous call surfaced an `[fs.timeout]` warning.
  static Future<String> loadConfig(String path, {int checkFsSeconds = 0}) async {
    final endAction = DiagnosticLog.action('loadConfig', {
      'path': path,
      'check_fs': checkFsSeconds,
    });
    final bin = findBin('bxp-fmt');
    if (bin == null) {
      endAction({'result': 'binary_missing'});
      return '{"error": "bxp-fmt binary not found"}';
    }
    final args = checkFsSeconds > 0
        ? ['--config', path, '--check-fs=$checkFsSeconds']
        : ['--config', path];
    final result = await _runOneShot(bin, args, _configTimeout);
    if (result.exitCode == 0) {
      endAction({
        'exit': 0,
        'stdout_bytes': (result.stdout as String).length,
      });
      return result.stdout as String;
    }
    // Exit 1 = validation failure; bxp-fmt still emits annotated JSON with $err_ nodes.
    if ((result.stdout as String).isNotEmpty) {
      endAction({
        'exit': result.exitCode,
        'stdout_bytes': (result.stdout as String).length,
      });
      return result.stdout as String;
    }
    final err = (result.stderr as String).trim();
    endAction({'exit': result.exitCode, 'stderr': err});
    return '{"error": ${jsonEncode(err.isEmpty ? "unknown error" : err)}}';
  }

  /// Probe a sibling binary for its version string via `<bin> --version`.
  /// Both bxp-cli and bxp-fmt print `"<name> <version>\n"` (the version is
  /// injected from `build.zig.zon` via `build_options.version`), so we keep
  /// just the trailing token. Returns null when the binary is missing or
  /// the call fails — callers render that as "(unknown)".
  static Future<String?> getVersion(String name) async {
    final bin = findBin(name);
    if (bin == null) return null;
    try {
      final result =
          await _runOneShot(bin, ['--version'], _versionTimeout);
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim();
      if (out.isEmpty) return null;
      final parts = out.split(RegExp(r'\s+'));
      return parts.length >= 2 ? parts.last : out;
    } catch (_) {
      return null;
    }
  }

  /// Fetch the canonical function/keyword/operator/token/config-schema
  /// catalog from `bxp-fmt --docs`. Returns the parsed JSON tree, or
  /// null if the binary is missing or returns garbage. Single-source-of-
  /// truth contract: tree tooltips, expression catalog, and autocomplete
  /// all read from the same data the CLI itself ships.
  static Future<Map<String, dynamic>?> getDocs() async {
    final bin = findBin('bxp-fmt');
    if (bin == null) return null;
    try {
      final result = await _runOneShot(bin, ['--docs'], _docsTimeout);
      if (result.exitCode != 0) {
        _lastDocsError = 'exit code ${result.exitCode}; '
            'stderr: ${_peek(result.stderr as String)}';
        return null;
      }
      final out = (result.stdout as String).trim();
      if (out.isEmpty) {
        _lastDocsError = 'stdout was empty; '
            'stderr: ${_peek(result.stderr as String)}';
        return null;
      }
      try {
        final parsed = jsonDecode(out);
        if (parsed is Map<String, dynamic>) return parsed;
        _lastDocsError = 'parsed JSON is ${parsed.runtimeType}, expected a Map; '
            'stdout starts with: ${_peek(out)}';
        return null;
      } on FormatException catch (e) {
        _lastDocsError = 'jsonDecode failed: ${e.message}; '
            'stdout (${out.length} bytes) starts with: ${_peek(out)}';
        return null;
      }
    } catch (e) {
      _lastDocsError = 'exception: $e';
      return null;
    }
  }

  /// Diagnostic detail captured on the most recent [getDocs] failure.
  /// Surfaced in `trace_store._fatalStartupError` so the user-facing
  /// "bxp-fmt --docs failed" screen can name the actual failure mode
  /// (timeout, non-zero exit, JSON parse error, ...) instead of a
  /// generic "no parseable JSON" message that gives the bug reporter
  /// nothing to work with.
  static String? _lastDocsError;
  static String? get lastDocsError => _lastDocsError;

  /// First [n] characters of [s], with a tail indicator when truncated.
  /// Used for diagnostic snippets in [_lastDocsError] — keeps the fatal
  /// error screen readable even when the binary returns megabytes of
  /// garbage.
  static String _peek(String s, {int n = 200}) =>
      s.length <= n ? s : '${s.substring(0, n)}... (+${s.length - n} more)';

  /// Enumerates conversion templates declared in a config via
  /// `bxp-fmt --config <path> --list-templates`. Returns an empty list when
  /// the binary is missing or the call fails — the caller falls back to its
  /// own enumeration of `configJson['conversion_templates']` keys, so a
  /// failure here only loses the metadata (data_dir / file_pattern_in /
  /// description) that powers the richer template-selector subtitle.
  static Future<List<TemplateInfo>> listTemplates(String path) async {
    final bin = findBin('bxp-fmt');
    if (bin == null) return const [];
    try {
      final result = await _runOneShot(
        bin,
        ['--config', path, '--list-templates'],
        _listTemplatesTimeout,
      );
      if (result.exitCode != 0) return const [];
      final out = (result.stdout as String).trim();
      if (out.isEmpty) return const [];
      final parsed = jsonDecode(out);
      if (parsed is! Map) return const [];
      final list = parsed['templates'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((e) => TemplateInfo.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Validates a single expression via `bxp-fmt --expr <text>`.
  /// Validate an expression via `bxp-fmt --expr`. Returns a record
  /// with `error` (null on success), and optional `offset` / `length`
  /// for token highlighting (Phase G1).
  ///
  /// `bxp-fmt --expr` emits a structured
  /// `{"error":"X","detail":"Y","off":N,"len":M}` on failure. We
  /// unwrap that into `"X: Y"` (or just `"X"` when detail is empty).
  static Future<({String? error, int? offset, int? length})> validateExpr(
    String expr,
  ) async {
    if (expr.isEmpty) return (error: null, offset: null, length: null);
    // Prefer the in-process FFI path when the bridge library is loadable.
    // Sub-ms latency vs ~50 ms spawn of `bxp-fmt --expr`. Sync FFI call
    // is safe on the main isolate (well under one frame budget).
    final evalClient = _resolveEvalBridgeClient();
    if (evalClient != null) {
      DiagnosticLog.log('action.validateExpr', {'len': expr.length, 'path': 'bridge'});
      return evalClient.evalExpr(expr);
    }
    final bin = findBin('bxp-fmt');
    if (bin == null) return (error: 'bxp-fmt not found', offset: null, length: null);
    DiagnosticLog.log('action.validateExpr', {'len': expr.length, 'path': 'subprocess'});
    final result =
        await _runOneShot(bin, ['--expr', expr], _exprTimeout);
    if (result.exitCode == 0) return (error: null, offset: null, length: null);
    final stdout = (result.stdout as String).trim();
    final stderr = (result.stderr as String).trim();
    final raw = stdout.isNotEmpty ? stdout : stderr;
    if (raw.isEmpty) return (error: 'invalid expression', offset: null, length: null);
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        final err = m['error'];
        final detail = m['detail'];
        final off = m['off'];
        final len = m['len'];
        final offset = off is int ? off : null;
        final length = len is int ? len : null;
        if (err is String && err.isNotEmpty) {
          final msg = (detail is String && detail.isNotEmpty)
              ? '$err: $detail'
              : err;
          return (error: msg, offset: offset, length: length);
        }
      }
    } catch (_) {
      // Not JSON — fall through to the raw text.
    }
    return (error: raw, offset: null, length: null);
  }

  /// Re-evaluates an expression against a CSV row context and returns the
  /// per-function-call NDJSON stream from `bxp-fmt --expr-trace`. Used by
  /// the GUI's hover-on-token feature to surface intermediate values for
  /// nested function calls (`ABS([Fee])` → "1.50") without re-running the
  /// whole pipeline.
  ///
  /// Returns the parsed call list. An empty list means the expression had
  /// no function calls or the spawn failed — the hover layer treats both
  /// the same (fall back to docs-only tooltip).
  static Future<List<ExprCallTrace>> traceExpr({
    required String expr,
    required List<String> headers,
    required List<String> fields,
  }) async {
    // Prefer in-process FFI when available. The trace NDJSON shape is
    // identical to `bxp-fmt --expr-trace` stdout so the per-line parser
    // below works on both payloads.
    final evalClient = _resolveEvalBridgeClient();
    if (evalClient != null) {
      final ndjson =
          evalClient.evalExprTrace(text: expr, headers: headers, fields: fields);
      if (ndjson != null) return _parseTraceNdjson(ndjson);
      // null = bridge-level failure → fall through to subprocess
    }
    final bin = findBin('bxp-fmt');
    if (bin == null) return const [];
    try {
      final result = await _runOneShot(
        bin,
        [
          '--expr-trace', expr,
          '--row-headers', jsonEncode(headers),
          '--row-fields', jsonEncode(fields),
        ],
        _exprTimeout,
      );
      final out = (result.stdout as String);
      return _parseTraceNdjson(out);
    } catch (_) {
      return const [];
    }
  }

  /// Evaluate N expressions against one row context in a single spawn.
  ///
  /// Calls `bxp-fmt --expr-batch` with a JSON request on stdin, returns
  /// a parallel list of results. Amortises subprocess-spawn cost across
  /// the entire batch — typical GUI drill-down click runs ~14 input_schema
  /// vars + a few rule.when probes (~19 calls), and per-call latency at
  /// ~2 ms per spawn on Linux would compound to ~40 ms vs ~3 ms total
  /// for a single batched call.
  ///
  /// Returns an empty list if the spawn itself failed (binary missing,
  /// malformed request). Individual expression failures carry through
  /// as `ExprBatchResult(ok: false, error, detail, off?, len?)` and do
  /// NOT cause an empty return — the caller can render per-cell errors
  /// alongside successful results.
  static Future<List<ExprBatchResult>> evalBatch({
    required List<String> headers,
    required List<String> fields,
    required List<String> exprs,
    Map<String, String>? tickerMap,
    Map<String, String>? lookups,
    Duration timeout = _exprTimeout,
    String? binPath,
  }) async {
    final bin = binPath ?? findBin('bxp-fmt');
    if (bin == null) return const [];

    final request = <String, dynamic>{
      'headers': headers,
      'fields': fields,
      'exprs': exprs,
    };
    if (tickerMap != null && tickerMap.isNotEmpty) {
      request['ticker_map'] = tickerMap;
    }
    if (lookups != null && lookups.isNotEmpty) {
      request['lookups'] = lookups;
    }
    final requestJson = jsonEncode(request);

    // Process.start so we can write the JSON body to the child's stdin.
    // bxp-fmt --expr-batch responses are small (typically 1-5 KB for a
    // realistic drill-down) so the dart-lang/sdk#1727 Windows pipe-overflow
    // race doesn't bite here — we don't need the bridge proxy round-trip.
    try {
      final p = await Process.start(bin, ['--expr-batch']);
      p.stdin.add(utf8.encode(requestJson));
      await p.stdin.close();
      final stdoutFut = p.stdout.transform(utf8.decoder).join();
      final stderrFut = p.stderr.transform(utf8.decoder).join();
      final exitFut = p.exitCode;
      // Race the child against the timeout. If timeout fires we kill the
      // process so the futures resolve instead of leaking. The "killed
      // child" branch reports an empty result list — caller surfaces a
      // timeout indicator the same way it would for any spawn failure.
      final exitCode = await exitFut.timeout(timeout, onTimeout: () {
        p.kill();
        return ProcessRunResult.kExitTimeout;
      });
      if (exitCode != 0) {
        // Drain so the futures complete; the stderr line is useful for
        // diagnostics but we don't surface it through the return — caller
        // sees an empty list and can decide on its own UX.
        final err = await stderrFut;
        _lastSubprocessDiag = 'evalBatch exit=$exitCode stderr="${_peek(err)}"';
        return const [];
      }
      final out = await stdoutFut;
      return _parseBatchResults(out);
    } catch (e) {
      _lastSubprocessDiag = 'evalBatch ${e.runtimeType}: $e';
      return const [];
    }
  }

  /// Parse the `{"results":[...]}` shape from `bxp-fmt --expr-batch`.
  /// Tolerates malformed individual entries (rendered as ok:false) so a
  /// single corrupt result line can't discard the rest of the batch.
  static List<ExprBatchResult> _parseBatchResults(String out) {
    Map<String, dynamic>? parsed;
    try {
      final v = jsonDecode(out);
      if (v is Map<String, dynamic>) parsed = v;
    } catch (_) {
      return const [];
    }
    if (parsed == null) return const [];
    final rawResults = parsed['results'];
    if (rawResults is! List) return const [];
    final out_ = <ExprBatchResult>[];
    for (final r in rawResults) {
      if (r is! Map) {
        out_.add(const ExprBatchResult(
          ok: false,
          error: 'BadResultShape',
          detail: 'result entry was not a JSON object',
        ));
        continue;
      }
      final ok = r['ok'] == true;
      out_.add(ExprBatchResult(
        ok: ok,
        value: ok ? r['value']?.toString() : null,
        error: ok ? null : r['error']?.toString(),
        detail: ok ? null : r['detail']?.toString(),
        off: r['off'] is num ? (r['off'] as num).toInt() : null,
        len: r['len'] is num ? (r['len'] as num).toInt() : null,
      ));
    }
    return out_;
  }

  /// Parse NDJSON from `bxp-fmt --expr-trace` (or the bridge equivalent)
  /// into a per-call list, dropping the final/error sentinel and any
  /// malformed lines. Shared between the bridge and subprocess paths so
  /// the same payload shape produces identical parsed results.
  static List<ExprCallTrace> _parseTraceNdjson(String out) {
    final calls = <ExprCallTrace>[];
    for (final line in out.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // One bad NDJSON line must NOT discard the rest of the trace —
      // per-line try/catch so a malformed sentinel from a future bxp-fmt
      // doesn't drop the 200 lines that came before it.
      try {
        final parsed = jsonDecode(trimmed);
        if (parsed is! Map) continue;
        // Skip the final-result sentinel `{"t":"final","value":"..."}` —
        // the per-call entries omit `t` and have a `fn` field.
        if (parsed['fn'] is! String) continue;
        final ss = parsed['src_start'];
        final se = parsed['src_end'];
        if (ss is! num || se is! num) continue;
        calls.add(ExprCallTrace(
          fn: parsed['fn'] as String,
          srcStart: ss.toInt(),
          srcEnd: se.toInt(),
          value: parsed['value']?.toString() ?? '',
        ));
      } catch (_) {
        // Skip this line, keep the rest.
        continue;
      }
    }
    return calls;
  }

  // ── Streaming invocations (stdout emitted as NDJSON events) ───────────

  /// Spawns `bxp-cli --config <path> --template <id> --dry-run --trace`.
  ///
  /// The pipeline runs with CWD = dirname(config_path) so `data_dir` paths
  /// in the template resolve the same way the FFI path did.
  ///
  /// [onLine] is invoked for every stdout line (one NDJSON event). Returns
  /// the process exit code once the pipeline finishes. stderr is captured
  /// and returned via [onStderr] (all at once, at end) so the caller can
  /// surface it in the UI.
  /// Optional `onSpawn` is called once with the [Process] handle as soon as
  /// the child has been started. Caller uses it to wire a "cancel" button:
  /// stash the handle, then invoke `kill()` from the UI to stop the run
  /// mid-stream. Skipped for callers that only need fire-and-forget streaming.
  static Future<ProcessRunResult> runDryRun({
    required String configPath,
    required String templateId,
    required void Function(String line) onLine,
    void Function(String chunk)? onStderr,
    void Function(Process)? onSpawn,
  }) =>
      _runCliTrace(
        configPath: configPath,
        templateId: templateId,
        dryRun: true,
        onLine: onLine,
        onStderr: onStderr,
        onSpawn: onSpawn,
      );

  static Future<ProcessRunResult> runFullRun({
    required String configPath,
    required String templateId,
    required void Function(String line) onLine,
    void Function(String chunk)? onStderr,
    void Function(Process)? onSpawn,
  }) =>
      _runCliTrace(
        configPath: configPath,
        templateId: templateId,
        dryRun: false,
        onLine: onLine,
        onStderr: onStderr,
        onSpawn: onSpawn,
      );

  static Future<ProcessRunResult> _runCliTrace({
    required String configPath,
    required String templateId,
    required bool dryRun,
    required void Function(String line) onLine,
    void Function(String chunk)? onStderr,
    void Function(Process)? onSpawn,
  }) async {
    final endAction = DiagnosticLog.action(
      dryRun ? 'runDryRun' : 'runFullRun',
      {'config': configPath, 'template': templateId},
    );
    final bin = findBin('bxp-cli');
    if (bin == null) {
      endAction({'result': 'binary_missing'});
      return const ProcessRunResult(
        exitCode: ProcessRunResult.kExitBinaryMissing,
        stderr: 'bxp-cli binary not found',
      );
    }

    final args = <String>[
      '--config',
      configPath,
      if (templateId.isNotEmpty) ...['--template', templateId],
      if (dryRun) '--dry-run',
      '--trace',
    ];

    // CWD = config dir so relative data_dir paths resolve identically to
    // what the FFI did via chdir(). Fail fast when the file is gone instead
    // of silently spawning bxp-cli with the GUI binary's CWD.
    final configFile = File(configPath);
    if (!configFile.existsSync()) {
      endAction({'result': 'config_missing'});
      return ProcessRunResult(
        exitCode: ProcessRunResult.kExitConfigMissing,
        stderr: 'config file not found: $configPath',
      );
    }
    final workingDir = configFile.parent.path;

    // Bridge is mandatory on Windows: dart:io's stream listener silently
    // drops bytes past ~8 KB on this platform (sdk#1727 + #51273) and
    // `--trace` would get brutally truncated. The bridge runs streaming
    // on its own threads and reports stdout in batches (default 100
    // newline-terminated lines, plus a final flush at EOF), so file-list
    // and per-row counters update progressively in the UI rather than
    // appearing all at once at the end of the run. Backpressure is
    // bounded by a per-stream semaphore — the bridge blocks the reader
    // thread after `default_queue_permits` (32) un-acked batches, and
    // Dart releases a permit via `bridge_ack` after processing each
    // batch (handled inside `BridgeClient.runStreaming`).
    final dllPath = _resolveBridgePath();
    if (Platform.isWindows) {
      if (dllPath == null) {
        endAction({
          'path': 'bridge',
          'result': 'dll_missing',
        });
        return ProcessRunResult(
          exitCode: -1,
          stderr: 'bridge: ${_lastSubprocessDiag ?? "DLL unavailable"}',
        );
      }
      final r = await _runCliTraceViaBridge(
        bin: bin,
        args: args,
        cwd: workingDir,
        dllPath: dllPath,
        onLine: onLine,
        onStderr: onStderr,
      );
      endAction({
        'path': 'bridge',
        'exit': r.exitCode,
        'stderr_bytes': r.stderr.length,
      });
      return r;
    }
    // Non-Windows pre-release smoke path: when BXP_FORCE_BRIDGE_PROXY=1
    // and the bridge library is loadable, route the streaming trace
    // through bridge_run_streaming instead of Process.start to exercise
    // the cross-platform bridge build end-to-end. Gate on the env var
    // explicitly (see `_runOneShot` for the same caveat).
    if (_forceBridgeProxy() && dllPath != null) {
      final r = await _runCliTraceViaBridge(
        bin: bin,
        args: args,
        cwd: workingDir,
        dllPath: dllPath,
        onLine: onLine,
        onStderr: onStderr,
      );
      endAction({
        'path': 'bridge-smoke',
        'exit': r.exitCode,
        'stderr_bytes': r.stderr.length,
      });
      return r;
    }

    final process = await Process.start(
      bin,
      args,
      workingDirectory: workingDir,
    );
    onSpawn?.call(process);

    final stderrBuffer = StringBuffer();

    // Idle watchdog — different from the per-call timeouts on the
    // one-shot Process.run paths above. Streaming runs can legitimately
    // take minutes on large datasets, so a hard total-time deadline
    // would make false positives. Instead we measure inactivity:
    // every stdout line / stderr chunk resets the timer; if nothing
    // arrives for `_streamIdleTimeout` the child is presumed stuck
    // (deadlock, infinite loop on a malformed row, blocked write) and
    // gets SIGTERM. The user keeps the stop-button cancel from P2 for
    // earlier intervention.
    bool watchdogFired = false;
    Timer? watchdog;
    Timer? watchdogEscalation;
    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(_streamIdleTimeout, () {
        watchdogFired = true;
        process.kill(ProcessSignal.sigterm);
        // SIGTERM is queued for a SIGSTOP'd child and never delivered
        // until SIGCONT — so a pause with `kill -STOP` would leave the
        // GUI stuck waiting for an exit that can't happen. SIGKILL
        // can't be blocked or queued, so we escalate after a short
        // grace window to guarantee the process actually dies.
        watchdogEscalation = Timer(const Duration(seconds: 2), () {
          process.kill(ProcessSignal.sigkill);
        });
      });
    }

    resetWatchdog();

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      resetWatchdog();
      if (line.isEmpty) return;
      onLine(line);
    }).asFuture<void>();

    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen((chunk) {
      resetWatchdog();
      stderrBuffer.write(chunk);
      // Stream stderr live to the caller — bxp-cli writes diagnostic
      // warnings (e.g. "[xlsx pre-pass] missing sheet") to stderr while
      // the trace stream is still running, so the StatusBar surfaces
      // these progressively instead of waiting for the whole pipeline
      // to finish.
      onStderr?.call(chunk);
    }).asFuture<void>();

    final exitCode = await process.exitCode;
    watchdog?.cancel();
    watchdogEscalation?.cancel();
    await stdoutDone;
    await stderrDone;

    if (watchdogFired) {
      final note = 'bxp-cli idle watchdog fired '
          '(no output for ${_streamIdleTimeout.inSeconds}s — '
          'process killed)';
      stderrBuffer.writeln();
      stderrBuffer.writeln(note);
    }

    endAction({
      'path': 'native',
      'exit': exitCode,
      'stderr_bytes': stderrBuffer.length,
      'watchdog_fired': watchdogFired,
    });
    return ProcessRunResult(
      exitCode: exitCode,
      stderr: stderrBuffer.toString(),
    );
  }

  /// Idle watchdog window for streaming runs. If neither stdout nor
  /// stderr produces a byte for this long the child is presumed stuck
  /// and SIGTERM'd. Tuned generously: bxp-cli normally emits trace
  /// lines well below 1 Hz, so 10 s is dozens of lines of headroom
  /// while still fast enough to recover from a deadlock without the
  /// user reaching for `kill`.
  static const Duration _streamIdleTimeout = Duration(seconds: 10);

  /// Bridge variant of [_runCliTrace]. The bridge drains the child's pipes
  /// from native Zig code (no dart:io truncation) and reports stdout in
  /// batches of 1000 lines via FFI callbacks routed through
  /// `NativeCallable.listener`, so trace rows appear in the UI as the
  /// child produces them — not at the end of the run.
  ///
  /// Runs on the main isolate. Earlier batch-mode bridge calls hopped into
  /// `Isolate.run` because they blocked for the entire child lifetime;
  /// `runStreaming` returns to its caller as soon as the bridge has armed
  /// its threads, so the main isolate stays responsive without isolate
  /// gymnastics.
  ///
  /// Mirrors the Process.start path's idle watchdog: every batch / chunk
  /// resets a [_streamIdleTimeout] timer, and on fire we deliver
  /// `bridge_cancel(handle)` to SIGTERM the child. The bridge then drains
  /// remaining buffered output, reaps exit, and the streaming future
  /// resolves naturally with the signal exit code — no orphaned child,
  /// no leaked output.
  static Future<ProcessRunResult> _runCliTraceViaBridge({
    required String bin,
    required List<String> args,
    required String cwd,
    required String dllPath,
    required void Function(String line) onLine,
    void Function(String chunk)? onStderr,
  }) async {
    final stderrBuffer = StringBuffer();
    final client = BridgeClient(dllPath);

    int? streamHandle;
    bool watchdogFired = false;
    Timer? watchdog;

    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(_streamIdleTimeout, () {
        watchdogFired = true;
        // Cancel the bridge's child via the new bridge_cancel API. The
        // streaming future resolves naturally once the child reaps and
        // on_exit fires; no abandonment, no orphaned process.
        final h = streamHandle;
        if (h != null) client.cancel(h);
      });
    }

    resetWatchdog();

    final exitCode = await client.runStreaming(
      bin,
      args,
      cwd: cwd,
      onSpawn: (handle) {
        streamHandle = handle;
      },
      onLine: (line) {
        resetWatchdog();
        onLine(line);
      },
      onStderr: (chunk) {
        resetWatchdog();
        stderrBuffer.write(chunk);
        onStderr?.call(chunk);
      },
    ).catchError((Object e, StackTrace _) {
      _lastSubprocessDiag = 'bridge $_bridgeVersion: '
          'stream ${e.runtimeType}: $e';
      return -1;
    });

    watchdog?.cancel();

    final reportedExit =
        watchdogFired ? ProcessRunResult.kExitTimeout : exitCode;

    if (watchdogFired) {
      final note = 'bridge: stream watchdog fired '
          '(no output for ${_streamIdleTimeout.inSeconds}s — child killed)';
      stderrBuffer.writeln();
      stderrBuffer.writeln(note);
      _lastSubprocessDiag = 'bridge $_bridgeVersion: $note';
    } else if (exitCode >= 0) {
      _lastSubprocessDiag = 'bridge $_bridgeVersion: '
          'stream exit $exitCode, stderr=${stderrBuffer.length} B';
    }
    return ProcessRunResult(
      exitCode: reportedExit,
      stderr: stderrBuffer.toString(),
    );
  }
}

/// Worker-isolate entry point for FFI bridge calls. Top-level on purpose:
/// `Isolate.run` requires the function (and its closure-captured values)
/// to be sendable, and a top-level function never accidentally drags an
/// enclosing class instance into the isolate boundary check.
///
/// Each invocation opens its own [BridgeClient] (the underlying
/// DynamicLibrary is per-isolate; we can't share one with the main
/// isolate). Re-opening costs a handful of milliseconds — well below
/// the bridge's per-call pipe-drain cost — and lets us use the simple
/// `Isolate.run` API instead of a long-lived worker with port plumbing.
BridgeResult _bridgeRunInIsolate(
  String dllPath,
  String executable,
  List<String> arguments,
) {
  try {
    final client = BridgeClient(dllPath);
    return client.run(executable, arguments);
  } catch (e) {
    return BridgeResult(
      exitCode: -1,
      stdout: '',
      stderr: '',
      err: 'bridge isolate exception: $e',
    );
  }
}

class ProcessRunResult {
  /// Synthetic exit code for "the binary we needed could not be located"
  /// (see [BxpProcessClient.findBin]). Negative so consumers that gate
  /// on `exitCode < 0` continue to treat it as failure; named so call
  /// sites and log readers can distinguish it from real OS exit codes
  /// (which are always ≥ 0 for normal exit, or negative-signal-number
  /// when killed).
  static const int kExitBinaryMissing = -1;

  /// Synthetic exit code for "the config path we were handed does not exist
  /// on disk". Distinct from `kExitBinaryMissing` so the UI can show a
  /// targeted message ("config file not found") instead of a generic
  /// failure. Avoids the older silent fallback to `Directory.current.path`,
  /// which would have spawned bxp-cli with the GUI binary's CWD — usually
  /// the wrong place and a class of "the run looks fine but the output
  /// landed somewhere unexpected" bugs.
  static const int kExitConfigMissing = -2;

  /// Synthetic exit code for "the child process exceeded its per-call
  /// timeout and was killed". The caller surfaces a "timed out" message
  /// in place of the usual stderr — see `BxpProcessClient._runWithTimeout`.
  static const int kExitTimeout = -3;

  final int exitCode;
  final String stderr;
  const ProcessRunResult({required this.exitCode, required this.stderr});
}

/// One entry returned by `bxp-fmt --list-templates` — used to render the
/// template-selector subtitle (file pattern / description) without re-parsing
/// the config inside the GUI.
class TemplateInfo {
  final String id;
  final String? dataDir;
  final String? filePatternIn;
  final String? filePatternOut;
  final String fileTypeIn;
  final String fileTypeOut;
  final String? description;

  const TemplateInfo({
    required this.id,
    this.dataDir,
    this.filePatternIn,
    this.filePatternOut,
    this.fileTypeIn = 'csv',
    this.fileTypeOut = 'csv',
    this.description,
  });

  factory TemplateInfo.fromJson(Map<String, dynamic> j) => TemplateInfo(
        id: j['id']?.toString() ?? '',
        dataDir: j['data_dir']?.toString(),
        filePatternIn: j['file_pattern_in']?.toString(),
        filePatternOut: j['file_pattern_out']?.toString(),
        fileTypeIn: j['file_type_in']?.toString() ?? 'csv',
        fileTypeOut: j['file_type_out']?.toString() ?? 'csv',
        description: j['description']?.toString(),
      );
}

/// One entry from a `bxp-fmt --expr-batch` result array.
///
/// On success: `ok = true`, `value` holds the stringified result of evaluating
/// the matching expression from the request. All other fields are null.
/// On failure: `ok = false`, `error` holds the error name (e.g.
/// `"ColumnNotFound"`, `"UnexpectedToken"`), `detail` a human-readable
/// message, and `off` / `len` optionally point at the offending token in
/// the expression source (used by the GUI's `ExprEditor` highlighter).
class ExprBatchResult {
  final bool ok;
  final String? value;
  final String? error;
  final String? detail;
  final int? off;
  final int? len;

  const ExprBatchResult({
    required this.ok,
    this.value,
    this.error,
    this.detail,
    this.off,
    this.len,
  });
}
