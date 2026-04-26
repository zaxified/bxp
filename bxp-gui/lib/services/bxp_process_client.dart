import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  ///   2. Packaged bundle (future): `bin/<name>` relative to executable
  ///   3. Dev path (monorepo): `<cwd>/../<name>/zig-out/bin/<name>`
  ///
  /// Returns null when no candidate exists on disk.
  static String? findBin(String name) {
    final envVar = switch (name) {
      'bxp-cli' => Platform.environment['BXP_CLI_PATH'],
      'bxp-fmt' => Platform.environment['BXP_FMT_PATH'],
      _ => null,
    };
    if (envVar != null && envVar.isNotEmpty && File(envVar).existsSync()) {
      return envVar;
    }

    // Packaged bundle: alongside the Flutter executable.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final packaged = '$exeDir/bin/$name';
    if (File(packaged).existsSync()) return packaged;

    // Dev layout (monorepo): sibling package in parent directory.
    final dev = '${Directory.current.path}/../$name/zig-out/bin/$name';
    if (File(dev).existsSync()) return dev;

    return null;
  }

  // ── One-shot invocations (stdout captured) ─────────────────────────────

  /// Validates config via `bxp-fmt --config <path>`.
  /// Returns stdout (annotated JSON) on exit 0, throws on missing binary.
  /// Non-zero exit with stderr is returned wrapped in `{"error": "..."}`.
  static Future<String> loadConfig(String path) async {
    final bin = findBin('bxp-fmt');
    if (bin == null) {
      return '{"error": "bxp-fmt binary not found"}';
    }
    final result = await Process.run(bin, ['--config', path]);
    if (result.exitCode == 0) {
      return result.stdout as String;
    }
    // Exit 1 = validation failure; bxp-fmt still emits annotated JSON with $err_ nodes.
    if ((result.stdout as String).isNotEmpty) return result.stdout as String;
    final err = (result.stderr as String).trim();
    return '{"error": ${jsonEncode(err.isEmpty ? "unknown error" : err)}}';
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
      final result = await Process.run(bin, ['--docs']);
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim();
      if (out.isEmpty) return null;
      final parsed = jsonDecode(out);
      return parsed is Map<String, dynamic> ? parsed : null;
    } catch (_) {
      return null;
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
    final result = await Process.run(bin, ['--expr', expr]);
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
  static Future<ProcessRunResult> runDryRun({
    required String configPath,
    required String templateId,
    required void Function(String line) onLine,
    void Function(String chunk)? onStderr,
  }) =>
      _runCliTrace(
        configPath: configPath,
        templateId: templateId,
        dryRun: true,
        onLine: onLine,
        onStderr: onStderr,
      );

  static Future<ProcessRunResult> runFullRun({
    required String configPath,
    required String templateId,
    required void Function(String line) onLine,
    void Function(String chunk)? onStderr,
  }) =>
      _runCliTrace(
        configPath: configPath,
        templateId: templateId,
        dryRun: false,
        onLine: onLine,
        onStderr: onStderr,
      );

  static Future<ProcessRunResult> _runCliTrace({
    required String configPath,
    required String templateId,
    required bool dryRun,
    required void Function(String line) onLine,
    void Function(String chunk)? onStderr,
  }) async {
    final bin = findBin('bxp-cli');
    if (bin == null) {
      return const ProcessRunResult(
        exitCode: -1,
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
    // what the FFI did via chdir().
    final configFile = File(configPath);
    final workingDir = configFile.existsSync()
        ? configFile.parent.path
        : Directory.current.path;

    final process = await Process.start(
      bin,
      args,
      workingDirectory: workingDir,
    );

    final stderrBuffer = StringBuffer();

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.isEmpty) return;
      onLine(line);
    }).asFuture<void>();

    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen((chunk) {
      stderrBuffer.write(chunk);
      // Stream stderr live to the caller — bxp-cli writes diagnostic
      // warnings (e.g. "[xlsx pre-pass] missing sheet") to stderr while
      // the trace stream is still running. Mirrors bxp-ui's pushStderr
      // so the StatusBar surfaces these progressively instead of waiting
      // for the whole pipeline to finish.
      onStderr?.call(chunk);
    }).asFuture<void>();

    final exitCode = await process.exitCode;
    await stdoutDone;
    await stderrDone;

    return ProcessRunResult(
      exitCode: exitCode,
      stderr: stderrBuffer.toString(),
    );
  }
}

class ProcessRunResult {
  final int exitCode;
  final String stderr;
  const ProcessRunResult({required this.exitCode, required this.stderr});
}
