import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:json5_ast/ast.dart';
import 'package:json5_ast/operations.dart' as ast_ops;
import '../services/ast_loader.dart';
import '../services/ast_patch_client.dart';
import '../services/bxp_process_client.dart';
import '../services/dart_validator.dart';
import '../services/dev_trace.dart';
import '../services/prefs_service.dart';
import '../services/op_log.dart';
import '../services/op_to_ast.dart';
import '../services/schema_doc_lookup.dart';
import 'trace_model.dart';
import 'trace_builder.dart';
import '../ui/theme/bxp_text_scheme.dart';

/// Per-severity diagnostic buckets produced by walking a `bxp-fmt
/// --config` annotated tree. Outer key: encoded parent path. Inner map:
/// `$err_<N>` / `$warn_<N>` / `$info_<N>` → message.
typedef _DiagnosticBuckets = ({
  Map<String, Map<String, String>> errors,
  Map<String, Map<String, String>> warnings,
  Map<String, Map<String, String>> info,
});

enum RunMode { none, dry, full }
enum RunStatus { idle, running, done, error }

/// 4-state badge for the live expression validator. Mirrors bxp-ui's
/// ExprPanel/Playground ValidationState union.
enum ExprValidationState { idle, pending, ok, error }

/// Central application state — the single `ChangeNotifier` that drives every
/// pane in bxp-gui. Backed by a Provider registered in `main.dart`.
///
/// Responsibilities:
///   - Config loading/saving via `AstLoader` + `AstPatchClient` + `BxpProcessClient`
///   - Undo/redo history via AST snapshots
///   - Validation: bxp-fmt `$err_*` buckets + native Dart-side `_revalidateDart`
///   - Expression editor state (selection, validation lifecycle, autocomplete gating)
///   - Streaming dry-run / full-run orchestration with live row-count updates
///   - User preferences (theme, zoom, MRU list) via `PrefsService`
///   - Schema docs cache from `bxp-fmt --docs`
///
/// Streaming invariant: NEVER call `notifyListeners()` per trace line — use
/// `_traceLinesCounter` and `_fileGen` ValueNotifiers to update live counters
/// without triggering the full PlutoGrid rebuild chain on every event.
class TraceStore extends ChangeNotifier {
  // Set in dispose(); guards every async-tail notifyListeners against
  // setState-after-dispose when the store outlives a fast tear-down
  // (e.g. provider replaced under the running app, or hot-restart in
  // dev tree).
  bool _disposed = false;

  // Config
  String configPath = '';
  String templateId = '';

  // Active theme preset identifier. Do not import bxp_theme.dart here —
  // the enum lives under ui/theme/ and loading it in store would create a
  // UI → store → UI import cycle. We store the preset name as a string and
  // let ui/theme/bxp_theme.dart resolve it.
  String _themePresetName = 'slate';
  String get themePresetName => _themePresetName;

  // Active sans/prose typography scheme. The app ships a single
  // bundled font (Roboto) so the getter is a constant; the indirection
  // is preserved so call sites stay shape `store.textScheme.fontFamily`
  // and a future second scheme can be added back without rewrites.
  BxpTextScheme get textScheme => kBxpTextRoboto;

  // Ctrl+/Ctrl-/Ctrl+wheel UI zoom factor. Stored INTERNALLY as an
  // integer percent (60, 80, 100, 125, …) and persisted under
  // `bxp-gui.zoom` as the same integer. Repeated `+/- 10` bumps stay
  // exact — `0.8 - 0.1 - 0.1` in IEEE 754 produces 0.6000000000000001
  // because 0.1 isn't binary-exact, while `80 - 10 - 10` is just 60.
  // The legacy double prefs (≤ v0.2) are auto-migrated on first
  // read by [_init].
  //
  // The stored value is the user's INTENT at the canonical 100 % DPR
  // baseline; the runtime divides by `MediaQuery.devicePixelRatio`
  // before applying `Transform.scale` (see ZoomContainer in main.dart).
  // That way `100` reads the same physical size on Linux 100 % DPI,
  // Windows 125 % DPI, and macOS Retina — Flutter's native respect
  // for OS scaling is undone by the DPR division so the layout looks
  // identical regardless of platform. Ctrl+0 always resets to 100;
  // `defaultZoomForPlatform` therefore returns 1.0 (= 100 /100).
  static int defaultZoomPercentForPlatform() => 100;

  /// Convenience: legacy doubles still call sites use. The same value
  /// the internal int holds, divided by 100. Identity for callers that
  /// previously read [zoom] as a `double` (Transform.scale, autoclamp
  /// math, dialog labels).
  static double defaultZoomForPlatform() =>
      defaultZoomPercentForPlatform() / 100.0;

  int _zoomPercent = defaultZoomPercentForPlatform();
  int get zoomPercent => _zoomPercent;
  double get zoom => _zoomPercent / 100.0;


  // Runtime State
  RunStatus status = RunStatus.idle;
  RunMode runMode = RunMode.none;
  String? runError;
  // Internal buffer + cached materialisation. Avoids O(N²) `String +=`
  // on every stderr chunk. The cache is invalidated on append and
  // rebuilt lazily by the [stderrText] getter — UI reads are infrequent
  // (only on `notifyListeners`), so toString() runs at most a handful
  // of times per stream.
  StringBuffer _stderrBuffer = StringBuffer();
  String? _stderrCache;
  String get stderrText => _stderrCache ??= _stderrBuffer.toString();
  set stderrText(String v) {
    _stderrBuffer = StringBuffer(v);
    _stderrCache = v;
  }
  int rawLines = 0;
  // Live trace-line counter exposed as a ValueListenable so the StatusBar's
  // "trace lines" cell can rebuild at ~10 Hz during a stream WITHOUT
  // calling main `notifyListeners()` (which would also rebuild RowList /
  // FileList / OutputPanel and turn the dry-run into an O(N²) PlutoGrid
  // re-allocation storm). Mutation is internal-only.
  final ValueNotifier<int> _traceLinesCounter = ValueNotifier(0);
  ValueListenable<int> get traceLinesCounter => _traceLinesCounter;

  // Bumped on every `file_start` event so FileList can grow live during a
  // stream without main `notifyListeners()`. RowList does NOT listen to
  // this — once the first file's auto-select fires (single main notify on
  // first `file_end`), the grid renders once and stays put for the rest
  // of the run. Mutation is internal-only.
  final ValueNotifier<int> _fileGen = ValueNotifier(0);
  ValueListenable<int> get fileGen => _fileGen;

  /// Phase 5h: path of the most recently inserted config node, set by
  /// `insertConfigNode`. The matching tree row's editable cell consumes
  /// it on first build (post-frame `_enterEdit` + [clearPendingFocus]),
  /// so the user lands directly in edit mode after Confirm rather than
  /// having to click the new row.
  final ValueNotifier<List<String>?> _pendingFocusPath = ValueNotifier(null);
  ValueListenable<List<String>?> get pendingFocusPath => _pendingFocusPath;
  void clearPendingFocus() {
    _pendingFocusPath.value = null;
  }

  /// Path of the tree row whose Add-Child dialog should be opened next
  /// frame. Fired by the Ctrl+Shift+Insert shortcut so that the dialog
  /// pops over the focused row even though the shortcut handler lives in
  /// `main_view` (which can't `showDialog` the row's local widget tree
  /// without losing the parent JsonObject reference held by
  /// `_JsonNodeState`). The matching node consumes and clears it in the
  /// same way `_pendingFocusPath` works.
  final ValueNotifier<List<String>?> _pendingAddChildPath = ValueNotifier(null);
  ValueListenable<List<String>?> get pendingAddChildPath => _pendingAddChildPath;
  // Monotonic ticket so that exactly one listener consumes each request
  // even when multiple `_JsonNodeState` instances share a path (a property
  // row and its expanded container can both match). `requestAddChildAt`
  // bumps `_addChildTicket`; the first matching listener calls
  // `consumeAddChildTicket(ticket)` — returns true once, false thereafter
  // for the same ticket, so siblings short-circuit.
  int _addChildTicket = 0;
  int _addChildTicketConsumed = 0;
  int get addChildTicket => _addChildTicket;
  bool consumeAddChildTicket(int ticket) {
    if (ticket <= _addChildTicketConsumed) return false;
    _addChildTicketConsumed = ticket;
    return true;
  }
  void requestAddChildAt(List<String> path) {
    _addChildTicket++;
    _pendingAddChildPath.value = path;
  }
  void clearPendingAddChild() {
    _pendingAddChildPath.value = null;
  }
  // Exit code from the most recent dry-run / full-run, captured so the
  // status bar can show "done · exit N" with the right colour:
  //   0 → success (emerald), 2 → completed with warnings (amber),
  //   anything else → red. Mirrors bxp-ui's StatusBar logic.
  int? lastExitCode;
  
  /// Phase 5c-D: validation diagnostics keyed by encoded path
  /// (`segment\x00segment\x00…`). Populated by `loadConfig` and the
  /// pre-save validation in `saveConfig` from `bxp-fmt --config` output;
  /// consulted by `errorsAt` / `hasErrorIn` from the UI. Empty until
  /// the first validator response lands.
  Map<String, Map<String, String>> _validationErrors = const {};

  /// Phase A plumbing for the `bxp-fmt --config` deep-validation
  /// pass. `$warn_<N>` and `$info_<N>` siblings live in their own
  /// path-keyed maps so the tree renderer can route them to a different
  /// badge style and the save pre-flight (`_firstErrTraceIn`) stays
  /// strict on `.@"error"` severity only. Populated by phases B+ that
  /// add deep-validation emit sites — empty by design today.
  Map<String, Map<String, String>> _validationWarnings = const {};
  Map<String, Map<String, String>> _validationInfo = const {};

  /// Phase 3 — native Dart-side per-edit diagnostics, populated by
  /// `_revalidateDart()` from `_applyOpToAst`/undo/redo/resetDraft and
  /// after each `loadConfig`. Same path-keyed shape as the bxp-fmt
  /// buckets above; merged at query time in `errorsAt`/`warningsAt`/
  /// `infoAt`. Inner keys are `$dart_<N>` so collisions with bxp-fmt's
  /// `$err_<N>` are impossible.
  Map<String, Map<String, String>> _dartErrors = const {};
  Map<String, Map<String, String>> _dartWarnings = const {};
  Map<String, Map<String, String>> _dartInfo = const {};

  /// Default deadline (seconds) for bxp-fmt's FS validation pass on
  /// load / save. 2s is plenty on local disk (sub-millisecond per
  /// broker); the GUI degrades to 0 (skip) for the rest of the session
  /// if any call surfaces an `[fs.timeout]` warning — see
  /// [_fsCheckSlow] and [_activeFsCheckSeconds].
  static const int _kFsCheckSeconds = 2;

  /// Set true on the first `[fs.timeout]` warning observed in
  /// `_validationWarnings`. Adaptive degradation: subsequent
  /// loadConfig / saveConfig spawns drop the `--check-fs=N` flag so a
  /// pathological NFS/SMB mount only pays the deadline once per app
  /// session. Resets on app restart only — there's no UI toggle.
  bool _fsCheckSlow = false;
  bool get fsCheckSlow => _fsCheckSlow;

  int _activeFsCheckSeconds() => _fsCheckSlow ? 0 : _kFsCheckSeconds;

  /// Scan `_validationWarnings` for the `[fs.timeout]` prefix emitted
  /// by `bxp-core`'s `validateFilesystemWithTimeout`. Sets
  /// [_fsCheckSlow] on the first match. No-op once the flag is true.
  /// Caller must already have updated `_validationWarnings`.
  void _detectFsTimeout() {
    if (_fsCheckSlow) return;
    for (final entry in _validationWarnings.values) {
      for (final v in entry.values) {
        if (v.startsWith('[fs.timeout]')) {
          _fsCheckSlow = true;
          devTrace('config.fs_check_slow_detected');
          return;
        }
      }
    }
  }

  /// AST is the single source of truth for the loaded config. Every
  /// mutation applies through `op_to_ast.applyConfigOp`; saves dump
  /// directly via the AST patcher.
  JsonAstNode? _astRoot;

  /// Read-only view of the live AST for UI components.
  /// Components MUST NOT mutate the returned tree — edits go through
  /// TraceStore mutation methods so op_log + history stay coherent.
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

  /// Bumps every time `loadConfig` completes. ConfigView keys the json-tree
  /// subtree with this counter so each reload throws away per-row UI state
  /// (manual expand/collapse on `_JsonNode`s) — without it Flutter reuses
  /// State across loads and the tree visually inherits the previous shape
  /// even though the AST is fresh.
  int treeLoadGen = 0;

  // Data
  TraceModel? traceModel;
  
  // UI Selection State
  String? selectedFileId;
  String? selectedRowId;

  // Expression editor state
  List<String>? selectedExprPath;
  String selectedExprText = '';

  /// Path of the tree row that currently has "keyboard focus" — the target
  /// of structural shortcuts (Ctrl+Shift+↑/↓/Del/Insert). Set when the user
  /// taps any tree row; cleared when focus leaves the tree. Independent of
  /// [selectedExprPath]: the latter governs the right-rail ExprPanel and is
  /// only set when the tapped node is an expression leaf, whereas this
  /// field tracks ANY clickable tree row (object/array container, scalar,
  /// expression — all of them).
  List<String>? focusedNodePath;
  // The text the editor was opened with — i.e. the value committed in
  // configJson at the time of selection, plus whatever Apply has pushed
  // since. The Reset button restores the editor to this baseline; without
  // a separate field we can't tell the original text from the working
  // copy because every keystroke flows through `selectedExprText`.
  String selectedExprBaseline = '';
  String? exprValidationError;
  /// Phase G1: byte offset + length of the offending token in
  /// `selectedExprText`. Set by `_validateNow` from
  /// `bxp-fmt --expr` JSON's `off` / `len` fields. Both null when no
  /// validation issue (or when the parser couldn't pin a span — old
  /// errors, allocator failures, …). The ExprPanel renders these as
  /// a token-level red underline instead of underlining the whole cell.
  int? exprValidationOffset;
  int? exprValidationLength;
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
      devTrace('action.tab.set', {'index': index});
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
      if (_disposed) return;
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
  /// events) into the raw index in the AST's `JsonArray.elements` along
  /// [parentPath]. Comment peers (CommentLine) shift the raw position
  /// forward; trace events count only real entries, the UI / op_log /
  /// AST resolver all use raw positions.
  int? _realToRawListIndex(List<String> parentPath, int realIdx) {
    final root = _astRoot;
    if (root == null) return null;
    JsonAstNode cur = root;
    for (final seg in parentPath) {
      if (cur is JsonObject) {
        JsonAstNode? next;
        for (final p in cur.properties.whereType<JsonProperty>()) {
          if (p.key == seg) {
            next = p.value;
            break;
          }
        }
        if (next == null) return null;
        cur = next;
      } else if (cur is JsonArray) {
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= cur.elements.length) return null;
        cur = cur.elements[i];
      } else {
        return null;
      }
    }
    if (cur is! JsonArray) return null;
    int seen = 0;
    for (int i = 0; i < cur.elements.length; i++) {
      if (cur.elements[i] is CommentLine) continue;
      if (seen == realIdx) return i;
      seen++;
    }
    return null;
  }

  void jumpToConfigRule(int ruleIndex, String whenExpr) {
    devTrace('action.jumpTo.rule', {'ruleIndex': ruleIndex});
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
    devTrace('action.jumpTo.var', {'varName': varName});
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
    devTrace('action.jumpTo.ruleVar', {
      'ruleIndex': ruleIndex,
      'outputRowIndex': outputRowIndex,
      'varName': varName,
    });
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

  /// True while the in-panel autocomplete popup is visible. Validation
  /// is suspended in that window — the user is mid-completion, the
  /// expression is intentionally partial, and a `bxp-fmt --expr` spawn
  /// would just flicker an "INVALID" badge that flips back to "VALID"
  /// the moment they pick a function.
  bool _exprAutocompleteOpen = false;
  bool get isExprAutocompleteOpen => _exprAutocompleteOpen;

  /// Called by ExprEditor when its autocomplete popup opens or closes.
  /// Open → cancel pending validation; closed → re-run validation on
  /// the current text so the badge catches up to the final input.
  void setExprAutocompleteOpen(bool open) {
    if (_exprAutocompleteOpen == open) return;
    _exprAutocompleteOpen = open;
    if (open) {
      _validationDebounce?.cancel();
      // Notify so the editor's badge / red border can mute themselves —
      // a stale "INVALID" from the previous keystroke would otherwise
      // shout at the user while they're choosing from the popup.
      notifyListeners();
    } else if (selectedExprText.trim().isNotEmpty) {
      exprValidationState = ExprValidationState.pending;
      notifyListeners();
      _validateNow(selectedExprText);
    } else {
      notifyListeners();
    }
  }

  // Selecting another leaf overwrites `selectedExprText` with the new leaf's
  // content — by design. The expression panel commits typed changes to the
  // tree as the user types (debounced), so anything not yet committed is
  // intentional in-flight churn that belongs on the previous leaf, not
  // ghost-pasted onto the new one. Adding a confirm dialog here would cost
  // more than it saves: typing into one leaf and clicking another is a
  // common navigation pattern (compare, reference) that should not prompt.
  /// Set the tree node currently receiving keyboard focus for structural
  /// shortcuts. Called by every tappable tree row (json_tree's
  /// `_buildExpandableRow`, scalar leaves, expression leaves).
  /// A null path clears focus (e.g. when the user clicks outside the tree).
  void setFocusedNode(List<String>? path) {
    if (focusedNodePath == null && path == null) return;
    if (focusedNodePath != null &&
        path != null &&
        focusedNodePath!.length == path.length) {
      var same = true;
      for (var i = 0; i < path.length; i++) {
        if (focusedNodePath![i] != path[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    focusedNodePath = path;
    notifyListeners();
  }

  void setSelectedExpr(List<String> path, String text) {
    devTrace('action.expr.select', {'path': path});
    selectedExprPath = path;
    selectedExprText = text;
    selectedExprBaseline = text;
    focusedNodePath = path;
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
    // Newlines are a UI typing aid only — the editor lets the user split
    // long expressions visually. bxp-fmt's expr parser would reject a
    // literal newline mid-token, so strip them defensively here so any
    // caller (including legacy paths) feeds a clean validator input.
    text = text.replaceAll(RegExp(r'[\r\n]+'), ' ');
    selectedExprText = text;
    if (_exprAutocompleteOpen) {
      // While the popup is up, leave the badge state as-is and don't
      // schedule a spawn; the user is selecting from the list, not
      // committing to typed text. `setExprAutocompleteOpen(false)` will
      // re-validate when the popup closes.
      notifyListeners();
      return;
    }
    // Flip to pending immediately so the user sees "checking…" the
    // moment they start typing — not after the 500ms debounce + spawn.
    exprValidationState = text.trim().isEmpty
        ? ExprValidationState.idle
        : ExprValidationState.pending;
    notifyListeners();
    // Typing: debounce the spawn so rapid keystrokes don't queue runs.
    _validationDebounce?.cancel();
    _validationDebounce = Timer(const Duration(milliseconds: 500), () {
      if (selectedExprText == text && !_exprAutocompleteOpen) {
        _validateNow(text);
      }
    });
  }

  // Monotonic counter for in-flight expression validations. The string
  // equality guard below catches the common A→B race, but breaks on
  // A→B→A: a slow validateExpr(A) returning *after* a faster validateExpr(A)
  // would still see selectedExprText == A and clobber the fresher result.
  // The generation counter closes that gap atomically — only the most
  // recently spawned call is allowed to write the result.
  int _exprValidateGen = 0;

  void _validateNow(String text) async {
    // Belt-and-suspenders: strip newlines on the validator boundary too,
    // matching `updateSelectedExprText`. Anything getting here from
    // `setSelectedExpr` (file load) is already newline-free, but a stray
    // direct caller can't accidentally feed a multi-line string.
    text = text.replaceAll(RegExp(r'[\r\n]+'), ' ');
    final gen = ++_exprValidateGen;
    if (text.trim().isEmpty) {
      exprValidationError = null;
      exprValidationOffset = null;
      exprValidationLength = null;
      exprValidationState = ExprValidationState.idle;
      notifyListeners();
      return;
    }

    // Phase 4 — Dart-side first pass. Catches UnknownFunction,
    // WrongArgCount, FnArgDoc statics (literal_int_positive,
    // sunrise_format), and LOOKUP unknown pre_pass instantly without
    // spawning a subprocess. Subprocess still runs afterward as the
    // oracle for syntax/precedence errors that the Dart walker
    // doesn't cover.
    final root = _astRoot;
    final d = docs;
    // Prefer the template id encoded in the selected expression's path
    // (path[1] when path[0] == 'conversion_templates'); fall back to
    // _activeTemplateId() when a non-template leaf is being validated
    // through Playground or similar standalone paths.
    String? activeTid;
    final sel = selectedExprPath;
    if (sel != null && sel.length >= 2 && sel[0] == 'conversion_templates') {
      activeTid = sel[1];
    } else {
      activeTid = _activeTemplateId();
    }
    if (root != null && d != null) {
      final v = DartValidator(d);
      final ed = v.validateExpr(text, root: root, activeTemplateId: activeTid);
      if (ed != null) {
        if (selectedExprText != text) return;
        exprValidationError = ed.suggest == null
            ? ed.message
            : '${ed.message} — ${ed.suggest}';
        exprValidationOffset = ed.offset;
        exprValidationLength = ed.length;
        exprValidationState = ExprValidationState.error;
        notifyListeners();
        return;
      }
    }

    final res = await BxpProcessClient.validateExpr(text);
    if (_disposed) return;
    // A newer validation has been spawned while we were awaiting — drop
    // this result so it can't overwrite the fresher one.
    if (gen != _exprValidateGen) return;
    // Selected expression changed under us (e.g. user clicked a different
    // leaf) — same drop rule.
    if (selectedExprText != text) return;
    final err = res.error;
    exprValidationError = err;
    exprValidationOffset = err == null ? null : res.offset;
    exprValidationLength = err == null ? null : res.length;
    exprValidationState = err == null
        ? ExprValidationState.ok
        : ExprValidationState.error;
    notifyListeners();
  }

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

  /// Phase 5c-D: encode a path for `_validationErrors` lookup. NUL is
  /// safe — JSON5 keys can't contain it, array indices are decimal ints.
  static String _encodePath(List<String> path) => path.join('\x00');

  /// Merge two path-keyed diagnostic maps for the same path. Returns
  /// the combined inner map without mutating either input. Used by
  /// `errorsAt`/`warningsAt`/`infoAt` to overlay Phase-3 Dart-side
  /// diagnostics on top of bxp-fmt entries at query time.
  ///
  /// Polish 1 — dedupe by VALUE: when both maps carry the same
  /// message text (e.g. bxp-fmt's `$err_1` and Dart's `$dart_1` both
  /// say `unknown config key 'data_dir2' — did you mean 'data_dir'?`
  /// because the wording is intentionally aligned), drop the
  /// duplicate from the second map. Bxp-fmt's keys come first since
  /// they reflect the saved file's authoritative state.
  static Map<String, String> _mergeMaps(
      Map<String, String>? a, Map<String, String>? b) {
    if (a == null || a.isEmpty) return b ?? const {};
    if (b == null || b.isEmpty) return a;
    final seen = <String>{...a.values};
    final out = <String, String>{...a};
    for (final e in b.entries) {
      if (seen.add(e.value)) out[e.key] = e.value;
    }
    return out;
  }

  /// Diagnostics on the node at [path]. Returns the `$err_<name>` →
  /// message map captured by the most recent `bxp-fmt --config` run,
  /// merged with `$dart_<N>` entries from the live Dart-side validator
  /// (`_revalidateDart`). Empty map when the node has no errors.
  Map<String, String> errorsAt(List<String> path) {
    final key = _encodePath(path);
    return _mergeMaps(_validationErrors[key], _dartErrors[key]);
  }

  /// Phase A plumbing: same path-keyed lookup as `errorsAt` but for
  /// `$warn_*` / `$info_*` siblings emitted by `bxp-fmt`'s deep
  /// validation pass + Phase-3 Dart-side warnings/info.
  Map<String, String> warningsAt(List<String> path) {
    final key = _encodePath(path);
    return _mergeMaps(_validationWarnings[key], _dartWarnings[key]);
  }

  Map<String, String> infoAt(List<String> path) {
    final key = _encodePath(path);
    return _mergeMaps(_validationInfo[key], _dartInfo[key]);
  }

  /// Reset all six severity buckets (3 bxp-fmt + 3 Dart) in one call.
  /// Used by loadConfig's reset paths so stale entries don't leak
  /// across loads.
  void _clearValidationDiagnostics() {
    _validationErrors = const {};
    _validationWarnings = const {};
    _validationInfo = const {};
    _dartErrors = const {};
    _dartWarnings = const {};
    _dartInfo = const {};
  }

  /// Polish 1 — dedup parent banner: returns true when [message]
  /// appears at any STRICT descendant of [path] in the bucket
  /// matching [severity]. Used by json_tree's banner renderer to
  /// suppress a parent-level banner whose text is already shown
  /// under a descendant leaf (the typical pattern when bxp-fmt
  /// emits `$err_*` at the parent object level while the Dart-side
  /// validator places the same diagnostic at the offending leaf).
  ///
  /// Strict descendant: a key that startsWith `<path>\x00` (so the
  /// banner's own path doesn't dedup itself away).
  bool _isDuplicatedAtDescendant(
      List<String> path, DartSeverity severity, String message) {
    final prefix = '${_encodePath(path)}\x00';
    Map<String, Map<String, String>> bucket;
    Map<String, Map<String, String>> dartBucket;
    switch (severity) {
      case DartSeverity.error:
        bucket = _validationErrors;
        dartBucket = _dartErrors;
        break;
      case DartSeverity.warning:
        bucket = _validationWarnings;
        dartBucket = _dartWarnings;
        break;
      case DartSeverity.info:
        bucket = _validationInfo;
        dartBucket = _dartInfo;
        break;
    }
    bool any(Map<String, Map<String, String>> m) {
      for (final e in m.entries) {
        if (!e.key.startsWith(prefix)) continue;
        if (e.value.values.contains(message)) return true;
      }
      return false;
    }
    return any(bucket) || any(dartBucket);
  }

  /// Filter [messages] to those NOT duplicated at a strict descendant
  /// of [path] in the [severity] bucket. Returns the inputs verbatim
  /// when no dedup is needed (typical case).
  Iterable<String> dedupBannerMessages(
      List<String> path, DartSeverity severity, Iterable<String> messages) {
    return messages
        .where((m) => !_isDuplicatedAtDescendant(path, severity, m));
  }

  /// True if any descendant of the node at [path] (inclusive) carries a
  /// `$err_*` marker — either bxp-fmt's or a Dart-side `$dart_<N>` from
  /// `_revalidateDart`. Used by composite-row renderers to surface a
  /// small red dot when a collapsed subtree contains diagnostics.
  /// O(errors) per bucket.
  bool hasErrorIn(List<String> path) {
    if (_validationErrors.isEmpty && _dartErrors.isEmpty) return false;
    if (path.isEmpty) return true;
    final key = _encodePath(path);
    final prefix = '$key\x00';
    bool any(Map<String, Map<String, String>> m) {
      for (final k in m.keys) {
        if (k == key || k.startsWith(prefix)) return true;
      }
      return false;
    }
    return any(_validationErrors) || any(_dartErrors);
  }

  /// Quick predicate: any `$err_*` anywhere in [src]? Used by the save
  /// pre-flight validator (which would otherwise pass through "annotated
  /// JSON with errors" silently because bxp-fmt exits with stdout even
  /// then). Mirrors the old `_findFirstErrTrace` behaviour without
  /// rebuilding the full path map.
  static String? _firstErrTraceIn(dynamic src) {
    if (src is Map) {
      for (final e in src.entries) {
        final k = e.key.toString();
        if (k.startsWith(r'$err_') && e.value is String) {
          return e.value as String;
        }
      }
      for (final e in src.entries) {
        final k = e.key.toString();
        if (k.startsWith(r'$')) continue;
        final found = _firstErrTraceIn(e.value);
        if (found != null) return found;
      }
    } else if (src is List) {
      for (final v in src) {
        final found = _firstErrTraceIn(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Walk a parsed `bxp-fmt --config` tree, collecting `$err_*`,
  /// `$warn_*`, and `$info_*` markers into per-severity path-keyed maps.
  /// Returns three buckets that share the same outer-key shape (encoded
  /// parent path) so the renderer can route by severity.
  ///
  /// Phase A note: today bxp-fmt only emits `$err_*` (the existing
  /// validateCollect path). Warning / info maps are empty until phases
  /// B+ wire deep-validation emit sites in core. Walking still skips
  /// the `$warn_*` / `$info_*` prefixes so future emissions are
  /// captured directly without recursing into them as if they were
  /// data nodes.
  /// Phase G1: $err_/$warn_/$info_ values are objects
  /// `{message, off?, len?, suggest?}` — extract the displayable message.
  /// Falls back to the legacy plain-string shape for forward-compat with
  /// any consumer still emitting bare strings.
  static String _diagMessage(dynamic v) {
    if (v is Map) {
      final m = v['message'];
      if (m is String) return m;
      return '';
    }
    if (v is String) return v;
    return v?.toString() ?? '';
  }

  static _DiagnosticBuckets _extractDiagnostics(dynamic src) {
    final errors = <String, Map<String, String>>{};
    final warnings = <String, Map<String, String>>{};
    final info = <String, Map<String, String>>{};
    void walk(dynamic node, List<String> path) {
      if (node is Map) {
        // bxp-fmt's contract (see bxp-fmt/CLAUDE.md): each `$err_<N>` /
        // `$warn_<N>` / `$info_<N>` is inserted "as a sibling immediately
        // before the offending key in its parent object"; when the
        // offending field is absent, the marker is appended at the end.
        // Translate that placement back into a leaf path so banners render
        // adjacent to the offending property row instead of after the
        // whole parent subtree.
        final entries = node.entries.toList();
        String? targetAt(int i) {
          for (var j = i + 1; j < entries.length; j++) {
            final nk = entries[j].key.toString();
            if (!nk.startsWith(r'$')) return nk;
          }
          return null;
        }
        for (var i = 0; i < entries.length; i++) {
          final k = entries[i].key.toString();
          Map<String, Map<String, String>>? bucket;
          if (k.startsWith(r'$err_')) {
            bucket = errors;
          } else if (k.startsWith(r'$warn_')) {
            bucket = warnings;
          } else if (k.startsWith(r'$info_')) {
            bucket = info;
          } else {
            continue;
          }
          final target = targetAt(i);
          final attachPath = target != null ? [...path, target] : path;
          final encoded = _encodePath(attachPath);
          (bucket.putIfAbsent(encoded, () => {}))[k] =
              _diagMessage(entries[i].value);
        }
        for (final e in entries) {
          final k = e.key.toString();
          // Skip only the annotation prefixes bxp-fmt actually emits
          // (`$err_*`, `$warn_*`, `$info_*`, `$comm_*`). Walking into
          // any future `$`-keys (e.g. user `$variable` names that
          // surface in input_schema) keeps them visible to consumers
          // higher up the stack instead of silently dropped here.
          if (!k.startsWith(r'$err_') &&
              !k.startsWith(r'$warn_') &&
              !k.startsWith(r'$info_') &&
              !k.startsWith(r'$comm_')) {
            walk(e.value, [...path, k]);
          }
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], [...path, i.toString()]);
        }
      }
    }
    walk(src, const []);
    return (errors: errors, warnings: warnings, info: info);
  }


  // Full reset of the expression-editor state. Called when no leaf is
  // selected (e.g. on file load with `preserveTreeState: false`). Mirrors
  // `setSelectedExpr` in always nuking `selectedExprText` — the panel
  // shows the most recently selected leaf's text, never lingering input.
  void clearSelectedExpr() {
    selectedExprPath = null;
    selectedExprText = '';
    selectedExprBaseline = '';
    exprValidationError = null;
    exprValidationOffset = null;
    exprValidationLength = null;
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

  final PrefsService _prefs = PrefsService();

  /// Read-only access to the prefs service. Used by the AppImage
  /// first-run integration flow to probe `prefsFileExists()` and call
  /// `ensureExists()` from outside the store.
  PrefsService get prefs => _prefs;

  Future<void> _init() async {
    await _prefs.load();
    // Defensive reads — a corrupt/older prefs store should never crash
    // the app or leave it in a half-loaded state. On any single read
    // failure we silently keep the field's default value.
    try {
      final stored = _prefs.getString('bxp-ui.theme');
      if (stored != null && stored.isNotEmpty) _themePresetName = stored;
    } catch (_) {}
    try {
      // Read as double for legacy compatibility. Pre-v0.3 prefs stored
      // the zoom as a fractional double (`0.8`, `0.6000000000000001`);
      // we promote to integer percent on read, and `_persistZoom()`
      // writes back as int next time we save. `getDouble` accepts both
      // ints and doubles in the JSON, so this also works for already-
      // migrated values.
      final z = _prefs.getDouble('bxp-gui.zoom');
      if (z != null && z.isFinite) {
        // Legacy values < 5 are fractional (e.g. 0.8); ≥ 5 are int
        // percent (e.g. 80). The cutoff sits well outside both ranges
        // (legacy max 3.0, new min 50) so misclassification is
        // impossible.
        final pct = z < 5 ? (z * 100).round() : z.round();
        if (pct >= 50 && pct <= 300) _zoomPercent = pct;
      }
    } catch (_) {}
    try {
      _recentFiles = _prefs.getStringList('bxp-ui.recent') ?? [];
    } catch (_) {}
    try {
      _customPlaces = _prefs.getStringList('bxp-gui.customPlaces') ?? [];
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
          '  • bxp-fmt in the same directory as bxp_gui = '
          '${p.join(exeDir, BxpProcessClient.binaryFileName('bxp-fmt'))}\n\n'
          'Diagnostics:\n'
          '  • Platform.resolvedExecutable = $exe\n'
          '  • Directory.current (PWD) = $cwd';
    } else {
      final d = await BxpProcessClient.getDocs();
      if (d == null) {
        final detail = BxpProcessClient.lastDocsError ?? '(no detail captured)';
        final subprocDiag =
            BxpProcessClient.lastSubprocessDiag ?? '(no subprocess diag)';
        _fatalStartupError =
            'bxp-fmt --docs failed.\n\n'
            'Found bxp-fmt at: $fmtBin\n\n'
            'Failure detail: $detail\n\n'
            'Subprocess fallback chain:\n  $subprocDiag\n\n'
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
  Map<String, dynamic>? findSchemaDoc(List<String> path) =>
      findSchemaDocIn(docConfigSchema, path);

  Future<void> _addRecentFile(String path) async {
    if (path.isEmpty) return;
    _recentFiles.remove(path);
    _recentFiles.insert(0, path);
    if (_recentFiles.length > _recentMax) {
      _recentFiles = _recentFiles.sublist(0, _recentMax);
    }
    if (_disposed) return;
    await _prefs.setStringList('bxp-ui.recent', _recentFiles);
    if (_disposed) return;
    notifyListeners();
  }

  // User-pinned directory paths shown in the OpenDialog sidebar under
  // PLACES, alongside the built-in Home/Documents shortcuts. Persisted.
  List<String> _customPlaces = [];
  List<String> get customPlaces => List.unmodifiable(_customPlaces);

  Future<void> addCustomPlace(String path) async {
    if (path.isEmpty || _customPlaces.contains(path)) return;
    _customPlaces.add(path);
    await _prefs.setStringList('bxp-gui.customPlaces', _customPlaces);
    notifyListeners();
  }

  Future<void> removeCustomPlace(String path) async {
    if (!_customPlaces.remove(path)) return;
    await _prefs.setStringList('bxp-gui.customPlaces', _customPlaces);
    notifyListeners();
  }

  /// Toggle between slate and zinc (kept for backwards-compat). Prefer
  /// [cycleTheme] for the 5-preset rotation used by the new TopBar.
  void toggleTheme() async {
    _themePresetName = _themePresetName == 'slate' ? 'zinc' : 'slate';
    await _prefs.setString('bxp-ui.theme', _themePresetName);
    notifyListeners();
  }

  /// Advances [themePresetName] through a caller-provided rotation list.
  /// We pass the order from the UI to avoid importing the theme module
  /// into the store.
  void setThemePreset(String name) async {
    if (_themePresetName == name) return;
    devTrace('action.theme.set', {'name': name});
    _themePresetName = name;
    await _prefs.setString('bxp-ui.theme', _themePresetName);
    notifyListeners();
  }

/// Set the UI zoom factor and persist under `bxp-gui.zoom`. Accepts
  /// the historical fractional API (1.0 = 100 %, 0.8 = 80 %, …) and
  /// internally stores the integer percent — see [_zoomPercent] for
  /// why. Clamped to [50 %, 300 %].
  void setZoom(double v) async {
    if (!v.isFinite) return;
    final pct = (v.clamp(0.5, 3.0) * 100).round();
    if (pct == _zoomPercent) return;
    _zoomPercent = pct;
    notifyListeners();
    try {
      // Write as int so the file contains a clean "80", not "80.0".
      // The reader in `_init` accepts both shapes (legacy `0.8` double
      // and modern `80` int) and migrates on read.
      await _prefs.setInt('bxp-gui.zoom', _zoomPercent);
    } catch (_) {
      // Persistence is best-effort. The user has already seen the zoom
      // change; failing the write would only silently corrupt their next
      // session, so we just swallow.
    }
  }

  /// Update [configPath] and notify listeners. Triggers no I/O on its own;
  /// callers follow up with [loadConfig] once the path is ready.
  void setConfigPath(String path) {
    devTrace('action.config.setPath', {'path': path});
    configPath = path;
    notifyListeners();
  }

  /// Set the active template filter. An empty string means "all templates"
  /// — bxp-cli will process every template declared in the config when
  /// `--template` is omitted.
  void setTemplateId(String id) {
    devTrace('action.template.set', {'id': id});
    templateId = id;
    notifyListeners();
  }

  /// Reload the active config from disk.
  ///
  /// [preserveTreeState] suppresses the `treeLoadGen` bump so the
  /// json-tree's per-row expansion state survives the reload. Used by
  /// `saveConfig` whose post-write reload is internal bookkeeping
  /// (refresh raw bytes, validator markers, op-log baseline) — not a
  /// user-visible "fresh file" event. Manual Reload (Ctrl+R / toolbar)
  /// leaves the default `false` so the tree resets to defaults as
  /// before.
  Future<void> loadConfig({bool preserveTreeState = false}) async {
    devTrace('loadConfig.start', {'path': configPath});
    isLoadingConfig = true;
    // Reset transient state from any previous load so errors don't stick:
    // a fresh load starts assumed-clean and the parse / validator paths
    // below set these back to error states only as needed.
    configError = null;
    _loadedWithErrors = false;
    _clearValidationDiagnostics();
    // Run-state from a prior dry-run / full-run is also stale once the
    // config is reloaded — the stderr badge, lastExitCode and runError
    // describe a pipeline that no longer corresponds to the current
    // file. Clear them too so a successful reload presents a clean
    // slate. (Trace model is left in place; the user may still want to
    // inspect rows from the previous run side-by-side with the freshly
    // loaded config until they trigger another run.)
    stderrText = '';
    runError = null;
    lastExitCode = null;
    if (status != RunStatus.running) {
      status = RunStatus.idle;
      runMode = RunMode.none;
    }
    // Per-(row, expr) trace cache is invalidated by reload: expressions
    // may have moved or changed text in the new file, and the cache key
    // includes the expression body — old entries can't be reused.
    _exprCallCache.clear();
    _exprCallInFlight.clear();
    // Drop the active expr selection — pointing at a stale path from the
    // previous file would leave the editor populated with the old text.
    // Skipped on save-driven reloads: the user's selection is still
    // valid (we just wrote the file we're re-reading) and clearing it
    // would jarringly close the editor mid-session.
    if (!preserveTreeState) clearSelectedExpr();
    notifyListeners();
    try {
      if (configPath.isEmpty) {
        _astRoot = null;
        _clearValidationDiagnostics();
        configError = null;
        _rawConfigInput = null;
        _templateInfos = const [];
        devTrace('loadConfig.skip', {'reason': 'empty path'});
        return;
      }

      // AST is the primary loader. Parse the file via the Dart JSON5 AST
      // library; bxp-fmt runs alongside as a background validator that
      // contributes only `$err_*` diagnostics (mapped into the path-keyed
      // `_validationErrors` table).
      final astResult = await AstLoader.loadFromFile(configPath);
      _rawConfigInput = utf8.encode(astResult.rawText);

      if (astResult.root == null) {
        final firstErr = astResult.diagnostics.isNotEmpty
            ? astResult.diagnostics.first
            : null;
        configError = firstErr != null
            ? 'JSON5 parse error at ${firstErr.span.startLine}:${firstErr.span.startCol}: ${firstErr.message}'
            : 'JSON5 parse error';
        _astRoot = null;
        _clearValidationDiagnostics();
        _loadedWithErrors = true;
        _templateInfos = const [];
        devTrace('loadConfig.astParseFail',
            {'diagnostics': astResult.diagnostics.length, 'first': configError});
        return;
      }

      _astRoot = astResult.root;

      // Background validator: bxp-fmt --config gives us schema / expr /
      // pre_pass diagnostics that the AST parser (pure JSON5) doesn't
      // know about. Parse its output, build the path-keyed error map.
      try {
        final jsonOutput = await BxpProcessClient.loadConfig(
          configPath,
          checkFsSeconds: _activeFsCheckSeconds(),
        );
        final bxpTree = jsonDecode(jsonOutput);
        if (bxpTree is Map<String, dynamic>) {
          final bxpFatal = bxpTree['error'] as String?;
          if (bxpFatal != null) {
            // bxp-fmt couldn't even parse — but AST did. Surface the
            // bxp-fmt error so the user knows about the deeper failure;
            // the editor stays openable since AST has a tree.
            configError = bxpFatal;
            _clearValidationDiagnostics();
          } else {
            final buckets = _extractDiagnostics(bxpTree);
            _validationErrors = buckets.errors;
            _validationWarnings = buckets.warnings;
            _validationInfo = buckets.info;
            _detectFsTimeout();
            // Phase 3 — populate Dart-side buckets immediately on load
            // so the very first frame of the editor shows native
            // diagnostics (FieldValidator, unknown-keys, unused-vars,
            // expression statics) without waiting for the first edit.
            _revalidateDart();
          }
        } else {
          // Unexpected top-level shape (List, scalar, null) — possible only
          // if bxp-fmt's contract changes. Clear any prior errors and log.
          devTrace('loadConfig.unexpectedShape',
              {'runtimeType': bxpTree.runtimeType.toString()});
          _clearValidationDiagnostics();
        }
      } catch (e) {
        // bxp-fmt invocation itself failed (binary missing, crash, etc.).
        // Don't block editing on validator failures.
        configError ??= 'bxp-fmt validator unavailable: $e';
        _clearValidationDiagnostics();
      }

      // Deliberately NOT flipping `_loadedWithErrors` on bxp-fmt errors:
      // the readonly toolbar gate exists to keep the user from editing a
      // file the AST parser couldn't understand at all. Schema / expression
      // errors that bxp-fmt finds are surfaced as `$err_*` markers and the
      // pre-save guard (`_firstErrTraceIn` in `saveConfig`) blocks bad
      // saves from landing on disk — so the user can keep editing toward
      // the fix without getting trapped. Re-flip only on AST parse fail
      // (set above when `astResult.root == null`).
      devTrace('loadConfig.ok', {
        'rawBytes': _rawConfigInput?.length ?? 0,
        'loadedWithErrors': _loadedWithErrors,
        'validationErrorPaths': _validationErrors.length,
        'configError': configError,
      });

      // Pull richer template metadata for the selector (separate subprocess
      // call into bxp-cli; not part of the AST loader path).
      _templateInfos = await BxpProcessClient.listTemplates(configPath);
    } catch (e, st) {
      configError = e.toString();
      _astRoot = null;
      _clearValidationDiagnostics();
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
    _astBaseline = _astRoot?.clone();
    _isDirty = false;
    _astHistory.clear();
    _historyIndex = 0;
    if (_astRoot != null) _astHistory.add(_astRoot!.clone());
    configSaveError = null;
    // Add to MRU when the AST parsed (even if bxp-fmt found errors —
    // user can still re-open later). Skip when the spawn itself crashed
    // so paths to nonexistent / unreadable files don't pollute the
    // quick-pick list. Fire-and-forget — persistence write is non-critical.
    if (configPath.isNotEmpty && _astRoot != null) {
      // ignore: discarded_futures
      _addRecentFile(configPath);
    }
    if (!preserveTreeState) treeLoadGen++;
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
    _opLog.truncate(_historyIndex);
    devTrace(traceEvent, traceData);
    _opLog.record(op);
    _invalidatePathKeyedState();
    return true;
  }

  void editConfigNode(List<String> path, dynamic newValue) {
    if (_astRoot == null) return;
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
  }

  bool _isDirty = false;
  bool get isDirty => _isDirty;

  // History for Undo/Redo. AST snapshots are the only state — every
  // mutation pushes a clone, undo/redo restores from the slot. Index 0
  // is always the last loaded/saved baseline; `_isDirty` derives from
  // `_historyIndex > 0` since (a) loadConfig and saveConfig both reset
  // the history to a single baseline entry and (b) every mutation
  // pushes, so the only way to be at index 0 is "exactly at baseline".
  final List<JsonAstNode> _astHistory = [];
  int _historyIndex = -1;
  JsonAstNode? _astBaseline;

  bool get canUndo => _historyIndex > 0;
  bool get canRedo => _historyIndex < _astHistory.length - 1;

  void _pushHistory() {
    if (_historyIndex < _astHistory.length - 1) {
      _astHistory.removeRange(_historyIndex + 1, _astHistory.length);
    }
    if (_astRoot != null) _astHistory.add(_astRoot!.clone());
    _historyIndex = _astHistory.length - 1;
    // Dirty derives from history index: reaching index 0 means we're
    // at the saved baseline. Mutation methods used to call
    // _recomputeDirty BEFORE _pushHistory; that left them stale on the
    // first edit (index hadn't bumped yet). Folding the recompute into
    // _pushHistory removes that ordering footgun for free.
    _recomputeDirty();
  }

  void _recomputeDirty() {
    _isDirty = _historyIndex > 0;
  }

  /// Discard all unsaved edits and snap the AST back to the last
  /// loaded/saved baseline. Cheaper than [loadConfig] because it
  /// doesn't re-spawn bxp-fmt — just clones `_astBaseline` and resets
  /// the undo history. Mirrors bxp-ui's `resetDraft` action; bound to
  /// Ctrl+T.
  void resetDraft() {
    if (_astBaseline == null) return;
    if (_loadedWithErrors) return; // edits are blocked anyway in this state
    devTrace('action.resetDraft');
    _astRoot = _astBaseline?.clone();
    _isDirty = false;
    _astHistory.clear();
    if (_astRoot != null) _astHistory.add(_astRoot!.clone());
    _historyIndex = 0;
    _invalidatePathKeyedState();
    if (selectedExprPath != null) {
      final val = _getAt(selectedExprPath!);
      selectedExprText = val is String ? val : '';
      exprGeneration++;
    }
    notifyListeners();
  }

  void undo() {
    if (canUndo) {
      devTrace('action.undo', {'historyIndex': _historyIndex - 1});
      _historyIndex--;
      _astRoot = _astHistory[_historyIndex].clone();
      _recomputeDirty();
      _invalidatePathKeyedState();
      if (selectedExprPath != null) {
        final val = _getAt(selectedExprPath!);
        selectedExprText = val is String ? val : '';
        exprGeneration++;
      }
      notifyListeners();
    }
  }

  void redo() {
    if (canRedo) {
      devTrace('action.redo', {'historyIndex': _historyIndex + 1});
      _historyIndex++;
      _astRoot = _astHistory[_historyIndex].clone();
      _recomputeDirty();
      _invalidatePathKeyedState();
      if (selectedExprPath != null) {
        final val = _getAt(selectedExprPath!);
        selectedExprText = val is String ? val : '';
        exprGeneration++;
      }
      notifyListeners();
    }
  }

  /// Walk the AST to the node at [path] and return it as a [JsonAstNode],
  /// or null when the path doesn't resolve. Used by mutation methods to
  /// branch on container shape (JsonObject vs JsonArray).
  JsonAstNode? _astAt(List<String> path) {
    final root = _astRoot;
    if (root == null) return null;
    JsonAstNode cur = root;
    for (final seg in path) {
      if (cur is JsonObject) {
        JsonAstNode? next;
        for (final p in cur.properties.whereType<JsonProperty>()) {
          if (p.key == seg) {
            next = p.value;
            break;
          }
        }
        if (next == null) return null;
        cur = next;
      } else if (cur is JsonArray) {
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= cur.elements.length) return null;
        cur = cur.elements[i];
      } else {
        return null;
      }
    }
    return cur;
  }

  /// Walk the AST to the value at [path] and convert it to its plain-Dart
  /// shape (String / num / bool / null) for callers that only need the
  /// scalar. Returns null for missing paths and for container nodes.
  dynamic _getAt(List<String> path) {
    final root = _astRoot;
    if (root == null) return null;
    JsonAstNode cur = root;
    for (final seg in path) {
      if (cur is JsonObject) {
        JsonAstNode? next;
        for (final p in cur.properties.whereType<JsonProperty>()) {
          if (p.key == seg) {
            next = p.value;
            break;
          }
        }
        if (next == null) return null;
        cur = next;
      } else if (cur is JsonArray) {
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= cur.elements.length) return null;
        cur = cur.elements[i];
      } else {
        return null;
      }
    }
    if (cur is JsonString) return cur.value;
    if (cur is JsonNumber) return num.tryParse(cur.rawText);
    if (cur is JsonBool) return cur.value;
    if (cur is JsonNull) return null;
    return null;
  }

  /// Drop any path-keyed UI state whose AST node no longer resolves.
  /// Generalises the original [_shiftSelectionOnArrayEdit] invalidator:
  /// every AST mutation can orphan `selectedExprPath` (the user undoing
  /// a fresh insert is the textbook case from Backlog 3) or
  /// `_pendingFocusPath` (insert into a collapsed parent → target widget
  /// never mounts to consume it). One walk per piece of state, only
  /// when set, so this is cheap to call from every mutation site.
  void _invalidatePathKeyedState() {
    if (selectedExprPath != null && _astAt(selectedExprPath!) == null) {
      clearSelectedExpr();
    }
    final pending = _pendingFocusPath.value;
    if (pending != null && _astAt(pending) == null) {
      _pendingFocusPath.value = null;
    }
    _revalidateDart();
  }

  /// CSV headers cached from the most recent dry-run, indexed by
  /// template id. Reads `traceModel.files` and unions every file
  /// belonging to the template. Empty set when no dry-run has run yet
  /// for the template (or `traceModel` is null mid-load).
  Set<String> cachedHeadersForTemplate(String templateId) {
    final m = traceModel;
    if (m == null) return const {};
    final out = <String>{};
    for (final f in m.files.values) {
      if (f.template == templateId) out.addAll(f.headers);
    }
    return out;
  }

  /// Phase 3 — rerun the native Dart validator over the live AST and
  /// write its diagnostics into the `_dart*` buckets. No-op when docs
  /// haven't loaded (startup gate would have refused MainView anyway)
  /// or there's no AST. Always overwrites the previous Dart buckets so
  /// stale diagnostics don't accumulate.
  ///
  /// Cheap to call from every edit hook: validator construction is O(1)
  /// once docs are loaded, the walk is O(AST nodes) per pass. The
  /// walker emits `dart.*`-prefixed codes so consumers can route by
  /// source if needed.
  void _revalidateDart() {
    final root = _astRoot;
    final d = docs;
    if (root == null || d == null) {
      _dartErrors = const {};
      _dartWarnings = const {};
      _dartInfo = const {};
      return;
    }
    // Build a per-template CSV header map for the cluster check. Cheap
    // — typical M < 10 templates × < 50 headers each.
    final headersByTemplate = <String, Set<String>>{};
    final m = traceModel;
    if (m != null) {
      for (final f in m.files.values) {
        (headersByTemplate[f.template] ??= <String>{}).addAll(f.headers);
      }
    }

    final validator = DartValidator(d, csvHeadersByTemplate: headersByTemplate);
    final diags = validator.validate(root);

    // Suppress diagnostics that target the actively-edited expression
    // while the autocomplete popup is open. Reason: the user mid-types
    // intermediate states like `LOOKUP('_default', ` that intentionally
    // fail WrongArgCount / UnknownFunction until they finish typing.
    // Firing the error during typing closes / hides the autocomplete
    // and feels noisy. Other paths still validate normally — only the
    // leaf at `selectedExprPath` is suppressed.
    final suppressPath = (_exprAutocompleteOpen && selectedExprPath != null)
        ? _encodePath(selectedExprPath!)
        : null;

    final errors = <String, Map<String, String>>{};
    final warnings = <String, Map<String, String>>{};
    final infos = <String, Map<String, String>>{};
    final counters = <String, int>{};
    for (final dg in diags) {
      final key = _encodePath(dg.path);
      if (suppressPath != null && key == suppressPath) continue;
      final innerKey = '\$dart_${(counters[key] = (counters[key] ?? 0) + 1)}';
      // The displayable string includes suggest text when present so
      // existing consumers (StatusBar, TooltipKey) need no special
      // routing — same shape as bxp-fmt $err_<N> messages.
      final msg = dg.suggest == null ? dg.message : '${dg.message} — ${dg.suggest}';
      switch (dg.severity) {
        case DartSeverity.error:
          (errors[key] ??= <String, String>{})[innerKey] = msg;
          break;
        case DartSeverity.warning:
          (warnings[key] ??= <String, String>{})[innerKey] = msg;
          break;
        case DartSeverity.info:
          (infos[key] ??= <String, String>{})[innerKey] = msg;
          break;
      }
    }
    _dartErrors = errors;
    _dartWarnings = warnings;
    _dartInfo = infos;
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
    if (!_pathStartsWith(selectedExprPath!, parentPath)) return;
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
    if (_astRoot == null || path.isEmpty || _loadedWithErrors) return;
    // Schema-driven guard: required keys cannot be deleted from their parent
    // map. Array entries (parent is List) are always deletable — the array
    // itself may be required, but individual elements aren't.
    final parentPath = path.sublist(0, path.length - 1);
    final lastKey = path.last;
    final parent = _astAt(parentPath);
    if (parent is JsonObject) {
      // `required: true` on a wildcard-slot schema entry refers to the
      // VALUE (must be non-empty), not the entry's presence in the
      // parent. User-named children of wildcards are always deletable.
      final match = findSchemaDocMatchIn(docConfigSchema, path);
      if (match.doc != null &&
          !match.wildcardLast &&
          match.doc!['required'] == true) {
        return;
      }
    }

    // Selection invalidation BEFORE the mutation so we can still inspect
    // the current path. Two cases that both clear the selection:
    //   - the deleted node IS the selected leaf
    //   - the deleted node is an ancestor of the selected leaf
    if (selectedExprPath != null &&
        _pathStartsWith(selectedExprPath!, path)) {
      clearSelectedExpr();
    }

    final removedIdx = parent is JsonArray ? int.tryParse(lastKey) : null;
    if (parent is JsonArray && removedIdx == null) return;

    if (!_applyOpToAst(DeleteOp(path), 'op.delete', {'path': path})) {
      return;
    }
    if (parent is JsonArray) {
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
  }

  /// Public AST navigator. Returns the node at [path], or null when the
  /// AST is unloaded or the path doesn't resolve. Mirrors the internal
  /// `_astAt` helper without exposing it directly — kept on the surface
  /// so json_tree can pre-validate sibling-key collisions before calling
  /// `renameConfigKey`.
  JsonAstNode? astAtPublic(List<String> path) => _astAt(path);

  /// Rename the Map key at [path] to [newKey]. Permissive — accepts any
  /// non-empty unique-among-siblings string. Validator surfaces any
  /// downstream references that go stale (e.g. `$ticker` lingering in
  /// output_schema after the input_schema entry was renamed).
  ///
  /// Returns silently on a no-op (same key), on read-only state, on
  /// non-Map parents, or when the new key clashes with a sibling — UI
  /// is expected to pre-validate so the user sees the rejection live.
  void renameConfigKey(List<String> path, String newKey) {
    if (_astRoot == null || path.isEmpty || _loadedWithErrors) return;
    if (newKey.isEmpty) return;
    final parentPath = path.sublist(0, path.length - 1);
    final parent = _astAt(parentPath);
    if (parent is! JsonObject) return;
    final oldKey = path.last;
    if (oldKey == newKey) return;
    // Duplicate-key guard: skip silently. The AST helper would throw,
    // but throwing leaks through `_applyOpToAst` as a non-recoverable
    // op-log corruption; pre-filtering keeps the UI snappy and avoids
    // a transient "Save failed" badge for what is a user-correctable
    // typing mistake.
    for (final p in parent.properties.whereType<JsonProperty>()) {
      if (p.key == newKey) return;
    }

    // selectedExprPath rewrite: if the renamed key sits on the selection
    // path, the new path differs only in `path.last`. Patch in place so
    // the right-rail ExprPanel keeps pointing at the (renamed) leaf.
    if (selectedExprPath != null &&
        _pathStartsWith(selectedExprPath!, path)) {
      final newSel = List<String>.from(selectedExprPath!);
      newSel[path.length - 1] = newKey;
      selectedExprPath = newSel;
    }
    // Same for focusedNodePath — Ctrl+Shift+↑/↓ keeps acting on the
    // renamed entry without losing the keyboard target.
    if (focusedNodePath != null &&
        _pathStartsWith(focusedNodePath!, path)) {
      final newFoc = List<String>.from(focusedNodePath!);
      newFoc[path.length - 1] = newKey;
      focusedNodePath = newFoc;
    }

    if (!_applyOpToAst(RenameKeyOp(path, newKey), 'op.rename',
        {'path': path, 'newKey': newKey})) {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
  }

  void duplicateConfigNode(List<String> path) {
    if (_astRoot == null || path.isEmpty || _loadedWithErrors) return;
    final parentPath = path.sublist(0, path.length - 1);
    final lastKey = path.last;
    final parent = _astAt(parentPath);
    if (parent is JsonObject) {
      // Find unique key. The AST helper rejects collisions, but computing
      // it here keeps the op_log self-contained (replay-safe even if we
      // ever add a key-collision recovery upstream).
      final existing = <String>{
        for (final p in parent.properties.whereType<JsonProperty>()) p.key,
      };
      String newKey = '${lastKey}_copy';
      int i = 2;
      while (existing.contains(newKey)) { newKey = '${lastKey}_copy$i'; i++; }
      if (!_applyOpToAst(DuplicateOp(path, newKey: newKey),
          'op.duplicate.map', {'path': path, 'newKey': newKey})) {
        return;
      }
      // Map duplicate: appended at end → no array-index shift, selection
      // unaffected (sibling keys keep their map keys).
    } else if (parent is JsonArray) {
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
    if (_astRoot == null || path.isEmpty || _loadedWithErrors) return;
    if (delta == 0) return;
    final parentPath = path.sublist(0, path.length - 1);
    final parent = _astAt(parentPath);

    int? listIdx;
    if (parent is JsonArray) {
      listIdx = int.tryParse(path.last);
      if (listIdx == null) return;
    }

    if (!_applyOpToAst(MoveOp(path, delta), 'op.move',
        {'path': path, 'delta': delta})) {
      return;
    }

    if (parent is JsonArray && listIdx != null) {
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
  }

  /// Insert a child into the container at [path].
  ///
  /// For Map containers: [newKey] is required. When [atIndex] is null the
  /// entry is appended; non-null inserts at that raw peer position
  /// (Phase 5f canonical placement, computed by `SchemaGate.insertIndexFor`).
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
    if (_astRoot == null || _loadedWithErrors) return;
    final target = _astAt(path);
    if (target is JsonObject && newKey != null) {
      if (!_applyOpToAst(InsertOp(path, newKey, defaultValue, atIndex: atIndex),
          'op.insert.map',
          {'parentPath': path, 'newKey': newKey, 'atIndex': atIndex})) {
        return;
      }
      _pendingFocusPath.value = [...path, newKey];
    } else if (target is JsonArray) {
      final n = target.elements.length;
      final clamped = atIndex == null ? n : atIndex.clamp(0, n);
      if (!_applyOpToAst(InsertOp(path, clamped.toString(), defaultValue),
          'op.insert.list',
          {'parentPath': path, 'index': clamped})) {
        return;
      }
      _pendingFocusPath.value = [...path, clamped.toString()];
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
  }

  /// Edit a comment's text body. [path] ends in `$comm_<N>`. [newText] is
  /// the body without `//` / `/* */` markers.
  void editCommentNode(List<String> path, String newText) {
    if (_astRoot == null || _loadedWithErrors) return;
    if (path.isEmpty || !path.last.startsWith(r'$comm_')) return;
    if (!_applyOpToAst(EditCommentOp(path, newText), 'op.editComment',
        {'path': path, 'newText': newText})) {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
  }

  /// Delete a standalone / leading / block comment.
  void deleteCommentNode(List<String> path) {
    if (_astRoot == null || _loadedWithErrors) return;
    if (path.isEmpty || !path.last.startsWith(r'$comm_')) return;
    if (!_applyOpToAst(DeleteCommentOp(path), 'op.deleteComment',
        {'path': path})) {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
  }

  /// Duplicate a comment in place — the clone is inserted as the next
  /// peer entry of [path]. Mirrors [duplicateConfigNode] for real-key
  /// duplicates so users get the same "right after the source" behaviour
  /// for either kind of row.
  void duplicateCommentNode(List<String> path) {
    if (_astRoot == null || path.isEmpty || _loadedWithErrors) return;
    if (!path.last.startsWith(r'$comm_')) return;
    if (!_applyOpToAst(DuplicateCommentOp(path),
        'op.duplicateComment', {'path': path})) {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
  }

  /// Insert a fresh trailing INLINE comment attached to [anchorPath]
  /// (`key: value, // text`). Mirrors [insertCommentNode] but produces
  /// an inline-placement CommentLine instead of a leading standalone
  /// row.
  void insertInlineCommentNode(
      List<String> anchorPath, String style, String text) {
    if (_astRoot == null || _loadedWithErrors) return;
    if (anchorPath.isEmpty) return;
    if (!_applyOpToAst(InsertInlineCommentOp(anchorPath, style, text),
        'op.insertInlineComment',
        {'anchorPath': anchorPath, 'style': style})) {
      return;
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
  }

  /// Insert a fresh leading comment immediately above [anchorPath].
  /// [style] is `"//"` or `"/*"`. [text] is the body without markers.
  void insertCommentNode(List<String> anchorPath, String style, String text) {
    if (_astRoot == null || _loadedWithErrors) return;
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
  }

  /// Last error thrown during saveConfig, null when the save succeeded.
  /// StatusBar surfaces this to the user.
  String? configSaveError;
  // True while a manual VALIDATE pass is in flight. Mirrors `isSaving`
  // so the toolbar can grey the button and the Ctrl+V shortcut can no-op
  // on re-press.
  bool isValidating = false;

  /// True while a saveConfig is in flight — write tmp, spawn bxp-fmt
  /// validation, backup, rename, reload. The toolbar SAVE button uses
  /// this to show a "SAVING…" label so the user gets feedback during
  /// the (possibly slow) round-trip. Mirrors bxp-ui's
  /// `configSaveStatus === "saving"` state.
  bool isSaving = false;

  Future<void> saveConfig() async {
    if (_astRoot == null || configPath.isEmpty) return;
    if (isSaving) return; // re-entrancy guard against double-click
    // Nothing to save: the toolbar/Ctrl+S gates on `isDirty`, but a
    // programmatic call with an empty op log would otherwise round-trip
    // through tmp-write + bxp-fmt validation + backup + rename for
    // bytes identical to the on-disk file. Skip the whole dance.
    if (_activeOps.isEmpty) {
      devTrace('saveConfig.noop', {'path': configPath});
      return;
    }
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
      // Mirrors bxp-ui's saveConfig pre-flight check. On failure we also
      // refresh the diagnostic maps from `parsed` so tree badges align with
      // the tooltip; the unparseable-output branch leaves them alone (the
      // AST is still well-formed and existing markers stay more useful
      // than a wipe-to-empty on a transient blip).
      Future<void> failPreSave(String msg, {dynamic parsedForDiag}) async {
        try { await tmpFile.delete(); } catch (_) {}
        if (parsedForDiag != null) {
          final b = _extractDiagnostics(parsedForDiag);
          _validationErrors = b.errors;
          _validationWarnings = b.warnings;
          _validationInfo = b.info;
          _detectFsTimeout();
        }
        configSaveError = msg;
        notifyListeners();
      }

      final validation = await BxpProcessClient.loadConfig(
        tmpPath,
        checkFsSeconds: _activeFsCheckSeconds(),
      );
      try {
        final parsed = jsonDecode(validation);
        final err = parsed is Map ? parsed['error'] as String? : null;
        if (err != null) {
          await failPreSave('pre-save validation failed: $err',
              parsedForDiag: parsed);
          return;
        }
        // bxp-fmt exits with annotated JSON (no top-level "error") even when
        // it found `$err_*` markers inside the tree — exit code 1 + stdout.
        // Without this scan, a syntactically broken save would still go
        // through and trap the user in readonly-on-reload mode.
        final treeErr = _firstErrTraceIn(parsed);
        if (treeErr != null) {
          await failPreSave('pre-save validation failed: $treeErr',
              parsedForDiag: parsed);
          return;
        }
      } catch (_) {
        // bxp-fmt printed something unparseable — treat as failure.
        await failPreSave('pre-save validation produced unreadable output');
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
      _astBaseline = _astRoot?.clone();
      _astHistory.clear();
      if (_astRoot != null) _astHistory.add(_astRoot!.clone());
      _historyIndex = 0;
      _isDirty = false;
      _opLog.clear();
      notifyListeners();

      // Re-run bxp-fmt so validation markers ($err_/$comm_) refresh against
      // the new on-disk content. (Also captures fresh raw bytes and resets
      // the op log baseline.) `preserveTreeState: true` keeps the user's
      // expansion state and active expr selection — Save isn't a "fresh
      // file" event from their perspective, just internal bookkeeping.
      await loadConfig(preserveTreeState: true);
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

  /// Manual deep-validation pass triggered by the VALIDATE toolbar button
  /// (or Ctrl+V). Runs `bxp-fmt --config <path> --check-fs=2`, refreshes
  /// the path-keyed `$err_*`/`$warn_*`/`$info_*` maps, and re-uses the
  /// adaptive `[fs.timeout]` flag so a slow mount only pays the deadline
  /// once per session. When the user has unsaved edits the current draft
  /// is dumped to `<path>.bxp-tmp-validate` first; otherwise the on-disk
  /// file is validated directly.
  Future<void> runValidate() async {
    if (_astRoot == null || configPath.isEmpty) return;
    if (isValidating || isSaving || isLoadingConfig) return;
    devTrace('runValidate.start',
        {'path': configPath, 'dirty': _isDirty, 'opCount': _activeOps.length});
    isValidating = true;
    notifyListeners();
    final tmpPath = '$configPath.bxp-tmp-validate';
    File? tmpFile;
    String pathToValidate = configPath;
    try {
      // Validate the current draft, not the on-disk file. If there are
      // pending ops, dump the AST to a tmp file so the validator sees what
      // the user is actually looking at; clean drafts validate the file
      // directly to avoid the round-trip cost.
      if (_isDirty && _activeOps.isNotEmpty && _rawConfigInput != null) {
        try {
          final outBytes = AstPatchClient.apply(_rawConfigInput!, _activeOps);
          tmpFile = File(tmpPath);
          await tmpFile.writeAsString(utf8.decode(outBytes), flush: true);
          pathToValidate = tmpPath;
        } on AstPatchError catch (e) {
          configError = 'AST patch failed during validate: ${e.message}';
          devTrace('runValidate.astPatchFail', {'message': e.message});
          return;
        }
      }
      final jsonOutput = await BxpProcessClient.loadConfig(
        pathToValidate,
        checkFsSeconds: 2,
      );
      final bxpTree = jsonDecode(jsonOutput);
      if (bxpTree is Map<String, dynamic>) {
        final fatal = bxpTree['error'] as String?;
        if (fatal != null) {
          configError = fatal;
          _clearValidationDiagnostics();
        } else {
          final buckets = _extractDiagnostics(bxpTree);
          _validationErrors = buckets.errors;
          _validationWarnings = buckets.warnings;
          _validationInfo = buckets.info;
          _detectFsTimeout();
          configError = null;
        }
      }
      devTrace('runValidate.ok', {
        'errors': _validationErrors.length,
        'warnings': _validationWarnings.length,
        'info': _validationInfo.length,
      });
    } catch (e, st) {
      configError = 'validate failed: $e';
      devTrace('runValidate.fail', {
        'err': e.toString(),
        'stack': st.toString().split('\n').take(3).join(' | '),
      });
    } finally {
      if (tmpFile != null) {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
      }
      // Refresh Dart-side diagnostics so the toolbar's combined view
      // reflects native checks alongside the bxp-fmt result that the
      // VALIDATE button is primarily about. _revalidateDart()
      // already runs from edit hooks; this extra call covers the
      // case where the user clicks VALIDATE without any pending
      // edits and expects ALL diagnostics to refresh in lockstep.
      _revalidateDart();
      isValidating = false;
      // Surface the post-validate transient toast so the user gets a
      // visible confirmation when the run is fast (sub-100ms on local
      // disk the in-flight badge barely flickers). Cleared on the
      // next user action or by `_clearValidateToast` after a short
      // timeout — see lastValidateToast below.
      _setValidateToast();
      notifyListeners();
    }
  }

  /// Transient summary string emitted by [runValidate] for the toolbar
  /// snackbar. Null = no toast pending; non-null = display + auto-clear
  /// after [_validateToastMs]. Mirrors the path-keyed buckets so the
  /// caller can reach the same numbers via diagnosticsCount.
  String? _validateToast;
  String? get validateToast => _validateToast;
  static const int _validateToastMs = 8000;
  Timer? _validateToastTimer;

  /// Build the validate toast summary string from the current diagnostic
  /// bucket sizes and schedule its auto-clear after [_validateToastMs].
  /// Counts both bxp-fmt and Dart-side buckets so the summary reflects all
  /// active diagnostics, not just what the most recent VALIDATE run found.
  void _setValidateToast() {
    final errs = _validationErrors.length + _dartErrors.length;
    final warns = _validationWarnings.length + _dartWarnings.length;
    final infos = _validationInfo.length + _dartInfo.length;
    if (errs == 0 && warns == 0 && infos == 0) {
      _validateToast = 'Validation OK';
    } else {
      final parts = <String>[];
      if (errs > 0) parts.add('$errs error${errs == 1 ? '' : 's'}');
      if (warns > 0) parts.add('$warns warning${warns == 1 ? '' : 's'}');
      if (infos > 0) parts.add('$infos info');
      _validateToast = 'Validate: ${parts.join(', ')}';
    }
    // Cancel any pending timer before starting a new one — avoids a double-
    // clear if the user clicks VALIDATE twice in quick succession.
    _validateToastTimer?.cancel();
    _validateToastTimer = Timer(const Duration(milliseconds: _validateToastMs), () {
      if (_disposed) return;
      _validateToast = null;
      notifyListeners();
    });
  }

  /// Dismiss the validate toast before the auto-clear timer fires.
  /// Called by the toolbar on any user action that invalidates the toast
  /// (e.g. a new edit or run start) so it doesn't linger misleadingly.
  void clearValidateToast() {
    _validateToastTimer?.cancel();
    if (_validateToast != null) {
      _validateToast = null;
      notifyListeners();
    }
  }

  /// `YYYYMMDDHHMMSS` — sortable, no separators, safe in any filesystem.
  String _backupTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// Trigger a dry-run (no output files written, `--dry-run` flag passed to
  /// bxp-cli). Idempotent — a second call while a run is in flight is a no-op
  /// at the `_streamRun` level because it sets `status = running` first.
  Future<void> runDryRun() {
    devTrace('action.run.dry');
    return _streamRun(dry: true);
  }

  /// Trigger a full run (output files written to `data_dir`). Same streaming
  /// mechanics as [runDryRun] but without `--dry-run`.
  Future<void> runFullRun() {
    devTrace('action.run.full');
    return _streamRun(dry: false);
  }

  /// Live handle to the bxp-cli process spawned by `_streamRun`. Set inside
  /// the spawn callback and cleared in the run's `finally` block, so a
  /// non-null value means a streaming run is currently executing and can
  /// be killed by [cancelRun].
  Process? _runProcess;

  /// True between `cancelRun()` and the moment `_runProcess` reaches
  /// `exitCode`. Used by the toolbar to flip the run-button label to
  /// "cancelling…" so the user sees that the click registered even before
  /// bxp-cli actually exits.
  bool _cancelRequested = false;
  bool get isCancelling => _cancelRequested;

  /// Sends SIGTERM to the running bxp-cli child. The streaming `_streamRun`
  /// future then collapses to the post-loop cleanup with whatever lines
  /// landed before the kill — partial output stays visible. No-op when no
  /// run is in flight.
  ///
  /// When the user clicks Cancel between status=running and Process.start
  /// returning, `_runProcess` is still null. We flip `_cancelRequested`
  /// anyway so `onSpawn` (below) can kill the child the moment the handle
  /// shows up — otherwise an early click would silently no-op and the
  /// run would race to completion ignoring the user.
  void cancelRun() {
    if (status != RunStatus.running) return;
    _cancelRequested = true;
    final proc = _runProcess;
    if (proc != null) {
      devTrace('action.run.cancel', {'pid': proc.pid});
      proc.kill(ProcessSignal.sigterm);
    } else {
      devTrace('action.run.cancel', {'pendingSpawn': true});
    }
    notifyListeners();
  }

  /// Select a file by its composite id. Automatically selects the first
  /// row of the newly chosen file so RowDetail and OutputPanel are never
  /// empty after a file-switch — mirrors bxp-ui's auto-select behaviour.
  void selectFile(String? id) {
    if (selectedFileId == id) return;
    devTrace('action.file.select', {'id': id});
    selectedFileId = id;
    // Auto-select the first row in the newly selected file so RowDetail
    // and OutputPanel populate immediately.
    final file = id == null ? null : traceModel?.files[id];
    selectedRowId = file != null && file.rowIds.isNotEmpty ? file.rowIds.first : null;
    notifyListeners();
  }

  /// Select a row by its synthetic id (`r0`, `r1`, …). Null deselects.
  void selectRow(String? id) {
    if (selectedRowId == id) return;
    devTrace('action.row.select', {'id': id});
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
    _traceLinesCounter.value = 0;
    lastExitCode = null;
    selectedFileId = null;
    selectedRowId = null;
    // Drop the per-(row, expr) trace cache: the row IDs and expression
    // texts a fresh run produces are unrelated to the previous run's
    // entries, so keeping them around just leaks memory.
    _exprCallCache.clear();
    _exprCallInFlight.clear();

    // Fresh builder so subsequent runs start clean.
    final builder = TraceBuilder();
    traceModel = builder.model;
    // One main notify to flip status to running and clear stale model.
    _fileGen.value++;
    notifyListeners();

    // Counter ticker — only refreshes the `trace lines` ValueNotifier.
    // Crucially does NOT call main `notifyListeners()`, so RowList /
    // OutputPanel / status-bar aggregates do not rebuild per tick.
    final ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_traceLinesCounter.value != rawLines) {
        _traceLinesCounter.value = rawLines;
      }
    });

    int prevFileCount = 0;

    // bxp-cli interprets an omitted --template as "process everything".
    try {
      final spawn = dry ? BxpProcessClient.runDryRun : BxpProcessClient.runFullRun;
      final result = await spawn(
        configPath: configPath,
        templateId: templateId,
        onSpawn: (p) {
          _runProcess = p;
          // The user may have clicked Cancel during the brief window
          // between status=running and Process.start completing. If so,
          // honour the request now that we finally have the handle —
          // otherwise the run would race to completion ignoring the
          // pending cancellation.
          if (_cancelRequested) {
            p.kill(ProcessSignal.sigterm);
          }
        },
        onLine: (line) {
          rawLines++;
          builder.parseLine(line);

          // FileList grows live: bump `fileGen` whenever a new file_start
          // landed. Cheap — typical M is < 50.
          final fc = builder.model.fileOrder.length;
          if (fc != prevFileCount) {
            prevFileCount = fc;
            _fileGen.value++;
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
          _stderrBuffer.write(chunk);
          _stderrCache = null;
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
      // SIGTERM/SIGKILL show up as negative exit codes too — treat a
      // user-requested cancel as a clean done, not an error. Otherwise
      // the toolbar would surface the kill signal as "spawn failed".
      if (_cancelRequested) {
        status = RunStatus.done;
        runError = 'cancelled';
        return;
      }
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
      // Drop the process handle so a stray cancelRun() click after the
      // run completes is a harmless no-op instead of double-killing a
      // dead PID (or worse, a recycled one).
      _runProcess = null;
      _cancelRequested = false;
      // Final sync — the last 100ms tick may have fired before the
      // closing batch of lines arrived, leaving the counter short of
      // the true total. Without this the displayed number is
      // non-deterministic (varies per run).
      if (_traceLinesCounter.value != rawLines) {
        _traceLinesCounter.value = rawLines;
      }
      // Always notify on exit. The error / cancel branches above do an
      // early `return`, which would skip the closing notify below and
      // leave the toolbar stuck in `isCancelling` (last notify came from
      // `cancelRun()` with the flag set). Putting the notify in `finally`
      // guarantees one final UI update regardless of which exit path ran.
      notifyListeners();
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

  /// Real template IDs from the live AST (no synthetic entries). The
  /// empty string is used separately in the UI to mean "all templates".
  ///
  /// Memoised against [treeLoadGen]: `_AddChildDialog` and the template
  /// picker hit this on every rebuild, and walking `properties` linearly
  /// for a deeply-nested config adds up. Cache invalidates whenever the
  /// tree is reloaded (load / save / external edit).
  int _availableTemplatesGen = -1;
  List<String> _availableTemplatesCache = const [];
  List<String> get availableTemplates {
    if (_availableTemplatesGen == treeLoadGen) {
      return _availableTemplatesCache;
    }
    final root = _astRoot;
    List<String> result = const [];
    if (root is JsonObject) {
      for (final p in root.properties.whereType<JsonProperty>()) {
        if (p.key != 'conversion_templates') continue;
        final v = p.value;
        if (v is JsonObject) {
          result = [
            for (final tp in v.properties.whereType<JsonProperty>()) tp.key,
          ];
        }
        break;
      }
    }
    _availableTemplatesCache = result;
    _availableTemplatesGen = treeLoadGen;
    return result;
  }

  /// Rich template metadata (data_dir / file_pattern_in / description)
  /// pulled from `bxp-fmt --config <path> --list-templates` after each
  /// successful config load. Empty when the lookup hasn't run yet or the
  /// CLI call failed — callers fall back to [availableTemplates] for IDs.
  List<TemplateInfo> _templateInfos = const [];
  List<TemplateInfo> get availableTemplateInfos => _templateInfos;

  /// True if a path encoded by [_encodePath] still resolves in the
  /// current AST. Empty path is the root and is always alive. Used to
  /// hide validation diagnostics whose target node has been deleted
  /// since the last load/save — the validator only re-runs at those
  /// boundaries, so without this filter the status bar keeps quoting
  /// errors at paths the user can no longer see.
  bool _validationPathAlive(String encodedPath) {
    if (encodedPath.isEmpty) return true;
    return _astAt(encodedPath.split('\x00')) != null;
  }

  /// True if the last `bxp-fmt --config` run OR the live Dart-side
  /// validator (`_revalidateDart`) produced any `$err_*` / `$dart_<N>`
  /// diagnostic that still points at a live AST node. Used to gate
  /// run buttons and display the error trace in the status bar.
  bool get configHasErrors {
    if (_validationErrors.isEmpty && _dartErrors.isEmpty) return false;
    for (final k in _validationErrors.keys) {
      if (_validationPathAlive(k)) return true;
    }
    for (final k in _dartErrors.keys) {
      if (_validationPathAlive(k)) return true;
    }
    return false;
  }

  /// First `$err_*` message found across the validation map whose
  /// path still resolves in the current AST, or null when the config
  /// is clean (or every remaining error is an orphan).
  ///
  /// Iteration order: `_validationErrors` is a `LinkedHashMap` keyed by
  /// path string in the order entries were inserted by
  /// `_extractValidationErrors` (DFS over the annotated `bxp-fmt --config`
  /// output, top-down). Within each path, the inner map preserves
  /// `$err_<N>` insertion order (i.e. emission order in the annotated
  /// JSON). Callers may treat the first non-empty hit as "the visually
  /// topmost error" — which is what the StatusBar pencil-icon shortcut
  /// jumps to.
  String? get firstConfigErrorTrace {
    for (final e in _validationErrors.entries) {
      if (!_validationPathAlive(e.key)) continue;
      for (final v in e.value.values) {
        if (v.isNotEmpty) return v;
      }
    }
    for (final e in _dartErrors.entries) {
      if (!_validationPathAlive(e.key)) continue;
      for (final v in e.value.values) {
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  /// Combined diagnostic text from every error source the UI surfaces:
  /// load-side configError, save-side configSaveError, **all** bxp-fmt
  /// `$err_*` / `$warn_*` / `$info_*` traces (stacked with one
  /// per line, severity-prefixed), Dart-side `$dart_<N>` entries from
  /// `_revalidateDart`, plus the runtime stderr stream from a dry/full
  /// run. Drives the single clickable `stderr (NB)` badge in the bottom
  /// status bar — the badge's byte count and its expansion panel both
  /// read from this getter so config errors and pipeline stderr live in
  /// one click target instead of three duplicated inline labels.
  ///
  /// Polish 2 — every diagnostic is listed (was: only the first
  /// `$err_*` trace). Order: errors first, then warnings, then info,
  /// each grouped by source bucket. Path is prefixed so the user can
  /// jump from the badge text to the offending node.
  String get diagnosticBlob {
    final parts = <String>[];

    void emitBucket(
      String severity,
      Map<String, Map<String, String>> bucket,
    ) {
      for (final e in bucket.entries) {
        if (!_validationPathAlive(e.key)) continue;
        final path = e.key.replaceAll('\x00', '.');
        for (final msg in e.value.values) {
          if (msg.isEmpty) continue;
          parts.add('$severity $path: $msg');
        }
      }
    }

    emitBucket('[error]', _validationErrors);
    emitBucket('[error]', _dartErrors);
    emitBucket('[warn] ', _validationWarnings);
    emitBucket('[warn] ', _dartWarnings);
    emitBucket('[info] ', _validationInfo);
    emitBucket('[info] ', _dartInfo);

    if (configError != null) parts.add('config: $configError');
    if (configSaveError != null) parts.add('save: $configSaveError');
    if (stderrText.isNotEmpty) parts.add(stderrText);
    return parts.join('\n');
  }

  /// Opens [path] in the host's default application. Used by the
  /// StatusBar pencil-icon shortcut — mirrors bxp-ui's `openInEditor`
  /// RPC.
  ///
  /// Per-platform launchers:
  /// * **Linux** — `xdg-open`, the freedesktop entry point that hands
  ///   off to the user's MIME-default app.
  /// * **macOS** — `open`, which routes through Launch Services.
  /// * **Windows** — `explorer.exe <path>` routes through Shell execute
  ///   internally and triggers the user's default association for the
  ///   extension. Earlier alternatives that we tried and dropped:
  ///   - `Process.start('cmd', ['/c', 'start', '', path], detached)`
  ///     — dart:io's argv→cmdline conversion combined with detached
  ///     mode produced a command line that `start` rejected on a
  ///     non-trivial fraction of paths.
  ///   - `launchUrl(Uri.file(path))` from `url_launcher` — works for
  ///     `http://` URIs but the Windows plugin's ShellExecute call
  ///     consistently no-op'd on local file paths.
  ///   - `rundll32.exe url.dll,FileProtocolHandler <path>` — the
  ///     entry point's name suggests it'd handle file paths, but
  ///     it actually only handles URL protocols and silently exits
  ///     on plain file paths.
  ///   `explorer.exe` is the simplest entry point that works
  ///   everywhere. Its exit code is intentionally ignored (it always
  ///   exits 1 on success), and we don't pass `detached` because the
  ///   process self-exits as soon as ShellExecute hands off.
  Future<void> openInEditor(String path) async {
    if (path.isEmpty) return;
    devTrace('action.openInEditor', {'path': path});
    try {
      if (Platform.isLinux) {
        await Process.start('xdg-open', [path],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path], mode: ProcessStartMode.detached);
      } else if (Platform.isWindows) {
        // `explorer.exe path` is the canonical Windows "open this file
        // with its default association" call — it routes through Shell
        // execute internally and shows the OpenWith picker if no
        // association exists. Earlier attempts (rundll32
        // url.dll,FileProtocolHandler / Process.start cmd '/c' 'start')
        // either silently no-op'd on file paths or got mangled by
        // dart:io's argv→cmdline conversion when combined with
        // ProcessStartMode.detached. explorer.exe's exit code is
        // intentionally ignored (it always exits 1 on success), and
        // not-detached so dart:io spawns it through a regular console
        // child that hands off to ShellExecute and then dies.
        await Process.start('explorer.exe', [path]);
      }
    } catch (e) {
      devTrace('action.openInEditor.failed',
          {'path': path, 'error': e.toString()});
    }
  }

  /// Release every resource the store owns.
  ///
  /// In normal app lifetime the store is created once in `main` and lives
  /// to process exit, so the OS reaps everything anyway. The override
  /// matters under hot-restart and in tests, where a half-disposed
  /// instance with live timers / value notifiers would log
  /// `setState/notifyListeners called after dispose`.
  @override
  void dispose() {
    _disposed = true;
    _validationDebounce?.cancel();
    _traceLinesCounter.dispose();
    _fileGen.dispose();
    _pendingFocusPath.dispose();
    _pendingAddChildPath.dispose();
    super.dispose();
  }

  /// Stress-test hook used by `DebugPanelDialog` to fire a long burst
  /// of `notifyListeners()` calls without any actual state change.
  /// Validates whether the render pipeline can keep up with a flood
  /// of rebuild requests independent of pointer activity. Not for
  /// production use.
  void debugNotify() => notifyListeners();
}

