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
      return File(envVar).existsSync() ? envVar : null;
    }

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sibling = '$exeDir/$name';
    if (File(sibling).existsSync()) return sibling;

    // Walk up looking for a `bxp-gui/` directory; its parent is the monorepo
    // root that holds sibling packages `bxp-cli/` and `bxp-fmt/`.
    Directory dir = Directory(exeDir);
    for (int i = 0; i < 10; i++) {
      final parent = dir.parent;
      if (parent.path == dir.path) break; // reached filesystem root
      if (dir.path.endsWith('/bxp-gui')) {
        final candidate = '${parent.path}/$name/zig-out/bin/$name';
        if (File(candidate).existsSync()) return candidate;
        break;
      }
      dir = parent;
    }

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
      final result =
          await Process.run(bin, ['--config', path, '--list-templates']);
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
