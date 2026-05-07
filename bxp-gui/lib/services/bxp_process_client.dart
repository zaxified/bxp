import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../store/trace_model.dart';
import 'dev_trace.dart';

/// Spawn-based client for `bxp-cli` and `bxp-fmt`.
///
/// Mirrors the RPC surface bxp-ui uses from its Bun main process: every
/// call is a short-lived sub-process. `--trace` runs stream stdout line
/// by line (one NDJSON event per line); validation calls capture stdout
/// in full. The old FFI path (zig/bxp-ffi, a separate shared library
/// re-exporting bxp-core) was deleted — keeping a parallel binding
/// duplicated maintenance with zero UX upside now that validateExpr
/// is debounced asynchronously.
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
  static const Duration _versionTimeout = Duration(seconds: 5);
  static const Duration _docsTimeout = Duration(seconds: 5);
  static const Duration _exprTimeout = Duration(seconds: 15);
  static const Duration _configTimeout = Duration(seconds: 15);
  static const Duration _listTemplatesTimeout = Duration(seconds: 30);

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
    // Two-attempt diagnostic strategy. The default Process.start path
    // races against Dart's deferred pipe-attach on Windows: bxp-fmt's
    // 30 KB --docs output overflows the 4 KB Win pipe buffer before the
    // listener is wired and the child trips its own flush with
    // `error: WriteFailed` / exit 1. Falling back to runInShell:true
    // routes through cmd /c (sh -c on POSIX), which drains the child
    // pipe in native code without depending on the Dart event loop.
    //
    // We try direct first to keep the Linux/macOS happy path zero-cost,
    // then retry via shell on non-zero exit. The diagnostic captures
    // both attempts so we can confirm which branch is actually
    // load-bearing once we collect Windows reports.
    String describe(String tag, ProcessResult r) {
      final out = r.stdout as String;
      final err = (r.stderr as String).trim();
      return '$tag: exit ${r.exitCode}, stdout=${out.length} B'
          ', stderr=${err.length} B'
          '${err.isEmpty ? '' : ' "${_peek(err)}"'}';
    }
    final r1 = await _runOnce(executable, arguments, timeout, runInShell: false);
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
    final bin = findBin('bxp-fmt');
    if (bin == null) {
      return '{"error": "bxp-fmt binary not found"}';
    }
    final args = checkFsSeconds > 0
        ? ['--config', path, '--check-fs=$checkFsSeconds']
        : ['--config', path];
    final result = await _runWithTimeout(bin, args, _configTimeout);
    if (result.exitCode == 0) {
      return result.stdout as String;
    }
    // Exit 1 = validation failure; bxp-fmt still emits annotated JSON with $err_ nodes.
    if ((result.stdout as String).isNotEmpty) return result.stdout as String;
    final err = (result.stderr as String).trim();
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
          await _runWithTimeout(bin, ['--version'], _versionTimeout);
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
  /// null if the binary is missing or returns garbage. Mirrors bxp-ui's
  /// `getDocs` RPC — same single-source-of-truth contract so the tree
  /// tooltips, expression catalog, and autocomplete all read from the
  /// same data the CLI itself ships.
  static Future<Map<String, dynamic>?> getDocs() async {
    final bin = findBin('bxp-fmt');
    if (bin == null) return null;
    try {
      final result = await _runWithTimeout(bin, ['--docs'], _docsTimeout);
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
      final result = await _runWithTimeout(
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
    final bin = findBin('bxp-fmt');
    if (bin == null) return (error: 'bxp-fmt not found', offset: null, length: null);
    final result =
        await _runWithTimeout(bin, ['--expr', expr], _exprTimeout);
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
    final bin = findBin('bxp-fmt');
    if (bin == null) return const [];
    try {
      final result = await _runWithTimeout(
        bin,
        [
          '--expr-trace', expr,
          '--row-headers', jsonEncode(headers),
          '--row-fields', jsonEncode(fields),
        ],
        _exprTimeout,
      );
      final out = (result.stdout as String);
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
    } catch (_) {
      return const [];
    }
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
    final bin = findBin('bxp-cli');
    if (bin == null) {
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
      return ProcessRunResult(
        exitCode: ProcessRunResult.kExitConfigMissing,
        stderr: 'config file not found: $configPath',
      );
    }
    final workingDir = configFile.parent.path;

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
      // the trace stream is still running. Mirrors bxp-ui's pushStderr
      // so the StatusBar surfaces these progressively instead of waiting
      // for the whole pipeline to finish.
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
