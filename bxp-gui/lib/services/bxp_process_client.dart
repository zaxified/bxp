import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../store/trace_model.dart';
import 'bridge_client.dart';
import 'dev_trace.dart';
import 'diagnostic_log.dart';

/// Bridge-backed client for the bxp toolchain.
///
/// Everything routes through the in-process `bxp-gui-bridge` shared library
/// on every platform — there is no separate validator subprocess and no
/// Process.start path. Two call shapes share one library:
///   * Stateless ops (`getDocs` / `loadConfig` / `listTemplates` /
///     `fetchTemplate` / `evalBatch` / `validateExpr` / `traceExpr`) call
///     `bridge_inspect` / `bridge_eval_*` synchronously on the main isolate
///     (sub-ms, served from bxp-core/inspect).
///   * `bxp-cli` runs (`runWithBtrace` dry-run / full-run, `--version`) go
///     through `bridge_run` / `bridge_run_streaming` in an `Isolate.run`
///     worker so the blocking pipe drain never stalls the UI thread; the
///     bridge drains the pipe in native Zig code (sidestepping dart:io's
///     Windows pipe truncation, dart-lang/sdk#1727).
///
/// `bxp-cli` is still a real binary the bridge spawns; the former `bxp-fmt`
/// validator subprocess is gone — the bridge links bxp-core/inspect directly,
/// so the GUI needs no validator binary. A missing bridge library is a fatal
/// startup error — same as Windows always had.
class BxpProcessClient {
  /// Resolve a sibling binary (`bxp-cli` for runs, `bxp-mcp` for the
  /// inspector's path display). Search order:
  ///   1. Env override: `$BXP_CLI_PATH` (`bxp-cli` only)
  ///      — when SET (non-empty), this wins absolutely. If the path doesn't
  ///        exist we return null instead of falling through to the bundle
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
  /// other platforms untouched. The release packager copies `bxp-cli` as
  /// `bxp-cli.exe` into the Windows bundle (release-02-desktop.sh), so a bare
  /// 'bxp-cli' lookup would miss on disk without the platform suffix.
  static String binaryFileName(String name) =>
      Platform.isWindows ? '$name.exe' : name;

  /// Returns null when no candidate exists on disk.
  static String? findBin(String name) {
    final envVar = switch (name) {
      'bxp-cli' => Platform.environment['BXP_CLI_PATH'],
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
    // root that holds the sibling package `bxp-cli/`. Use
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

  /// Bundled starter-template file name. Ships next to the binaries in the
  /// desktop archive (release-02-desktop.sh) so a GUI-only install — which
  /// no longer assumes the console archive is also present — still has the
  /// example templates on hand.
  static const examplesFileName = 'bxp-cli.examples.json';

  /// Locates the bundled `bxp-cli.examples.json`. Mirrors [findBin]:
  /// `$BXP_EXAMPLES_PATH` override → sibling of the running executable
  /// (desktop bundle) → dev-tree `<mono>/resources/console/<file>`.
  /// Returns null when no copy exists.
  static String? findExamplesSource() {
    final env = Platform.environment['BXP_EXAMPLES_PATH'];
    if (env != null && env.isNotEmpty) {
      if (File(env).existsSync()) return env;
      devTrace('findExamples.envOverrideMissing', {'path': env});
      return null;
    }

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sibling = p.join(exeDir, examplesFileName);
    if (File(sibling).existsSync()) return sibling;

    // Same walk-up as findBin: find the `bxp-gui/` segment; its parent is
    // the monorepo root that holds `resources/console/`.
    Directory dir = Directory(exeDir);
    for (int i = 0; i < 10; i++) {
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      if (p.basename(dir.path) == 'bxp-gui') {
        final candidate =
            p.join(parent.path, 'resources', 'console', examplesFileName);
        if (File(candidate).existsSync()) return candidate;
        break;
      }
      dir = parent;
    }
    return null;
  }

  /// Copies the bundled examples file into [destDir] verbatim, keeping the
  /// `bxp-cli.examples.json` name. Never overwrites: on a name collision it
  /// appends ` (N)` before the extension until a free name is found.
  /// Returns the created file's path, or null when the source can't be
  /// located. Propagates I/O errors to the caller.
  static String? copyExamplesInto(String destDir) {
    final src = findExamplesSource();
    if (src == null) return null;
    final target = uniqueTargetPath(destDir, examplesFileName);
    File(src).copySync(target);
    devTrace('copyExamples.created', {'target': target});
    return target;
  }

  /// Returns `destDir/fileName`, or — when that exists — the first free
  /// `destDir/<base> (N)<ext>` (N = 1, 2, …). Pure-ish (only stats the
  /// filesystem); extracted for unit testing the collision suffixing.
  static String uniqueTargetPath(String destDir, String fileName) {
    final ext = p.extension(fileName); // .json
    final base = p.basenameWithoutExtension(fileName); // bxp-cli.examples
    String target = p.join(destDir, fileName);
    for (int n = 1; File(target).existsSync(); n++) {
      target = p.join(destDir, '$base ($n)$ext');
    }
    return target;
  }

  // ── One-shot invocations (stdout captured) ─────────────────────────────

  /// Timeout for the only remaining one-shot subprocess call, `--version`,
  /// which the bridge runs in an `Isolate.run` worker wrapped in
  /// `Future.timeout`. The stateless `the bridge` ops are in-process now (no
  /// spawn), so they carry no per-call spawn timeout.
  static const Duration _versionTimeout = Duration(seconds: 5);

  /// Cached bridge library path + main-isolate client. The bridge ships on
  /// every platform (release-02 + the Linux CMake copy place it next to
  /// bxp-gui) and is the *only* backend — there is no `the bridge` spawn
  /// fallback. The in-process inspect/eval ops (`getDocs` / `loadConfig` /
  /// `listTemplates` / `fetchTemplate` / `evalBatch` / `validateExpr` /
  /// `traceExpr`) call [_bridgeClient] directly on the main isolate (sub-ms,
  /// well under a frame). The blocking subprocess-proxy ops (`bxp-cli`
  /// dry-run via `bridge_run_streaming`, `--version` via `bridge_run`)
  /// re-open the library inside an `Isolate.run` worker by [_bridgeLibPath]
  /// so the blocking pipe drain never stalls the UI thread.
  static String? _bridgeLibPath;
  static BridgeClient? _bridgeClient;
  static String? _bridgeVersion;
  static bool _bridgeProbed = false;

  /// Library self-reported version, populated on the first [_bridge] probe.
  /// Surfaced in the SettingsInspector so a reporter can confirm which
  /// bridge build the GUI is talking to. Null until the probe runs.
  static String? get bridgeVersion => _bridgeVersion;

  /// Cached path of the bridge library after a successful probe. Diagnostic
  /// surface — the SettingsInspector renders it next to [bridgeVersion].
  static String? get bridgeDllPath => _bridgeLibPath;

  /// Probe + cache the bridge. Returns the main-isolate client, or null when
  /// the library can't be located/opened — in which case every op surfaces a
  /// visible error (fatal docs gate at startup, `{"error":...}` for config,
  /// empty results for the rest). There is no `the bridge` fallback: the bridge
  /// is the single sanctioned backend on every platform, so a missing library
  /// is a broken install.
  static BridgeClient? _bridge() {
    if (_bridgeProbed) return _bridgeClient;
    _bridgeProbed = true;
    final path = _bridgeLibPath ?? findBridgeLibrary();
    if (path == null) {
      _lastSubprocessDiag = 'bridge: library not found next to bxp-gui';
      return null;
    }
    try {
      _bridgeClient = BridgeClient(path);
      _bridgeLibPath = path;
      _bridgeVersion = _bridgeClient!.bridgeVersion;
      return _bridgeClient;
    } catch (e) {
      _lastSubprocessDiag = 'bridge: probe failed: $e';
      _bridgeLibPath = null;
      return null;
    }
  }

  /// True when the bridge library loads. The GUI startup gate calls this to
  /// distinguish "bridge missing" from "docs returned garbage" before
  /// rendering its fatal screen.
  static bool ensureBridgeLoaded() => _bridge() != null;

  /// Test seam: inject the bridge library path directly, short-circuiting the
  /// [findBridgeLibrary] sibling/dev-tree probe. `flutter test` runs from a
  /// CWD where `Platform.resolvedExecutable` points at the test runner (no
  /// `bxp-gui(.exe)` sibling), so the bridge can't self-resolve. Tests inject
  /// the dev-tree library here; forcing a re-probe so the next [_bridge] call
  /// opens the injected path. Not for production use.
  static void setBridgeLibPathForTest(String path) {
    _bridgeLibPath = path;
    _bridgeClient = null;
    _bridgeVersion = null;
    _bridgeProbed = false;
  }

  /// One-shot run, always via the bridge (`bridge_run` in an `Isolate.run`
  /// worker). The only remaining caller is [getVersion]; the stateless
  /// `the bridge` ops moved in-process to [_bridge]'s inspect/eval calls. The
  /// bridge is the single backend on every platform — a missing library
  /// surfaces a synthetic non-zero exit (no Process.start fallback).
  ///
  /// Why a worker isolate: `bridge_run` is synchronous and blocks for
  /// the duration of the child process. Running it on the main isolate
  /// would freeze Flutter's frame loop; `Isolate.run` offloads the
  /// blocking call to a fresh worker isolate so the UI stays smooth.
  /// Diagnostic trace of the most recent bridge subprocess call — exit
  /// code, stdout/stderr sizes, or the failure reason. Surfaced in fatal
  /// startup messages and the SettingsInspector so a bug reporter can paste
  /// the concrete failure mode instead of "didn't work".
  static String? _lastSubprocessDiag;
  static String? get lastSubprocessDiag => _lastSubprocessDiag;

  /// Validates config via `the bridge config validation <path>`.
  /// Returns stdout (annotated JSON) on exit 0, throws on missing binary.
  /// Non-zero exit with stderr is returned wrapped in `{"error": "..."}`.
  ///
  /// [checkFsSeconds] controls the bridge's optional FS validation pass:
  /// 0 (default) skips it entirely, >0 enables it with that many seconds
  /// total deadline. The TraceStore flips to 0 for the rest of the
  /// session if a previous call surfaced an `[fs.timeout]` warning.
  static Future<String> loadConfig(String path, {int checkFsSeconds = 0}) async {
    final endAction = DiagnosticLog.action('loadConfig', {
      'path': path,
      'check_fs': checkFsSeconds,
    });
    // In-process via the bridge (no spawn). Same annotated JSON, incl.
    // $err_ siblings; the FS check resolves data_dir against the GUI process
    // CWD — identical to the former spawned the bridge (config.zig opens data_dir
    // via cwd). annotateConfigFromFile always returns JSON (even file errors as
    // {"$err_1":...}), so a non-empty result means success.
    final bridge = _bridge();
    if (bridge == null) {
      endAction({'result': 'bridge_unavailable'});
      return '{"error": ${jsonEncode('bxp-gui-bridge unavailable: '
          '${_lastSubprocessDiag ?? "library not found"}')}}';
    }
    final raw = bridge.inspect(jsonEncode({
      'op': 'config',
      'path': path,
      if (checkFsSeconds > 0) 'check_fs': checkFsSeconds,
    }));
    if (raw != null && raw.trim().isNotEmpty) {
      endAction({'path_kind': 'bridge', 'bytes': raw.length});
      return raw;
    }
    endAction({'result': 'bridge_inspect_failed'});
    return '{"error": "bxp-gui-bridge config validation failed"}';
  }

  /// Probe a sibling binary for its version string via `<bin> --version`.
  /// Both bxp-cli and the bridge print `"<name> <version>\n"` (the version is
  /// injected from `build.zig.zon` via `build_options.version`), so we keep
  /// just the trailing token. Returns null when the binary is missing or
  /// the call fails — callers render that as "(unknown)".
  /// One-shot run via the TOLERANT streaming path (`bridge_run_streaming`),
  /// collecting stdout. Used for `--version` instead of the one-shot
  /// `bridge_run`: the latter's `child.wait()` panics on the ECHILD the Dart
  /// VM's `ExitCodeHandler` (`wait4(-1)`) reaper produces when it reaps the
  /// child first — and it can't be made ECHILD-tolerant under Zig 0.15.2 (a
  /// codegen bug miscompiles `bridge_run`'s spawn path when its wait control
  /// flow changes). The streaming wait loop IS tolerant, so routing version
  /// probes through it removes the racy startup crash. Returns null when the
  /// bridge library is unavailable.
  static Future<ProcessResult?> _runOneShotStreaming(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    final dllPath = _bridgeLibPath;
    if (_bridge() == null || dllPath == null) return null;
    final client = BridgeClient(dllPath);
    final stdoutBuf = BytesBuilder(copy: false);
    final stderrBuf = StringBuffer();
    try {
      final exitCode = await client
          .runStreamingBinary(
            executable,
            arguments,
            onChunk: (chunk) => stdoutBuf.add(chunk),
            onStderr: (chunk) => stderrBuf.write(chunk),
          )
          .timeout(timeout);
      return ProcessResult(
        0,
        exitCode,
        utf8.decode(stdoutBuf.takeBytes(), allowMalformed: true),
        stderrBuf.toString(),
      );
    } catch (e) {
      return ProcessResult(0, 1, '', 'bridge stream: $e');
    }
  }

  static Future<String?> getVersion(String name) async {
    final bin = findBin(name);
    if (bin == null) return null;
    try {
      final result =
          await _runOneShotStreaming(bin, ['--version'], _versionTimeout);
      if (result == null) return null;
      // Deliberately NOT gated on exitCode: the streaming wait reports
      // -1 / .Unknown when the Dart VM's reaper reaped the child before the
      // bridge's own wait, but the version text already streamed to stdout.
      final out = (result.stdout as String).trim();
      if (out.isEmpty) return null;
      final parts = out.split(RegExp(r'\s+'));
      return parts.length >= 2 ? parts.last : out;
    } catch (_) {
      return null;
    }
  }

  /// Fetch the canonical function/keyword/operator/token/config-schema
  /// catalog from `the bridge docs catalog`. Returns the parsed JSON tree, or
  /// null if the binary is missing or returns garbage. Single-source-of-
  /// truth contract: tree tooltips, expression catalog, and autocomplete
  /// all read from the same data the CLI itself ships.
  static Future<Map<String, dynamic>?> getDocs() async {
    // In-process via the bridge (no spawn); same JSON.
    final bridge = _bridge();
    if (bridge == null) {
      _lastDocsError = 'bxp-gui-bridge unavailable: '
          '${_lastSubprocessDiag ?? "library not found"}';
      return null;
    }
    final String? out = bridge.inspect('{"op":"docs"}');
    if (out == null) {
      _lastDocsError = 'bridge_inspect docs returned no payload';
      return null;
    }
    final trimmed = out.trim();
    if (trimmed.isEmpty) {
      _lastDocsError = 'docs output was empty';
      return null;
    }
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is Map<String, dynamic>) return parsed;
      _lastDocsError = 'parsed JSON is ${parsed.runtimeType}, expected a Map; '
          'starts with: ${_peek(trimmed)}';
      return null;
    } on FormatException catch (e) {
      _lastDocsError = 'jsonDecode failed: ${e.message}; '
          '(${trimmed.length} bytes) starts with: ${_peek(trimmed)}';
      return null;
    }
  }

  /// Diagnostic detail captured on the most recent [getDocs] failure.
  /// Surfaced in `trace_store._fatalStartupError` so the user-facing
  /// "the bridge docs catalog failed" screen can name the actual failure mode
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

  /// Fetch one template's raw JSON block via
  /// `the bridge config validation <path> --fetch-template <id>`. Returns the parsed
  /// JSON object (input_schema, row_rules, maps, …) or null on any
  /// failure (binary missing, exit non-zero, malformed JSON). Used by the
  /// btrace browser to drive `evalBatch` with the template's input_schema
  /// expressions when reconstructing drill-down on click.
  static Future<Map<String, dynamic>?> fetchTemplate(
      String configPath, String templateId) async {
    // In-process via the bridge (no spawn).
    final bridge = _bridge();
    if (bridge == null) {
      _lastSubprocessDiag = 'fetchTemplate: bridge unavailable';
      return null;
    }
    final String? out = bridge
        .inspect(jsonEncode({'op': 'fetch_template', 'path': configPath, 'id': templateId}));
    if (out == null) return null;
    try {
      final trimmed = out.trim();
      if (trimmed.isEmpty) return null;
      final parsed = jsonDecode(trimmed);
      if (parsed is! Map) return null;
      // Missing-id / read errors surface as {"$err_1":...} (the bridge path
      // returns that JSON rather than a non-zero exit) — treat as null, same
      // as the subprocess's exit-1 → null.
      if (parsed.containsKey('\$err_1')) return null;
      return parsed.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Enumerates conversion templates declared in a config via
  /// `the bridge config validation <path> --list-templates`. Returns an empty list when
  /// the binary is missing or the call fails — the caller falls back to its
  /// own enumeration of `configJson['conversion_templates']` keys, so a
  /// failure here only loses the metadata (data_dir / file_pattern_in /
  /// description) that powers the richer template-selector subtitle.
  static Future<List<TemplateInfo>> listTemplates(String path) async {
    // In-process via the bridge (no spawn).
    final bridge = _bridge();
    if (bridge == null) {
      _lastSubprocessDiag = 'listTemplates: bridge unavailable';
      return const [];
    }
    final String? out =
        bridge.inspect(jsonEncode({'op': 'list_templates', 'path': path}));
    if (out == null) return const [];
    try {
      final trimmed = out.trim();
      if (trimmed.isEmpty) return const [];
      final parsed = jsonDecode(trimmed);
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

  /// Validate an expression via `the bridge expr validator` (or the in-process bridge
  /// FFI path when the bridge library is loadable). Returns a record
  /// with `error` (null on success), and optional `offset` / `length`
  /// for token highlighting (Phase G1).
  ///
  /// `the bridge expr validator` emits a structured
  /// `{"error":"X","detail":"Y","off":N,"len":M}` on failure. We
  /// unwrap that into `"X: Y"` (or just `"X"` when detail is empty).
  static Future<({String? error, int? offset, int? length})> validateExpr(
    String expr,
  ) async {
    if (expr.isEmpty) return (error: null, offset: null, length: null);
    // In-process FFI (`bridge_eval_expr`). Sub-ms latency, safe on the main
    // isolate (well under one frame budget). No spawn fallback.
    final bridge = _bridge();
    if (bridge == null) {
      return (error: 'bxp-gui-bridge unavailable', offset: null, length: null);
    }
    DiagnosticLog.log('action.validateExpr', {'len': expr.length, 'path': 'bridge'});
    return bridge.evalExpr(expr);
  }

  /// Re-evaluates an expression against a CSV row context and returns the
  /// per-function-call NDJSON stream from `the bridge expr trace`. Used by
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
    // In-process FFI (`bridge_eval_expr_trace`). The NDJSON shape is identical
    // to the former `the bridge expr trace` stdout, so `_parseTraceNdjson`
    // works unchanged. No spawn fallback.
    final bridge = _bridge();
    if (bridge == null) {
      _lastSubprocessDiag = 'traceExpr: bridge unavailable';
      return const [];
    }
    final ndjson =
        bridge.evalExprTrace(text: expr, headers: headers, fields: fields);
    if (ndjson == null) return const [];
    return _parseTraceNdjson(ndjson);
  }

  /// Evaluate N expressions against one row context in a single spawn.
  ///
  /// Calls `the bridge expr batch` with a JSON request on stdin, returns
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
    Map<String, Map<String, String>>? maps,
    Map<String, String>? lookups,
    String? singlePrepassName,
  }) async {
    if (exprs.isEmpty) return const [];
    final request = <String, dynamic>{
      'headers': headers,
      'fields': fields,
      'exprs': exprs,
    };
    if (maps != null && maps.isNotEmpty) {
      request['maps'] = maps;
    }
    if (lookups != null && lookups.isNotEmpty) {
      request['lookups'] = lookups;
    }
    // Enables 2-arg LOOKUP(key, field) in evaluated exprs by binding the
    // synthetic / explicit single-block pre_pass name. Required for the
    // legacy single-block `pre_pass: {when, key, values}` form whose
    // implicit name is `_default` — without this the expr layer returns
    // `LookupRequiresName`.
    if (singlePrepassName != null && singlePrepassName.isNotEmpty) {
      request['single_prepass_name'] = singlePrepassName;
    }

    // In-process via the bridge (no spawn). Same `{results:[...]}`
    // shape, so `_parseBatchResults` works unchanged.
    final bridge = _bridge();
    if (bridge == null) {
      _lastSubprocessDiag = 'evalBatch: bridge unavailable';
      return const [];
    }
    final raw =
        bridge.inspect(jsonEncode({'op': 'eval_batch', 'request': request}));
    if (raw == null) {
      _lastSubprocessDiag = 'evalBatch: bridge_inspect failed';
      return const [];
    }
    return _parseBatchResults(raw);
  }

  /// Parse the `{"results":[...]}` shape from `the bridge expr batch`.
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

  /// Parse NDJSON from `the bridge expr trace` (or the bridge equivalent)
  /// into a per-call list, dropping the final/error sentinel and any
  /// malformed lines. Shared between the bridge and subprocess paths so
  /// the same payload shape produces identical parsed results.
  static List<ExprCallTrace> _parseTraceNdjson(String out) {
    final calls = <ExprCallTrace>[];
    for (final line in out.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // One bad NDJSON line must NOT discard the rest of the trace —
      // per-line try/catch so a malformed sentinel from a future the bridge
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


  /// Spawn `bxp-cli` with `--trace=bin --trace-file=<btraceOutPath>`.
  ///
  /// `--trace=bin` emits the binary BXTB stream on stdout — this is the
  /// primary live source the GUI feeds frame-by-frame into its sparse
  /// trace model as bytes arrive (no waiting for the process to exit).
  /// `--trace-file` writes the same byte sequence to disk in parallel so
  /// the file persists for post-run drill-down (mmap reads at
  /// `source_locator` etc.) — useful for large datasets where the GUI
  /// drops the in-RAM frame backing once the model is built.
  ///
  /// `--trace` implies `--quiet`, so there is no per-template stdout
  /// summary block on this path; all progress signals come from the
  /// binary stream itself (file_start / file_end / output_row frames).
  /// stderr still streams chunk-by-chunk via [onStderr] for warnings.
  static Future<ProcessRunResult> runWithBtrace({
    required String configPath,
    required String templateId,
    required String btraceOutPath,
    required bool dryRun,
    void Function(List<int> chunk)? onStdoutChunk,
    void Function(String chunk)? onStderr,
    void Function(int handle)? onBridgeSpawn,
  }) async {
    final endAction = DiagnosticLog.action(
      'runWithBtrace',
      {'config': configPath, 'template': templateId, 'bxtb': btraceOutPath},
    );
    final bin = findBin('bxp-cli');
    if (bin == null) {
      endAction({'result': 'binary_missing'});
      return const ProcessRunResult(
        exitCode: ProcessRunResult.kExitBinaryMissing,
        stderr: 'bxp-cli binary not found',
      );
    }
    final configFile = File(configPath);
    if (!configFile.existsSync()) {
      endAction({'result': 'config_missing'});
      return ProcessRunResult(
        exitCode: ProcessRunResult.kExitConfigMissing,
        stderr: 'config file not found: $configPath',
      );
    }
    final workingDir = configFile.parent.path;
    final args = <String>[
      '--config',
      configPath,
      if (templateId.isNotEmpty) ...['--template', templateId],
      if (dryRun) '--dry-run',
      '--trace=bin',
      '--trace-file=$btraceOutPath',
    ];

    // bxp-cli streams the binary BXTB frame stream through
    // bridge_run_streaming on every platform: dart:io's Process.start
    // suffers ~8 KB pipe truncation on the multi-MB stream on Windows
    // (dart-lang/sdk#1727), and the bridge is now the single backend
    // everywhere (the Process.start path was retired with the bridge
    // fallback). The bridge drains the pipe in native Zig code.
    // Cancellation goes through the [onBridgeSpawn] handle +
    // `cancelBtrace(handle)` since there is no [Process] object here.
    if (_bridge() == null) {
      endAction({'result': 'bridge_unavailable'});
      return ProcessRunResult(
        exitCode: -1,
        stderr: 'bridge: ${_lastSubprocessDiag ?? "library unavailable"}',
      );
    }
    return _runWithBtraceViaBridge(
      bin: bin,
      args: args,
      cwd: workingDir,
      dllPath: _bridgeLibPath!,
      onStdoutChunk: onStdoutChunk,
      onStderr: onStderr,
      onBridgeSpawn: onBridgeSpawn,
      endAction: endAction,
    );
  }

  /// Bridge variant of [runWithBtrace]. Streams the binary BXTB frames
  /// via `bridge_run_streaming` so dart:io's anonymous pipe truncation
  /// on Windows (sdk#1727) doesn't bite. Cancellation
  /// goes through [cancelBtrace] — the bridge handle is the caller's
  /// only path to kill the child, since there is no [Process] object in
  /// this path.
  static Future<ProcessRunResult> _runWithBtraceViaBridge({
    required String bin,
    required List<String> args,
    required String cwd,
    required String dllPath,
    void Function(List<int> chunk)? onStdoutChunk,
    void Function(String chunk)? onStderr,
    void Function(int handle)? onBridgeSpawn,
    required void Function(Map<String, dynamic>) endAction,
  }) async {
    final client = BridgeClient(dllPath);
    int stdoutBytes = 0;
    final stderrBuf = StringBuffer();
    try {
      final exitCode = await client.runStreamingBinary(
        bin,
        args,
        cwd: cwd,
        onSpawn: (handle) {
          if (onBridgeSpawn != null) onBridgeSpawn(handle);
        },
        onChunk: (chunk) {
          stdoutBytes += chunk.length;
          if (onStdoutChunk != null) onStdoutChunk(chunk);
        },
        onStderr: (chunk) {
          stderrBuf.write(chunk);
          if (onStderr != null) onStderr(chunk);
        },
      );
      endAction({
        'path': 'bridge',
        'exit': exitCode,
        'stdout_bytes': stdoutBytes,
        'stderr_bytes': stderrBuf.length,
      });
      return ProcessRunResult(
        exitCode: exitCode,
        stderr: stderrBuf.toString(),
      );
    } catch (e) {
      endAction({'result': 'bridge_stream_failed', 'error': e.toString()});
      return ProcessRunResult(
        exitCode: -1,
        stderr: 'bridge stream: $e',
      );
    }
  }

  /// Cancel a btrace bridge run. [handle] is the opaque value delivered
  /// to the `onBridgeSpawn` callback of [runWithBtrace]; the bridge
  /// signals the child (SIGTERM / TerminateProcess) and the streaming
  /// future resolves naturally with the exit code. No-op for unknown
  /// handles (already exited).
  static void cancelBtrace(int handle) {
    if (_bridge() == null) return;
    try {
      BridgeClient(_bridgeLibPath!).cancel(handle);
    } catch (_) {
      // Best-effort — cancel is idempotent and the run will resolve
      // anyway when the child exits or the watchdog fires.
    }
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
  /// in place of the usual stderr — see `_runOneShotViaBridge`.
  static const int kExitTimeout = -3;

  final int exitCode;
  final String stderr;
  const ProcessRunResult({required this.exitCode, required this.stderr});
}

/// One entry returned by `the bridge template list` — used to render the
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

/// One entry from a `the bridge expr batch` result array.
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
