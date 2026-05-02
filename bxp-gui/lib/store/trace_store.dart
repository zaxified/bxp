import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:json_ast_proto/ast.dart';
import 'package:json_ast_proto/operations.dart' as ast_ops;
import '../services/ast_loader.dart';
import '../services/ast_patch_client.dart';
import '../services/ast_to_legacy_map.dart';
import '../services/bxp_process_client.dart';
import '../services/dev_trace.dart';
import '../services/op_log.dart';
import '../services/op_to_ast.dart';
import 'trace_model.dart';
import 'trace_builder.dart';
import '../ui/theme/bxp_text_scheme.dart';

enum RunMode { none, dry, full }
enum RunStatus { idle, running, done, error }

/// 4-state badge for the live expression validator. Mirrors bxp-ui's
/// ExprPanel/Playground ValidationState union.
enum ExprValidationState { idle, pending, ok, error }

class TraceStore extends ChangeNotifier {
  // Config
  String configPath = '';
  String templateId = '';

  // Active theme preset identifier. Do not import bxp_theme.dart here —
  // the enum lives under ui/theme/ and loading it in store would create a
  // UI → store → UI import cycle. We store the preset name as a string and
  // let ui/theme/bxp_theme.dart resolve it.
  String _themePresetName = 'slate';
  String get themePresetName => _themePresetName;

  // Active sans/prose typography scheme. Resolved by BxpTextScheme in
  // ui/theme/bxp_text_scheme.dart. Persisted via SharedPreferences key
  // `bxp-ui.textScheme`. Default 'roboto' = Material bundled, always
  // renders.
  String _textSchemeName = 'roboto';
  String get textSchemeName => _textSchemeName;
  BxpTextScheme get textScheme =>
      bxpTextSchemes[_textSchemeName] ?? kBxpTextRoboto;

  // Ctrl+/Ctrl-/Ctrl+wheel UI zoom factor. Persisted under `bxp-gui.zoom`
  // so power users don't have to re-zoom after every restart.
  double _zoom = 1.0;
  double get zoom => _zoom;


  // Runtime State
  RunStatus status = RunStatus.idle;
  RunMode runMode = RunMode.none;
  String? runError;
  String stderrText = '';
  int rawLines = 0;
  // Live trace-line counter exposed as a ValueNotifier so the StatusBar's
  // "trace lines" cell can rebuild at ~10 Hz during a stream WITHOUT
  // calling main `notifyListeners()` (which would also rebuild RowList /
  // FileList / OutputPanel and turn the dry-run into an O(N²) PlutoGrid
  // re-allocation storm).
  final ValueNotifier<int> traceLinesCounter = ValueNotifier(0);
  // Bumped on every `file_start` event so FileList can grow live during a
  // stream without main `notifyListeners()`. RowList does NOT listen to
  // this — once the first file's auto-select fires (single main notify on
  // first `file_end`), the grid renders once and stays put for the rest
  // of the run.
  final ValueNotifier<int> fileGen = ValueNotifier(0);
  // Exit code from the most recent dry-run / full-run, captured so the
  // status bar can show "done · exit N" with the right colour:
  //   0 → success (emerald), 2 → completed with warnings (amber),
  //   anything else → red. Mirrors bxp-ui's StatusBar logic.
  int? lastExitCode;
  
  Map<String, dynamic>? configJson;

  /// Phase 5c-A: AST is the live source of truth. Every mutation applies
  /// to `_astRoot` first via `op_to_ast.applyConfigOp`; `configJson` is
  /// then regenerated via `AstToLegacyMap.convert` so the existing UI
  /// (still on the Map shape) stays in sync. Save / validate dump from
  /// the same tree, eliminating the dual-mutation class of bugs that
  /// plagued the Map-mutating earlier phases.
  JsonAstNode? _astRoot;

  /// Phase 5c-C: read-only view of the live AST for UI components that
  /// have been migrated off the legacy `configJson` Map (output_panel,
  /// schema_gate, …). Components MUST NOT mutate the returned tree —
  /// edits go through TraceStore mutation methods so op_log + history
  /// stay coherent with the visible state.
  JsonAstNode? get astRoot => _astRoot;

  /// Raw file bytes at load time. Kept verbatim so the AST patcher can
  /// replay the user's edit log against them at save time without
  /// re-rendering the whole file. Bytes (not String) — UTF-16 indexing on
  /// a Dart String would corrupt multi-byte UTF-8 (em dashes, accents, …).
  List<int>? _rawConfigInput;

  /// Append-only log of edits since load. Replayed at save time.
  final OpLog _opLog = OpLog();
  String? configError;
  // True while a loadConfig spawn is in flight. Mirrors bxp-ui's
  // `configStatus === "loading"` so ConfigView can show a "Loading…"
  // placeholder instead of momentarily flashing "Config not parsed."
  // when the bxp-fmt spawn takes more than a frame to return.
  bool isLoadingConfig = false;
  
  // Data
  TraceModel? traceModel;
  
  // UI Selection State
  String? selectedFileId;
  String? selectedRowId;

  // Expression editor state
  List<String>? selectedExprPath;
  String selectedExprText = '';
  // The text the editor was opened with — i.e. the value committed in
  // configJson at the time of selection, plus whatever Apply has pushed
  // since. The Reset button restores the editor to this baseline; without
  // a separate field we can't tell the original text from the working
  // copy because every keystroke flows through `selectedExprText`.
  String selectedExprBaseline = '';
  String? exprValidationError;
  // Validation lifecycle. Mirrors bxp-ui's 4-state badge so the editor
  // and Playground can show "checking…" while a validateExpr spawn is
  // in flight (200ms debounce + bxp-fmt round-trip), then flip to
  // "valid"/"invalid" when the result lands.
  //   idle    — no expression selected OR text is whitespace
  //   pending — debounce timer running OR spawn in flight
  //   ok      — last validation returned no error
  //   error   — last validation reported an error (see exprValidationError)
  ExprValidationState exprValidationState = ExprValidationState.idle;
  int exprGeneration = 0;

  // App Navigation state
  int activeTabIndex = 0;

  void setActiveTab(int index) {
    if (activeTabIndex != index) {
      activeTabIndex = index;
      notifyListeners();
    }
  }

  // Per-call expression trace cache for the hover-on-token feature. Keyed
  // by `"${rowId}::${exprText}"`. Each entry is the parsed NDJSON output of
  // `bxp-fmt --expr-trace` for that (row, expr) pair — list may be empty
  // when the expression has no function calls or the spawn failed. The
  // separate in-flight set prevents duplicate spawns when several Tooltip
  // widgets request the same expression on the same frame.
  final Map<String, List<ExprCallTrace>> _exprCallCache = {};
  final Set<String> _exprCallInFlight = {};

  String _exprCallKey(String rowId, String expr) => '$rowId::$expr';

  /// Returns the cached per-call trace for an expression in a row, or null
  /// if no spawn has completed yet. Callers that want to populate the cache
  /// must first invoke [requestExprCallTrace] (typically from a post-frame
  /// callback during a build that detects a function token in the spans).
  List<ExprCallTrace>? exprCallTraces(String rowId, String expr) {
    return _exprCallCache[_exprCallKey(rowId, expr)];
  }

  /// Lazily kicks off `bxp-fmt --expr-trace` for the given (row, expr) pair.
  /// No-op when the cache already holds a result or another spawn is in
  /// flight. Calls [notifyListeners] when the result lands so widgets that
  /// depend on the cache rebuild and display the per-call values.
  void requestExprCallTrace(String rowId, String expr) {
    final key = _exprCallKey(rowId, expr);
    if (_exprCallCache.containsKey(key)) return;
    if (_exprCallInFlight.contains(key)) return;
    final row = traceModel?.rows[rowId];
    if (row == null) return;
    final file = traceModel?.files[row.fileId];
    if (file == null) return;
    // Snapshot row state — the row may change (or be cleared) while the
    // spawn is in flight; we want the trace to match the row at request
    // time, not whatever happens to be selected when it returns.
    final headers = List<String>.from(file.headers);
    final fields = List<String>.from(row.fields);
    _exprCallInFlight.add(key);
    () async {
      final calls = await BxpProcessClient.traceExpr(
        expr: expr,
        headers: headers,
        fields: fields,
      );
      _exprCallCache[key] = calls;
      _exprCallInFlight.remove(key);
      notifyListeners();
    }();
  }

  /// Resolve the conversion-template id for the currently-selected row.
  /// Falls back to the global `templateId` (set when the user explicitly
  /// picks a template tab); if neither is set we return null and the
  /// jump-to-config helpers refuse to build a path with an empty segment
  /// — which would land on `conversion_templates > > … > <var>` and
  /// silently fail to reveal the leaf.
  String? _activeTemplateId() {
    final rowId = selectedRowId;
    if (rowId != null) {
      final row = traceModel?.rows[rowId];
      if (row != null) {
        final file = traceModel?.files[row.fileId];
        final t = file?.template;
        if (t != null && t.isNotEmpty) return t;
      }
    }
    return templateId.isNotEmpty ? templateId : null;
  }

  /// Convert a real-only array index (the kind bxp-cli emits in trace
  /// events) into a Dart raw index against `configJson` along [parentPath].
  /// Returns the raw index, or null when the parent path can't be resolved
  /// or the target slot doesn't exist.
  ///
  /// This is needed because:
  ///   * bxp-cli iterates the in-memory config (no comments) and emits
  ///     `rule_index: 2` for the third rule.
  ///   * `configJson` is the annotated parse tree where `$comm_*` wrappers
  ///     occupy real slots in the parsed list.
  ///   * `JsonTree` paths and op_log paths use the Dart raw index, so
  ///     the same rule may be at raw index 3 if a leading comment exists.
  int? _realToRawListIndex(List<String> parentPath, int realIdx) {
    final root = configJson;
    if (root == null) return null;
    dynamic cur = root;
    for (final seg in parentPath) {
      if (cur is Map) {
        cur = cur[seg];
      } else if (cur is List) {
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= cur.length) return null;
        cur = cur[i];
      } else {
        return null;
      }
      if (cur == null) return null;
    }
    if (cur is! List) return null;
    int seen = 0;
    for (int i = 0; i < cur.length; i++) {
      final v = cur[i];
      // "Is comment wrapper?" predicate: a Map where every key starts with
      // `$` (the only kind of element the parser emits as a wrapper rather
      // than a real value).
      final isCommWrapper = v is Map &&
          v.keys.every((k) => k.toString().startsWith(r'$'));
      if (isCommWrapper) continue;
      if (seen == realIdx) return i;
      seen++;
    }
    return null;
  }

  void jumpToConfigRule(int ruleIndex, String whenExpr) {
    final tmpl = _activeTemplateId();
    if (tmpl == null) return;
    final parentPath = ['conversion_templates', tmpl, 'row_rules'];
    final raw = _realToRawListIndex(parentPath, ruleIndex) ?? ruleIndex;
    setActiveTab(0);
    final path = [...parentPath, raw.toString(), 'when'];
    setSelectedExpr(path, whenExpr);
  }

  /// Jump to a top-level `input_schema.<varName>` expression in the
  /// template the currently-selected row belongs to. Used by Variables-
  /// table row clicks.
  void jumpToConfigVar(String varName, String exprText) {
    final tmpl = _activeTemplateId();
    if (tmpl == null) return;
    setActiveTab(0);
    final path = ['conversion_templates', tmpl, 'input_schema', varName];
    setSelectedExpr(path, exprText);
  }

  /// Jump to an override expression inside a row_rules block:
  /// `row_rules[ruleIndex].rows[outputRowIndex].<varName>`. Used by
  /// Rule-Results table cell clicks. Both list indices arrive from
  /// trace events (real-only) and need conversion to Dart raw indices
  /// before they'll match a JsonTree leaf.
  void jumpToConfigRuleVar(
    int ruleIndex,
    int outputRowIndex,
    String varName,
    String exprText,
  ) {
    final tmpl = _activeTemplateId();
    if (tmpl == null) return;
    final rulesPath = ['conversion_templates', tmpl, 'row_rules'];
    final ruleRaw = _realToRawListIndex(rulesPath, ruleIndex) ?? ruleIndex;
    final rowsPath = [...rulesPath, ruleRaw.toString(), 'rows'];
    final rowRaw = _realToRawListIndex(rowsPath, outputRowIndex) ?? outputRowIndex;
    setActiveTab(0);
    final path = [...rowsPath, rowRaw.toString(), varName];
    setSelectedExpr(path, exprText);
  }

  // Debouncer for expression validation. Spawn-based validateExpr costs
  // ~10–20ms per call — fine when fired on explicit selection, but would
  // hammer the CLI on every keystroke. 200ms balances responsiveness
  // against CPU load and feels instant to the typist.
  Timer? _validationDebounce;

  void setSelectedExpr(List<String> path, String text) {
    selectedExprPath = path;
    selectedExprText = text;
    selectedExprBaseline = text;
    exprGeneration++;
    // Opening a new leaf: start in pending state so the badge reads
    // "checking" instead of stale-flashing the previous result.
    exprValidationState = text.trim().isEmpty
        ? ExprValidationState.idle
        : ExprValidationState.pending;
    // Validate immediately when a new expression is opened — the user has
    // not just typed a character, so no debounce is needed.
    _validateNow(text);
    notifyListeners();
  }

  void updateSelectedExprText(String text) {
    selectedExprText = text;
    // Flip to pending immediately so the user sees "checking…" the
    // moment they start typing — not after the 200ms debounce + spawn.
    exprValidationState = text.trim().isEmpty
        ? ExprValidationState.idle
        : ExprValidationState.pending;
    notifyListeners();
    // Typing: debounce the spawn so rapid keystrokes don't queue runs.
    _validationDebounce?.cancel();
    _validationDebounce = Timer(const Duration(milliseconds: 200), () {
      if (selectedExprText == text) _validateNow(text);
    });
  }

  void _validateNow(String text) async {
    if (text.trim().isEmpty) {
      exprValidationError = null;
      exprValidationState = ExprValidationState.idle;
      notifyListeners();
      return;
    }
    final err = await BxpProcessClient.validateExpr(text);
    // Guard against races: the selected expression may have changed while
    // the spawn was in flight.
    if (selectedExprText != text) return;
    exprValidationError = err;
    exprValidationState = err == null
        ? ExprValidationState.ok
        : ExprValidationState.error;
    notifyListeners();
  }

  // ── Live config validation ───────────────────────────────────────────
  //
  // Each op (edit/insert/delete/duplicate/move) schedules a debounced
  // re-spawn of `bxp-fmt --config` so the user sees `$err_*` markers in
  // the tree as soon as a change breaks syntax. Without this, validation
  // ran only at save — which wrote a broken file before the user had a
  // chance to undo, trapping them in readonly-on-reload mode.
  Timer? _configValidateDebounce;
  bool _configValidating = false;

  /// Snapshot of "did this file contain `$err_*` at load time?" Drives the
  /// readonly toolbar gate. Live errors introduced by edits do NOT flip
  /// this — the user needs to keep editing to fix them.
  bool _loadedWithErrors = false;
  bool get configLoadHadErrors => _loadedWithErrors;

  /// Ops slice that matches the current undo position. `_historyIndex`
  /// equals the number of ops applied at this snapshot (history[0] is the
  /// load-time baseline = 0 ops, history[i] = state after i ops). Edits
  /// truncate the op log to this index before recording, so after a normal
  /// edit `_opLog.ops.length == _historyIndex`. After undo without a new
  /// edit they diverge — slice to keep validator/save in sync.
  List<ConfigOp> get _activeOps {
    final n = _historyIndex < 0 ? 0 : _historyIndex;
    return n >= _opLog.ops.length ? _opLog.ops : _opLog.ops.sublist(0, n);
  }

  void _scheduleConfigValidation() {
    _configValidateDebounce?.cancel();
    _configValidateDebounce = Timer(const Duration(milliseconds: 250), () {
      _validateConfigNow();
    });
  }

  Future<void> _validateConfigNow() async {
    if (_configValidating) return;
    if (configJson == null || configPath.isEmpty) return;
    if (isSaving) return; // saveConfig runs its own validation
    final raw = _rawConfigInput;
    if (raw == null) return;
    _configValidating = true;
    final tmpPath = '$configPath.bxp-live';
    final tmpFile = File(tmpPath);
    try {
      final outBytes = AstPatchClient.apply(raw, _activeOps);
      await tmpFile.writeAsString(utf8.decode(outBytes), flush: true);
      final out = await BxpProcessClient.loadConfig(tmpPath);
      final parsed = jsonDecode(out);
      if (parsed is! Map) return;
      // Sync only $err_* diagnostic markers from the reparsed tree into
      // the live tree, instead of replacing configJson wholesale. The
      // wholesale replace was causing $comm_<N> ID drift across reparse:
      // bxp-fmt assigns IDs by source order on every reparse, but the
      // OpLog and the LIVE tree must agree on which comment is "$comm_3"
      // for follow-up ops to land on the right entry. Keeping the tree
      // mutated in place by user ops only (live edits in trace_store +
      // AST patcher on save) makes IDs stable for the duration of the
      // session — fresh IDs only on save+reload.
      _syncErrMarkers(configJson!, parsed);
      _recomputeDirty();
      notifyListeners();
    } catch (_) {
      // Best-effort: a transient parse failure shouldn't block edits.
    } finally {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      _configValidating = false;
    }
  }

  /// Walk [src] (the reparsed tree) and copy any `$err_*` markers into [dst]
  /// (the live tree) at structurally-matching paths. Also drop stale
  /// `$err_*` from [dst] where [src] has none. Skips `$comm_*`/`$meta_*`
  /// entries since their IDs may differ between trees.
  static void _syncErrMarkers(dynamic dst, dynamic src) {
    if (dst is Map && src is Map) {
      // Drop existing $err_* from dst — they'll be repopulated below.
      final stale = dst.keys
          .where((k) => k.toString().startsWith(r'$err_'))
          .toList();
      for (final k in stale) {
        dst.remove(k);
      }
      // Copy $err_* from src; recurse into matching real-key children.
      src.forEach((k, v) {
        final key = k.toString();
        if (key.startsWith(r'$err_')) {
          dst[key] = v;
        } else if (!key.startsWith(r'$')) {
          if (dst.containsKey(key)) {
            _syncErrMarkers(dst[key], v);
          }
        }
      });
    } else if (dst is List && src is List) {
      // Best-effort: walk by index. New/removed elements throw off the
      // alignment; on misalignment we just skip (no live $err_ for that
      // sub-tree until next op + reparse).
      final n = dst.length < src.length ? dst.length : src.length;
      for (int i = 0; i < n; i++) {
        _syncErrMarkers(dst[i], src[i]);
      }
    }
  }

  /// Phase 5c-A: collect every `$err_*` map entry currently attached to
  /// [tree], keyed by the path of its parent map. Used before regenerating
  /// `configJson` from the AST adapter (which produces a fresh tree with
  /// no error markers) so the markers can be re-spliced afterwards. Without
  /// this, every keystroke would briefly clear the red dots until the
  /// debounced bxp-fmt validator fires again.
  static Map<String, Map<String, dynamic>> _collectErrMarkers(dynamic tree) {
    final out = <String, Map<String, dynamic>>{};
    void walk(dynamic node, List<String> path) {
      if (node is Map) {
        for (final e in node.entries) {
          final key = e.key.toString();
          if (key.startsWith(r'$err_')) {
            final pathKey = path.join(' ');
            (out[pathKey] ??= <String, dynamic>{})[key] = e.value;
          } else if (!key.startsWith(r'$')) {
            walk(e.value, [...path, key]);
          }
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], [...path, i.toString()]);
        }
      }
    }
    walk(tree, const []);
    return out;
  }

  /// Splice [markers] (keyed by parent-path joined with ` `) back into
  /// the freshly-regenerated [tree]. Skips entries whose parent path no
  /// longer exists or no longer points at a Map (e.g. the user deleted the
  /// containing entry between marker capture and re-merge).
  static void _reapplyErrMarkers(
      dynamic tree, Map<String, Map<String, dynamic>> markers) {
    if (markers.isEmpty) return;
    for (final entry in markers.entries) {
      final pathSegs =
          entry.key.isEmpty ? const <String>[] : entry.key.split(' ');
      dynamic cur = tree;
      var ok = true;
      for (final seg in pathSegs) {
        if (cur is Map && cur.containsKey(seg)) {
          cur = cur[seg];
        } else if (cur is List) {
          final idx = int.tryParse(seg);
          if (idx == null || idx < 0 || idx >= cur.length) {
            ok = false;
            break;
          }
          cur = cur[idx];
        } else {
          ok = false;
          break;
        }
      }
      if (!ok || cur is! Map) continue;
      for (final m in entry.value.entries) {
        cur[m.key] = m.value;
      }
    }
  }

  void clearSelectedExpr() {
    selectedExprPath = null;
    selectedExprText = '';
    selectedExprBaseline = '';
    exprValidationError = null;
    exprValidationState = ExprValidationState.idle;
    notifyListeners();
  }

  TraceStore() {
    _init();
  }

  /// True after [_init] finishes — successfully OR with a fatal error.
  /// BxpApp gates MainView/FatalErrorView on this so the user sees a
  /// clean splash for the brief async setup window.
  bool _initialized = false;
  bool get initialized => _initialized;

  /// Set by [_init] when bxp-fmt is missing or its `--docs` output is
  /// invalid. Non-null = render a blocking fatal-error screen and refuse
  /// every other operation. Null = normal operation; docs guaranteed loaded.
  String? _fatalStartupError;
  String? get fatalStartupError => _fatalStartupError;

  /// Versions of the three components, populated once at [_init] time.
  /// `bxpGuiVersion` comes from the embedded pubspec metadata via
  /// `package_info_plus` — same single-source-of-truth pattern as bxp-cli /
  /// bxp-fmt, where `build.zig` reads `.version` from `build.zig.zon` and
  /// injects it as a comptime constant. Bumping the version anywhere in the
  /// monorepo therefore requires touching exactly one manifest.
  /// Null = lookup failed (binary missing, --version returned non-zero, etc.);
  /// the SettingsInspector renders "(unknown)" in that case.
  String? bxpGuiVersion;
  String? bxpCliVersion;
  String? bxpFmtVersion;

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    // Defensive reads — a corrupt/older prefs store should never crash
    // the app or leave it in a half-loaded state. On any single read
    // failure we silently keep the field's default value.
    try {
      final stored = prefs.getString('bxp-ui.theme');
      if (stored != null && stored.isNotEmpty) _themePresetName = stored;
    } catch (_) {}
    try {
      final ts = prefs.getString('bxp-ui.textScheme');
      if (ts != null && ts.isNotEmpty && bxpTextSchemes.containsKey(ts)) {
        _textSchemeName = ts;
      }
    } catch (_) {}
    try {
      final z = prefs.getDouble('bxp-gui.zoom');
      if (z != null && z.isFinite && z >= 0.5 && z <= 3.0) _zoom = z;
    } catch (_) {}
    try {
      _recentFiles = prefs.getStringList('bxp-ui.recent') ?? [];
    } catch (_) {}
    try {
      _customPlaces = prefs.getStringList('bxp-gui.customPlaces') ?? [];
    } catch (_) {}
    notifyListeners();

    // Pull the canonical docs catalog from the CLI. AWAITED on purpose —
    // bxp-fmt is the single source of truth for the expression catalog
    // (functions / keywords / operators / tokens / config schema). The GUI
    // used to ship hand-maintained fallback constants, but they drifted
    // from the live catalog and needed parallel maintenance. Now: if the
    // binary is missing or `--docs` returns garbage, we set a fatal
    // startup error and the app renders a blocking error screen instead
    // of MainView (see BxpApp.home in main.dart). Once we reach the
    // _initialized=true happy path, every consumer can read store.docX
    // directly without a fallback branch.
    final fmtBin = BxpProcessClient.findBin('bxp-fmt');
    if (fmtBin == null) {
      final envPath = Platform.environment['BXP_FMT_PATH'] ?? '(unset)';
      final exe = Platform.resolvedExecutable;
      final exeDir = File(exe).parent.path;
      final cwd = Directory.current.path;
      _fatalStartupError =
          'bxp-fmt binary not found.\n\n'
          'The GUI requires bxp-fmt to validate configs, evaluate expressions, '
          'and load the docs catalog (functions / keywords / operators / tokens / '
          'config schema). Without it nothing in the editor would work.\n\n'
          'Searched (in order):\n'
          '  • \$BXP_FMT_PATH environment variable = $envPath\n'
          '  • bxp-fmt in the same directory as bxp_gui = $exeDir/bxp-fmt\n\n'
          'Diagnostics:\n'
          '  • Platform.resolvedExecutable = $exe\n'
          '  • Directory.current (PWD) = $cwd';
    } else {
      final d = await BxpProcessClient.getDocs();
      if (d == null) {
        _fatalStartupError =
            'bxp-fmt --docs failed.\n\n'
            'Found bxp-fmt at: $fmtBin\n\n'
            'Calling it with --docs returned no parseable JSON. The binary may '
            'be from an incompatible bxp-fmt version (the GUI requires the '
            '--docs flag), or its output is corrupted. Rebuild bxp-fmt from '
            'the current monorepo and restart the GUI.';
      } else {
        docs = d;
      }
    }

    // Probe versions in parallel — all three calls are independent and can
    // tolerate failure (any null surfaces as "(unknown)" in the inspector).
    // Run alongside the docs catalog so MainView opens with versions ready.
    Future<String?> guiVer() async {
      try {
        final p = await PackageInfo.fromPlatform();
        return p.version;
      } catch (_) {
        return null;
      }
    }
    final results = await Future.wait<String?>([
      guiVer(),
      BxpProcessClient.getVersion('bxp-cli'),
      BxpProcessClient.getVersion('bxp-fmt'),
    ]);
    bxpGuiVersion = results[0];
    bxpCliVersion = results[1];
    bxpFmtVersion = results[2];

    _initialized = true;
    notifyListeners();

    // Intentionally NO startup auto-load. bxp-gui always opens with an
    // empty editor; the user picks a file via Ctrl+O / OPEN button (the
    // OpenDialog seeds its starting directory from recentFiles[0] so the
    // MRU list is still useful for fast access). This diverges from
    // bxp-ui's getStartupConfig RPC by design — opaque "where did this
    // come from?" surprises after a crash/restart are worse than one
    // explicit dialog interaction per session.
  }

  // Recently opened config paths, MRU order. Persisted across sessions
  // so the OpenDialog can offer them as a quick-pick list — mirrors
  // bxp-ui's `recentFiles` zustand slice.
  static const _recentMax = 10;
  List<String> _recentFiles = [];
  List<String> get recentFiles => List.unmodifiable(_recentFiles);

  // Live function/keyword/operator/token/config-schema catalog from
  // `bxp-fmt --docs`. Single source of truth — the CLI's own dispatcher
  // emits the same data, so the UI catalog can never drift from
  // what the runtime actually supports. Null until the spawn completes
  // (or stays null if the binary is missing).
  Map<String, dynamic>? docs;
  List<Map<String, dynamic>> get docFunctions =>
      ((docs?['functions'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get docKeywords =>
      ((docs?['keywords'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get docOperators =>
      ((docs?['operators'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get docTokens =>
      ((docs?['tokens'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get docConfigSchema =>
      ((docs?['config_schema'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  /// Resolve [path] (segments excluding the synthetic 'config' root) against
  /// `docConfigSchema`. Returns the matching FieldDoc entry or null when the
  /// docs catalog hasn't loaded yet or the path doesn't match anything.
  ///
  /// Pattern semantics: `*` in a schema key matches any single segment, so
  /// `"conversion_templates.*.data_dir"` matches every template's data_dir.
  /// Mirrors `_SchemaTooltipKey._matches` in json_tree.dart — kept here so
  /// the delete guard, enum dropdown, and reorder gate share one rule.
  Map<String, dynamic>? findSchemaDoc(List<String> path) {
    if (path.isEmpty) return null;
    for (final f in docConfigSchema) {
      final pattern = f['key']?.toString() ?? '';
      final segs = pattern.split('.');
      if (segs.length != path.length) continue;
      var ok = true;
      for (int i = 0; i < segs.length; i++) {
        if (segs[i] == '*') continue;
        if (segs[i] != path[i]) { ok = false; break; }
      }
      if (ok) return f;
    }
    return null;
  }

  Future<void> _addRecentFile(String path) async {
    if (path.isEmpty) return;
    _recentFiles.remove(path);
    _recentFiles.insert(0, path);
    if (_recentFiles.length > _recentMax) {
      _recentFiles = _recentFiles.sublist(0, _recentMax);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('bxp-ui.recent', _recentFiles);
    notifyListeners();
  }

  // User-pinned directory paths shown in the OpenDialog sidebar under
  // PLACES, alongside the built-in Home/Documents shortcuts. Persisted.
  List<String> _customPlaces = [];
  List<String> get customPlaces => List.unmodifiable(_customPlaces);

  Future<void> addCustomPlace(String path) async {
    if (path.isEmpty || _customPlaces.contains(path)) return;
    _customPlaces.add(path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('bxp-gui.customPlaces', _customPlaces);
    notifyListeners();
  }

  Future<void> removeCustomPlace(String path) async {
    if (!_customPlaces.remove(path)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('bxp-gui.customPlaces', _customPlaces);
    notifyListeners();
  }

  /// Toggle between slate and zinc (kept for backwards-compat). Prefer
  /// [cycleTheme] for the 5-preset rotation used by the new TopBar.
  void toggleTheme() async {
    _themePresetName = _themePresetName == 'slate' ? 'zinc' : 'slate';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bxp-ui.theme', _themePresetName);
    notifyListeners();
  }

  /// Advances [themePresetName] through a caller-provided rotation list.
  /// We pass the order from the UI to avoid importing the theme module
  /// into the store.
  void setThemePreset(String name) async {
    if (_themePresetName == name) return;
    _themePresetName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bxp-ui.theme', _themePresetName);
    notifyListeners();
  }

  /// Pick a sans/prose typography scheme. Persisted under
  /// `bxp-ui.textScheme`. Unknown names are ignored (silently kept on
  /// previous value) — we never trust user input to map to a missing
  /// scheme.
  void setTextScheme(String name) async {
    if (_textSchemeName == name) return;
    if (!bxpTextSchemes.containsKey(name)) return;
    _textSchemeName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bxp-ui.textScheme', _textSchemeName);
    notifyListeners();
  }

  /// Set the UI zoom factor and persist under `bxp-gui.zoom`. Clamped to
  /// [0.5, 3.0] — the same range the keyboard/scroll handler enforces.
  void setZoom(double v) async {
    if (!v.isFinite) return;
    final clamped = v.clamp(0.5, 3.0);
    if (clamped == _zoom) return;
    _zoom = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('bxp-gui.zoom', _zoom);
    } catch (_) {
      // Persistence is best-effort. The user has already seen the zoom
      // change; failing the write would only silently corrupt their next
      // session, so we just swallow.
    }
  }

  void setConfigPath(String path) {
    configPath = path;
    notifyListeners();
  }

  void setTemplateId(String id) {
    templateId = id;
    notifyListeners();
  }

  Future<void> loadConfig() async {
    devTrace('loadConfig.start', {'path': configPath});
    isLoadingConfig = true;
    notifyListeners();
    try {
      if (configPath.isEmpty) {
        configJson = null;
        configError = null;
        _rawConfigInput = null;
        _templateInfos = const [];
        devTrace('loadConfig.skip', {'reason': 'empty path'});
        return;
      }

      // Phase 5a: AST is the primary loader. Parse the file via the Dart
      // JSON5 AST library; the resulting tree's source-order numbering of
      // comments drives every subsequent `$comm_<N>` label in configJson,
      // which in turn matches what the AST patcher walks at save time.
      // No more dual-numbering between bxp-fmt and AST.
      final astResult = await AstLoader.loadFromFile(configPath);
      _rawConfigInput = utf8.encode(astResult.rawText);

      if (astResult.root == null) {
        // JSON5 syntax error from the AST parser. bxp-fmt would fail too;
        // skip its call and surface the diagnostic directly.
        final firstErr = astResult.diagnostics.isNotEmpty
            ? astResult.diagnostics.first
            : null;
        configError = firstErr != null
            ? 'JSON5 parse error at ${firstErr.span.startLine}:${firstErr.span.startCol}: ${firstErr.message}'
            : 'JSON5 parse error';
        configJson = null;
        _astRoot = null;
        _loadedWithErrors = true;
        _templateInfos = const [];
        devTrace('loadConfig.astParseFail',
            {'diagnostics': astResult.diagnostics.length, 'first': configError});
        return;
      }

      // Phase 5c-A: AST is the live source of truth. Stash it; mutations
      // operate on this tree and regenerate configJson via the adapter.
      _astRoot = astResult.root;

      // Convert AST → bxp-fmt-shaped configJson via the legacy adapter.
      // `$comm_<N>` numbering in this Map matches the AST's source-order
      // walk; this is the contract that ends comment-move regressions.
      configJson =
          AstToLegacyMap.convert(_astRoot!) as Map<String, dynamic>;

      // bxp-fmt --config still runs as a background validator: parses for
      // schema / expr / pre_pass / cross-field issues that the AST parser
      // (pure JSON5) doesn't know about. We extract its `$err_*` markers
      // and merge them into our configJson at matching real-key paths.
      try {
        final jsonOutput = await BxpProcessClient.loadConfig(configPath);
        final bxpTree = jsonDecode(jsonOutput);
        if (bxpTree is Map<String, dynamic>) {
          final bxpFatal = bxpTree['error'] as String?;
          if (bxpFatal != null) {
            // bxp-fmt couldn't even parse — but AST did. Surface the
            // bxp-fmt error so the user knows about the deeper failure;
            // the editor stays openable since AST has a tree.
            configError = bxpFatal;
          } else {
            _syncErrMarkers(configJson!, bxpTree);
          }
        }
      } catch (e) {
        // bxp-fmt invocation itself failed (binary missing, crash, etc.).
        // Don't block editing on validator failures.
        configError ??= 'bxp-fmt validator unavailable: $e';
      }

      _loadedWithErrors = _findFirstErrTrace(configJson) != null;
      devTrace('loadConfig.ok', {
        'rawBytes': _rawConfigInput?.length ?? 0,
        'loadedWithErrors': _loadedWithErrors,
        'configError': configError,
      });

      // Pull richer template metadata for the selector (separate subprocess
      // call into bxp-cli; not part of the AST loader path).
      _templateInfos = await BxpProcessClient.listTemplates(configPath);
    } catch (e, st) {
      configError = e.toString();
      configJson = null;
      _rawConfigInput = null;
      _templateInfos = const [];
      devTrace('loadConfig.fail', {'err': e.toString(), 'stack': st.toString().split('\n').take(3).join(' | ')});
    } finally {
      isLoadingConfig = false;
    }
    // New load starts a fresh op log.
    _opLog.clear();
    // Empty templateId means "all templates" (bxp-cli runs every template
    // in the config when --template is omitted). Keep that as the default;
    // only drop a stale selection if the current template no longer exists.
    final templates = availableTemplates;
    if (templateId.isNotEmpty && !templates.contains(templateId)) {
      templateId = '';
    }
    // Fresh load establishes a new "clean" baseline. Everything edited
    // after this point counts as dirty until the user saves.
    _savedBaseline = _deepCopy(configJson);
    _astBaseline = _astRoot?.clone();
    _isDirty = false;
    _history.clear();
    _astHistory.clear();
    _historyIndex = 0;
    _history.add(_deepCopy(configJson));
    if (_astRoot != null) _astHistory.add(_astRoot!.clone());
    configSaveError = null;
    // Add to MRU when the load reached bxp-fmt and produced a parseable
    // response — including configs that have $err_* markers (the user
    // can still reopen them later to retry after external edits).
    // We skip the case where the spawn itself crashed (configJson=null
    // AND configError set) so paths to nonexistent / unreadable files
    // don't pollute the quick-pick list. Fire-and-forget — persistence
    // write is non-critical.
    if (configPath.isNotEmpty && configJson != null) {
      // ignore: discarded_futures
      _addRecentFile(configPath);
    }
    notifyListeners();
  }

  /// Phase 5c-A: apply [op] to the live AST, regenerate `configJson` via
  /// the adapter (preserving any `$err_*` markers attached by the
  /// background validator), record the op in `_opLog`, push history, and
  /// refresh the UI. Returns true on success; false if the AST mutation
  /// threw (in which case nothing is recorded — the live tree is unchanged
  /// and op_log stays consistent with what the AST patcher could replay).
  bool _applyOpToAst(ConfigOp op, String traceEvent,
      [Map<String, Object?>? traceData]) {
    if (_astRoot == null) return false;
    try {
      applyConfigOp(_astRoot!, op);
    } on ast_ops.AstOpError catch (e) {
      devTrace('$traceEvent.fail',
          {'err': e.toString(), if (traceData != null) ...traceData});
      return false;
    } catch (e) {
      devTrace('$traceEvent.fail',
          {'err': e.toString(), if (traceData != null) ...traceData});
      return false;
    }
    final priorErrs = _collectErrMarkers(configJson);
    final regen = AstToLegacyMap.convert(_astRoot!);
    if (regen is! Map<String, dynamic>) {
      devTrace('$traceEvent.fail', {'err': 'adapter returned non-Map root'});
      return false;
    }
    configJson = regen;
    _reapplyErrMarkers(configJson, priorErrs);
    _opLog.truncate(_historyIndex);
    devTrace(traceEvent, traceData);
    _opLog.record(op);
    return true;
  }

  void editConfigNode(List<String> path, dynamic newValue) {
    if (configJson == null) return;
    // Mirror bxp-ui's `readOnly = configHasErrors`: when the loaded tree
    // contains $err_* diagnostic markers, all mutations are blocked. The
    // ConfigView toolbar already greys out edit buttons, but the inline
    // tree editors (EditableString/Number/Boolean) commit through this
    // path — guarding here covers both surfaces uniformly.
    if (_loadedWithErrors) return;

    final oldValue = _getAt(path);
    if (oldValue == newValue) return;

    if (!_applyOpToAst(EditValueOp(path, newValue), 'op.edit',
        {'path': path, 'newValue': newValue})) {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
    _scheduleConfigValidation();
  }

  bool _isDirty = false;
  bool get isDirty => _isDirty;

  // History for Undo/Redo. [_savedBaseline] is the config as it exists on
  // disk (or as it was last loaded). Dirty status is computed by structural
  // comparison against this baseline — NOT by history index — so undoing
  // back to the loaded state correctly clears the dirty flag even after
  // the user has poked around.
  final List<dynamic> _history = [];
  int _historyIndex = -1;
  dynamic _savedBaseline;

  // Phase 5c-A: AST snapshots parallel to _history / _savedBaseline.
  // Restored on undo/redo/resetDraft so the live AST stays in lockstep
  // with the visible configJson Map.
  final List<JsonAstNode> _astHistory = [];
  JsonAstNode? _astBaseline;

  bool get canUndo => _historyIndex > 0;
  bool get canRedo => _historyIndex < _history.length - 1;

  void _pushHistory() {
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
      _astHistory.removeRange(_historyIndex + 1, _astHistory.length);
    }
    _history.add(_deepCopy(configJson));
    if (_astRoot != null) _astHistory.add(_astRoot!.clone());
    _historyIndex = _history.length - 1;
  }

  void _recomputeDirty() {
    _isDirty = !_deepEquals(configJson, _savedBaseline);
  }

  /// Discard all unsaved edits and snap configJson back to the last
  /// loaded/saved baseline. Cheaper than [loadConfig] because it doesn't
  /// re-spawn bxp-fmt — just clones `_savedBaseline` and resets the undo
  /// history. Mirrors bxp-ui's `resetDraft` action; bound to Ctrl+T.
  void resetDraft() {
    if (_savedBaseline == null) return;
    if (_loadedWithErrors) return; // edits are blocked anyway in this state
    configJson = _deepCopy(_savedBaseline);
    _astRoot = _astBaseline?.clone();
    _isDirty = false;
    _history
      ..clear()
      ..add(_deepCopy(configJson));
    _astHistory.clear();
    if (_astRoot != null) _astHistory.add(_astRoot!.clone());
    _historyIndex = 0;
    if (selectedExprPath != null) {
      final val = _getAt(selectedExprPath!);
      selectedExprText = val is String ? val : '';
      exprGeneration++;
    }
    notifyListeners();
  }

  void undo() {
    if (canUndo) {
      _historyIndex--;
      configJson = _deepCopy(_history[_historyIndex]);
      if (_historyIndex < _astHistory.length) {
        _astRoot = _astHistory[_historyIndex].clone();
      }
      _recomputeDirty();
      if (selectedExprPath != null) {
        final val = _getAt(selectedExprPath!);
        selectedExprText = val is String ? val : '';
        exprGeneration++;
      }
      notifyListeners();
      _scheduleConfigValidation();
    }
  }

  void redo() {
    if (canRedo) {
      _historyIndex++;
      configJson = _deepCopy(_history[_historyIndex]);
      if (_historyIndex < _astHistory.length) {
        _astRoot = _astHistory[_historyIndex].clone();
      }
      _recomputeDirty();
      if (selectedExprPath != null) {
        final val = _getAt(selectedExprPath!);
        selectedExprText = val is String ? val : '';
        exprGeneration++;
      }
      notifyListeners();
      _scheduleConfigValidation();
    }
  }

  bool _deepEquals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      // Map-key INSERTION ORDER must match. Reordering top-level templates
      // or output_schema entries is a key-swap that leaves the set + values
      // identical, so an order-blind comparison would treat the post-move
      // tree as equal to the saved baseline and `_isDirty` would never
      // flip — Save and Apply stay greyed out and the move silently
      // disappears. Walking entries in lockstep catches that.
      final aIt = a.entries.iterator;
      final bIt = b.entries.iterator;
      while (aIt.moveNext() && bIt.moveNext()) {
        if (aIt.current.key != bIt.current.key) return false;
        if (!_deepEquals(aIt.current.value, bIt.current.value)) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  // Vrátí hlubokou kopii dynamické hodnoty
  dynamic _deepCopy(dynamic v) {
    if (v is Map) {
      return Map<String, dynamic>.fromEntries(
        v.entries.map((e) => MapEntry(e.key.toString(), _deepCopy(e.value)))
      );
    }
    if (v is List) {
      return v.map(_deepCopy).toList();
    }
    return v;
  }

  dynamic _getAt(List<String> path) {
    dynamic cur = configJson;
    for (final key in path) {
      if (cur is Map) {
        cur = cur[key];
      } else if (cur is List) {
        final i = int.tryParse(key);
        if (i != null) {
          cur = cur[i];
        } else {
          return null;
        }
      } else {
        return null;
      }
    }
    return cur;
  }

  /// Apply [remap] to `selectedExprPath` after a structural array edit.
  /// [parentPath] is the array containing the indices that shifted; only
  /// selections sitting under that exact prefix are touched. Returning
  /// `-1` from [remap] (or whose remap matches removeIdx) clears the
  /// selection entirely — used when the selected index was deleted.
  ///
  /// Mirrors the path-shift logic that previously lived inline in
  /// [moveConfigNode]; sharing it here keeps insert/delete/duplicate/move
  /// behaviour consistent so a structural edit never strands the editor
  /// on the wrong leaf.
  void _shiftSelectionOnArrayEdit(
    List<String> parentPath,
    int Function(int oldIdx) remap,
  ) {
    if (selectedExprPath == null) return;
    if (selectedExprPath!.length <= parentPath.length) return;
    // Selected path must live strictly under the parent array.
    for (int i = 0; i < parentPath.length; i++) {
      if (selectedExprPath![i] != parentPath[i]) return;
    }
    final oldIdx = int.tryParse(selectedExprPath![parentPath.length]);
    if (oldIdx == null) return;
    final newIdx = remap(oldIdx);
    if (newIdx == oldIdx) return;
    if (newIdx < 0) {
      // The selected index was removed — drop the selection rather than
      // pointing at a sibling the user didn't click.
      clearSelectedExpr();
      return;
    }
    selectedExprPath = [
      ...parentPath,
      '$newIdx',
      ...selectedExprPath!.sublist(parentPath.length + 1),
    ];
  }

  /// True if [candidate] starts with [prefix] (segment-wise).
  static bool _pathStartsWith(List<String> candidate, List<String> prefix) {
    if (candidate.length < prefix.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (candidate[i] != prefix[i]) return false;
    }
    return true;
  }

  void deleteConfigNode(List<String> path) {
    if (configJson == null || path.isEmpty || _loadedWithErrors) return;
    // Schema-driven guard: required keys cannot be deleted from their parent
    // map. Array entries (parent is List) are always deletable — the array
    // itself may be required, but individual elements aren't.
    final parentPath = path.sublist(0, path.length - 1);
    final lastKey = path.last;
    final parent = _getAt(parentPath);
    if (parent is Map) {
      final doc = findSchemaDoc(path);
      if (doc != null && doc['required'] == true) return;
    }

    // Selection invalidation BEFORE the mutation so we can still inspect
    // the current path. Two cases that both clear the selection:
    //   - the deleted node IS the selected leaf
    //   - the deleted node is an ancestor of the selected leaf
    if (selectedExprPath != null &&
        _pathStartsWith(selectedExprPath!, path)) {
      clearSelectedExpr();
    }

    final removedIdx = parent is List ? int.tryParse(lastKey) : null;
    if (parent is List && removedIdx == null) return;

    if (!_applyOpToAst(DeleteOp(path), 'op.delete', {'path': path})) {
      return;
    }
    if (parent is List) {
      // Shift sibling-selections downward: indices > removedIdx slide
      // up by one; the removed index itself was already cleared above.
      _shiftSelectionOnArrayEdit(parentPath, (oldIdx) {
        if (oldIdx == removedIdx) return -1; // shouldn't happen (cleared)
        if (oldIdx > removedIdx!) return oldIdx - 1;
        return oldIdx;
      });
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
    _scheduleConfigValidation();
  }

  void duplicateConfigNode(List<String> path) {
    if (configJson == null || path.isEmpty || _loadedWithErrors) return;
    final parentPath = path.sublist(0, path.length - 1);
    final lastKey = path.last;
    final parent = _getAt(parentPath);
    if (parent is Map) {
      // Find unique key. The AST helper rejects collisions, but computing
      // it here keeps the op_log self-contained (replay-safe even if we
      // ever add a key-collision recovery upstream).
      String newKey = '${lastKey}_copy';
      int i = 2;
      while (parent.containsKey(newKey)) { newKey = '${lastKey}_copy$i'; i++; }
      if (!_applyOpToAst(DuplicateOp(path, newKey: newKey),
          'op.duplicate.map', {'path': path, 'newKey': newKey})) {
        return;
      }
      // Map duplicate: appended at end → no array-index shift, selection
      // unaffected (sibling keys keep their map keys).
    } else if (parent is List) {
      final idx = int.tryParse(lastKey);
      if (idx == null) return;
      if (!_applyOpToAst(DuplicateOp(path), 'op.duplicate.list', {'path': path})) {
        return;
      }
      // Selection lives under same array AND was at index >= idx+1?
      // Then it slid one slot right. Selection on the duplicated source
      // (idx) stays put — the user still has the original highlighted.
      _shiftSelectionOnArrayEdit(parentPath, (oldIdx) {
        if (oldIdx > idx) return oldIdx + 1;
        return oldIdx;
      });
    } else {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
    _scheduleConfigValidation();
  }

  /// Reorder a sibling by swapping with its adjacent peer.
  ///
  /// [path] points at the entry to move. [delta] is +1 (down) or -1 (up).
  /// Phase 5c-A: the AST `moveAt` op handles both Map and List in a single
  /// uniform "swap with adjacent container entry" operation; trailing
  /// comments come along automatically because they're peer entries
  /// (Phase 5e). The list-side selection-shift logic still runs locally
  /// since it's a UI concern, not part of the underlying mutation.
  void moveConfigNode(List<String> path, int delta) {
    if (configJson == null || path.isEmpty || _loadedWithErrors) return;
    if (delta == 0) return;
    final parentPath = path.sublist(0, path.length - 1);
    final parent = _getAt(parentPath);

    int? listIdx;
    if (parent is List) {
      listIdx = int.tryParse(path.last);
      if (listIdx == null) return;
    }

    if (!_applyOpToAst(MoveOp(path, delta), 'op.move',
        {'path': path, 'delta': delta})) {
      return;
    }

    if (parent is List && listIdx != null) {
      // The two adjacent real elements swapped; selections on either
      // follow. (Comment peers are skipped from the index shift since
      // selectedExprPath only ever points at a real-key element.)
      final movedFrom = listIdx;
      final movedTo = listIdx + delta;
      _shiftSelectionOnArrayEdit(parentPath, (oldIdx) {
        if (oldIdx == movedFrom) return movedTo;
        if (oldIdx == movedTo) return movedFrom;
        return oldIdx;
      });
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
    _scheduleConfigValidation();
  }

  /// Insert a child into the container at [path].
  ///
  /// For Map containers: [newKey] is required; the entry is appended
  /// (Map has no positional concept).
  ///
  /// For List containers: when [atIndex] is null the value is appended;
  /// otherwise it's clamped into `[0, list.length]` and inserted at that
  /// position. Mirrors bxp-ui's `insertChild` index-clamp semantics.
  /// Selections at or after the insertion point shift right by one.
  void insertConfigNode(
    List<String> path,
    String? newKey,
    dynamic defaultValue, {
    int? atIndex,
  }) {
    if (configJson == null || _loadedWithErrors) return;
    final target = _getAt(path);
    if (target is Map && newKey != null) {
      if (!_applyOpToAst(InsertOp(path, newKey, defaultValue),
          'op.insert.map', {'parentPath': path, 'newKey': newKey})) {
        return;
      }
    } else if (target is List) {
      final clamped = atIndex == null
          ? target.length
          : atIndex.clamp(0, target.length);
      if (!_applyOpToAst(InsertOp(path, clamped.toString(), defaultValue),
          'op.insert.list',
          {'parentPath': path, 'index': clamped})) {
        return;
      }
      // Selections under the same array at indices >= clamped shifted up.
      _shiftSelectionOnArrayEdit(path, (oldIdx) {
        if (oldIdx >= clamped) return oldIdx + 1;
        return oldIdx;
      });
    } else {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
    _scheduleConfigValidation();
  }

  /// Edit a comment's text body. [path] ends in `$comm_<N>`. [newText] is
  /// the body without `//` / `/* */` markers.
  void editCommentNode(List<String> path, String newText) {
    if (configJson == null || _loadedWithErrors) return;
    if (path.isEmpty || !path.last.startsWith(r'$comm_')) return;
    if (!_applyOpToAst(EditCommentOp(path, newText), 'op.editComment',
        {'path': path, 'newText': newText})) {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
    _scheduleConfigValidation();
  }

  /// Delete a standalone / leading / block comment.
  void deleteCommentNode(List<String> path) {
    if (configJson == null || _loadedWithErrors) return;
    if (path.isEmpty || !path.last.startsWith(r'$comm_')) return;
    if (!_applyOpToAst(DeleteCommentOp(path), 'op.deleteComment',
        {'path': path})) {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
    _scheduleConfigValidation();
  }

  /// Insert a fresh leading comment immediately above [anchorPath].
  /// [style] is `"//"` or `"/*"`. [text] is the body without markers.
  void insertCommentNode(List<String> anchorPath, String style, String text) {
    if (configJson == null || _loadedWithErrors) return;
    if (anchorPath.isEmpty) return;
    if (!_applyOpToAst(InsertCommentOp(anchorPath, style, text),
        'op.insertComment', {'anchorPath': anchorPath, 'style': style})) {
      return;
    }
    // Comment peers don't enter the int-indexed list address space — UI
    // selections point at real-key paths only — so no _shiftSelection is
    // needed here even when the anchor is a list element.
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
    _scheduleConfigValidation();
  }

  /// Last error thrown during saveConfig, null when the save succeeded.
  /// StatusBar surfaces this to the user.
  String? configSaveError;

  /// True while a saveConfig is in flight — write tmp, spawn bxp-fmt
  /// validation, backup, rename, reload. The toolbar SAVE button uses
  /// this to show a "SAVING…" label so the user gets feedback during
  /// the (possibly slow) round-trip. Mirrors bxp-ui's
  /// `configSaveStatus === "saving"` state.
  bool isSaving = false;

  Future<void> saveConfig() async {
    if (configJson == null || configPath.isEmpty) return;
    if (isSaving) return; // re-entrancy guard against double-click
    devTrace('saveConfig.start',
        {'path': configPath, 'opCount': _activeOps.length});
    configSaveError = null;
    isSaving = true;
    notifyListeners();
    final tmpPath = '$configPath.bxp-tmp';
    final tmpFile = File(tmpPath);
    try {
      // AST patcher: parse the original raw bytes via the Dart JSON5 AST
      // library, replay each ConfigOp from _opLog as an AST mutation, then
      // dump back to bytes through the deterministic emitter. Style is
      // canonicalised on first save; subsequent saves are stable.
      final raw = _rawConfigInput;
      if (raw == null) {
        configSaveError =
            'cannot save: original raw input unavailable (load failure?)';
        notifyListeners();
        return;
      }
      final Uint8List outBytes;
      try {
        outBytes = AstPatchClient.apply(raw, _activeOps);
      } on AstPatchError catch (e) {
        configSaveError = 'AST patch failed: ${e.message}';
        devTrace('saveConfig.astPatchFail',
            {'message': e.message, 'opCount': _activeOps.length});
        notifyListeners();
        return;
      }
      final text = utf8.decode(outBytes);

      // Write to <path>.bxp-tmp first so we can validate before touching
      // the real file. If anything goes wrong below, the original config
      // on disk stays intact.
      await tmpFile.writeAsString(text, flush: true);

      // Pre-save validation: round-trip through bxp-fmt --config. If the
      // emitter produced something the parser rejects, abort and surface
      // the diagnostic — better than silently corrupting the user's file.
      // Mirrors bxp-ui's saveConfig pre-flight check.
      final validation = await BxpProcessClient.loadConfig(tmpPath);
      try {
        final parsed = jsonDecode(validation);
        final err = parsed is Map ? parsed['error'] as String? : null;
        if (err != null) {
          await tmpFile.delete().catchError((_) => tmpFile);
          configSaveError = 'pre-save validation failed: $err';
          notifyListeners();
          return;
        }
        // bxp-fmt exits with annotated JSON (no top-level "error") even when
        // it found `$err_*` markers inside the tree — exit code 1 + stdout.
        // Without this scan, a syntactically broken save would still go
        // through and trap the user in readonly-on-reload mode.
        final treeErr = _findFirstErrTrace(parsed);
        if (treeErr != null) {
          await tmpFile.delete().catchError((_) => tmpFile);
          configSaveError = 'pre-save validation failed: $treeErr';
          notifyListeners();
          return;
        }
      } catch (_) {
        // bxp-fmt printed something unparseable — treat as failure.
        await tmpFile.delete().catchError((_) => tmpFile);
        configSaveError = 'pre-save validation produced unreadable output';
        notifyListeners();
        return;
      }

      // Backup the original before overwriting so the user has a recovery
      // path if a save turns out to be wrong. Suffix is a sortable
      // timestamp so multiple saves of the same file don't collide.
      // Mirrors bxp-ui's `${path}_${ts}` backup convention.
      final original = File(configPath);
      if (await original.exists()) {
        final ts = _backupTimestamp(DateTime.now());
        try {
          await original.copy('${configPath}_$ts');
        } catch (_) {
          // Best-effort backup; don't block the save if the FS rejects it.
        }
      }

      // Atomic rename: this is the one filesystem operation that cannot
      // leave the destination half-written.
      await tmpFile.rename(configPath);
      devTrace('saveConfig.ok',
          {'bytes': outBytes.length, 'opCount': _activeOps.length});

      // History compresses to a single "saved" baseline so the undo stack
      // starts fresh after a successful write.
      _savedBaseline = _deepCopy(configJson);
      _history
        ..clear()
        ..add(_deepCopy(configJson));
      _historyIndex = 0;
      _isDirty = false;
      _opLog.clear();
      notifyListeners();

      // Re-run bxp-fmt so validation markers ($err_/$comm_) refresh against
      // the new on-disk content. (Also captures fresh raw bytes and resets
      // the op log baseline.)
      await loadConfig();
    } catch (e, st) {
      // Clean up the tmp file if it leaked through an unexpected exception
      // path (e.g. rename failed after validation passed).
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      configSaveError = e.toString();
      devTrace('saveConfig.fail', {
        'err': e.toString(),
        'stack': st.toString().split('\n').take(3).join(' | '),
      });
      notifyListeners();
    } finally {
      // Always clear the in-flight flag so the toolbar SAVE button stops
      // showing "SAVING…" — covers all early-return paths and the
      // exception path. notifyListeners is fired below to refresh.
      isSaving = false;
      notifyListeners();
    }
  }

  /// `YYYYMMDDHHMMSS` — sortable, no separators, safe in any filesystem.
  String _backupTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  Future<void> runDryRun() => _streamRun(dry: true);
  Future<void> runFullRun() => _streamRun(dry: false);
  
  void selectFile(String? id) {
    selectedFileId = id;
    // Auto-select the first row in the newly selected file so RowDetail
    // and OutputPanel populate immediately.
    final file = id == null ? null : traceModel?.files[id];
    selectedRowId = file != null && file.rowIds.isNotEmpty ? file.rowIds.first : null;
    notifyListeners();
  }
  
  void selectRow(String? id) {
    selectedRowId = id;
    notifyListeners();
  }

  /// Spawns `bxp-cli --trace` (dry or full) and streams the NDJSON output
  /// into a fresh TraceBuilder. UI refreshes are throttled to ~60 fps so
  /// the file/row lists grow live while the pipeline still runs.
  Future<void> _streamRun({required bool dry}) async {
    if (configPath.isEmpty) return;

    status = RunStatus.running;
    runMode = dry ? RunMode.dry : RunMode.full;
    runError = null;
    stderrText = '';
    rawLines = 0;
    traceLinesCounter.value = 0;
    lastExitCode = null;
    selectedFileId = null;
    selectedRowId = null;

    // Fresh builder so subsequent runs start clean.
    final builder = TraceBuilder();
    traceModel = builder.model;
    // One main notify to flip status to running and clear stale model.
    fileGen.value++;
    notifyListeners();

    // Counter ticker — only refreshes the `trace lines` ValueNotifier.
    // Crucially does NOT call main `notifyListeners()`, so RowList /
    // OutputPanel / status-bar aggregates do not rebuild per tick.
    final ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (traceLinesCounter.value != rawLines) {
        traceLinesCounter.value = rawLines;
      }
    });

    int prevFileCount = 0;

    // bxp-cli interprets an omitted --template as "process everything".
    try {
      final spawn = dry ? BxpProcessClient.runDryRun : BxpProcessClient.runFullRun;
      final result = await spawn(
        configPath: configPath,
        templateId: templateId,
        onLine: (line) {
          rawLines++;
          builder.parseLine(line);

          // FileList grows live: bump `fileGen` whenever a new file_start
          // landed. Cheap — typical M is < 50.
          final fc = builder.model.fileOrder.length;
          if (fc != prevFileCount) {
            prevFileCount = fc;
            fileGen.value++;
          }

          // Auto-select happens exactly ONCE, on the FIRST `file_end`
          // (detected by the first file's `stats` being non-null). That
          // single main `notifyListeners()` triggers RowList to mount
          // PlutoGrid with the first file's complete row set. After that
          // we stay quiet until `done` — no further row-level rebuilds.
          if (selectedFileId == null && builder.model.fileOrder.isNotEmpty) {
            final firstId = builder.model.fileOrder.first;
            final firstFile = builder.model.files[firstId];
            if (firstFile?.stats != null) {
              selectedFileId = firstId;
              if (firstFile!.rowIds.isNotEmpty) {
                selectedRowId = firstFile.rowIds.first;
              }
              notifyListeners();
            }
          }
        },
        // Stderr is appended silently during the run; surface lands at
        // the first-file-ready notify or at the final `done` notify so
        // we don't pay a rebuild per chunk.
        onStderr: (chunk) {
          stderrText += chunk;
        },
      );

      // The streamed `onStderr` callback already filled `stderrText`
      // chunk-by-chunk during the run, so we don't reassign from
      // `result.stderr` here — that would overwrite identical data and
      // briefly flicker the StatusBar badge size. Only fall back to
      // the buffered copy if the stream produced nothing (e.g. the
      // process crashed before any chunk arrived).
      if (stderrText.isEmpty) stderrText = result.stderr;
      lastExitCode = result.exitCode;
      if (result.exitCode < 0) {
        runError = result.stderr.isEmpty ? 'spawn failed' : result.stderr;
        status = RunStatus.error;
        return;
      }
      if (builder.model.issues.isNotEmpty) {
        runError = builder.model.issues.take(3).join('; ');
      }
    } catch (e) {
      runError = e.toString();
      status = RunStatus.error;
      return;
    } finally {
      ticker.cancel();
      // Final sync — the last 100ms tick may have fired before the
      // closing batch of lines arrived, leaving the counter short of
      // the true total. Without this the displayed number is
      // non-deterministic (varies per run).
      if (traceLinesCounter.value != rawLines) {
        traceLinesCounter.value = rawLines;
      }
    }

    status = RunStatus.done;
    // Post-stream selection sync. The live onLine handler already
    // primes selectedFileId on the first file_start event, so we only
    // top-up here for the corner case where no file_start fired (e.g.
    // empty config) or a row inside the currently selected file landed
    // after the user had cleared their selection. NEVER overwrite an
    // active selection — that would yank the user out of whichever
    // file/row they navigated to mid-stream.
    if (traceModel != null && traceModel!.fileOrder.isNotEmpty) {
      selectedFileId ??= traceModel!.fileOrder.first;
      final activeFile = traceModel!.files[selectedFileId];
      if (selectedRowId == null &&
          activeFile != null &&
          activeFile.rowIds.isNotEmpty) {
        selectedRowId = activeFile.rowIds.first;
      }
    }
    notifyListeners();
  }

  /// Real template IDs from configJson (no synthetic entries). The empty
  /// string is used separately in the UI to mean "all templates".
  List<String> get availableTemplates {
    final ct = configJson?['conversion_templates'];
    if (ct is Map) {
      return ct.keys
          .cast<String>()
          .where((k) => !k.startsWith(r'$'))
          .toList();
    }
    return const [];
  }

  /// Rich template metadata (data_dir / file_pattern_in / description)
  /// pulled from `bxp-fmt --config <path> --list-templates` after each
  /// successful config load. Empty when the lookup hasn't run yet or the
  /// CLI call failed — callers fall back to [availableTemplates] for IDs.
  List<TemplateInfo> _templateInfos = const [];
  List<TemplateInfo> get availableTemplateInfos => _templateInfos;

  /// True if the last loaded config contains any `$err_*` diagnostic node.
  /// Matches bxp-ui's `configHasErrors` — used to gate run buttons and
  /// display the bxp-fmt error trace in the status bar.
  bool get configHasErrors => _findFirstErrTrace(configJson) != null;

  /// Returns the first bxp-fmt `$err_*` string found anywhere in the tree,
  /// or null if none. Matches bxp-ui's findFirstErrTrace(). Skips sibling
  /// `$comm_*` / `$err_*` nodes during recursion to avoid confusing a
  /// comment containing the word "error" for a real diagnostic.
  String? get firstConfigErrorTrace => _findFirstErrTrace(configJson);

  String? _findFirstErrTrace(dynamic v) {
    if (v is Map) {
      for (final e in v.entries) {
        final k = e.key.toString();
        if (k.startsWith(r'$err_') && e.value is String) return e.value as String;
      }
      for (final e in v.entries) {
        final k = e.key.toString();
        // Skip ALL $-prefixed keys during recursion: $err_, $comm_,
        // $meta_, $elem_meta_, $meta_self never carry user-visible
        // diagnostics in their nested structure.
        if (k.startsWith(r'$')) continue;
        final found = _findFirstErrTrace(e.value);
        if (found != null) return found;
      }
    } else if (v is List) {
      for (final item in v) {
        final found = _findFirstErrTrace(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Opens [path] in the host's default application (`xdg-open` on Linux).
  /// Used by the StatusBar pencil-icon shortcut — mirrors bxp-ui's
  /// `openInEditor` RPC.
  Future<void> openInEditor(String path) async {
    if (path.isEmpty) return;
    try {
      if (Platform.isLinux) {
        await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path], mode: ProcessStartMode.detached);
      } else if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', path],
            mode: ProcessStartMode.detached);
      }
    } catch (_) {
      // Best-effort launch; don't surface transient errors to the UI.
    }
  }
}

