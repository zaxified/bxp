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
    final sibling = '$exeDir/$name';
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
        final candidate = p.join(parent.path, name, 'zig-out', 'bin', name);
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
  static Future<ProcessResult> _runWithTimeout(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    final process = await Process.start(executable, arguments);
    final stdoutFut = process.stdout.transform(utf8.decoder).join();
    final stderrFut = process.stderr.transform(utf8.decoder).join();
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      final out = await stdoutFut;
      final err = await stderrFut;
      return ProcessResult(process.pid, exitCode, out, err);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      // Best-effort drain: if the child ignores SIGTERM, escalate to
      // SIGKILL after a short grace window so we don't wait forever
      // collecting streams that will never close.
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        try { await process.exitCode; } catch (_) {}
      }
      // Streams should now be at EOF; drain them so the file descriptors
      // get released. Errors here are not interesting to the caller.
      String out = '';
      String err = '';
      try { out = await stdoutFut; } catch (_) {}
      try { err = await stderrFut; } catch (_) {}
      final timeoutNote =
          '$executable timed out after ${timeout.inSeconds}s';
      return ProcessResult(
        process.pid,
        ProcessRunResult.kExitTimeout,
        out,
        err.isEmpty ? timeoutNote : '$err\n$timeoutNote',
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
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim();
      if (out.isEmpty) return null;
      final parsed = jsonDecode(out);
      return parsed is Map<String, dynamic> ? parsed : null;
    } catch (_) {
      return null;
    }
  }

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
  /// Returns null on success, human-readable message on failure.
  ///
  /// `bxp-fmt --expr` emits a structured `{"error":"X","detail":"Y"}` on
  /// failure (currently on stdout, but we read both streams to stay
  /// resilient to CLI version drift). We unwrap that into `"X: Y"` (or
  /// just `"X"` when detail is empty) so the editor's error box reads
  /// like a compiler diagnostic instead of leaking raw JSON.
  static Future<String?> validateExpr(String expr) async {
    if (expr.isEmpty) return null;
    final bin = findBin('bxp-fmt');
    if (bin == null) return 'bxp-fmt not found';
    final result =
        await _runWithTimeout(bin, ['--expr', expr], _exprTimeout);
    if (result.exitCode == 0) return null;
    final stdout = (result.stdout as String).trim();
    final stderr = (result.stderr as String).trim();
    final raw = stdout.isNotEmpty ? stdout : stderr;
    if (raw.isEmpty) return 'invalid expression';
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        final err = m['error'];
        final detail = m['detail'];
        if (err is String && err.isNotEmpty) {
          if (detail is String && detail.isNotEmpty) return '$err: $detail';
          return err;
        }
      }
    } catch (_) {
      // Not JSON — fall through to the raw text.
    }
    return raw;
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
