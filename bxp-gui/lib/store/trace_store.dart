import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/bxp_process_client.dart';
import '../services/json5_emitter.dart';
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
  
  // Runtime State
  RunStatus status = RunStatus.idle;
  RunMode runMode = RunMode.none;
  String? runError;
  String stderrText = '';
  int rawLines = 0;
  // Exit code from the most recent dry-run / full-run, captured so the
  // status bar can show "done · exit N" with the right colour:
  //   0 → success (emerald), 2 → completed with warnings (amber),
  //   anything else → red. Mirrors bxp-ui's StatusBar logic.
  int? lastExitCode;
  
  Map<String, dynamic>? configJson;
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

  void jumpToConfigRule(int ruleIndex, String whenExpr) {
    setActiveTab(0);
    final path = ['conversion_templates', templateId, 'row_rules', ruleIndex.toString(), 'when'];
    setSelectedExpr(path, whenExpr);
  }

  // Debouncer for expression validation. Spawn-based validateExpr costs
  // ~10–20ms per call — fine when fired on explicit selection, but would
  // hammer the CLI on every keystroke. 200ms balances responsiveness
  // against CPU load and feels instant to the typist.
  Timer? _validationDebounce;

  void setSelectedExpr(List<String> path, String text) {
    selectedExprPath = path;
    selectedExprText = text;
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

  void clearSelectedExpr() {
    selectedExprPath = null;
    selectedExprText = '';
    exprValidationError = null;
    exprValidationState = ExprValidationState.idle;
    notifyListeners();
  }

  TraceStore() {
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('bxp-ui.theme');
    if (stored != null && stored.isNotEmpty) {
      _themePresetName = stored;
    }
    final ts = prefs.getString('bxp-ui.textScheme');
    if (ts != null && ts.isNotEmpty && bxpTextSchemes.containsKey(ts)) {
      _textSchemeName = ts;
    }
    _recentFiles = prefs.getStringList('bxp-ui.recent') ?? [];
    _customPlaces = prefs.getStringList('bxp-gui.customPlaces') ?? [];
    notifyListeners();

    // Pull the canonical docs catalog from the CLI in the background. We
    // don't await it — the UI is usable before docs arrive, and the
    // ExprPanel falls back to "no docs yet" instead of blocking startup.
    // ignore: discarded_futures
    BxpProcessClient.getDocs().then((d) {
      if (d != null) {
        docs = d;
        notifyListeners();
      }
    });

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

  void setConfigPath(String path) {
    configPath = path;
    notifyListeners();
  }

  void setTemplateId(String id) {
    templateId = id;
    notifyListeners();
  }

  Future<void> loadConfig() async {
    isLoadingConfig = true;
    notifyListeners();
    try {
      final jsonOutput = await BxpProcessClient.loadConfig(configPath);
      configJson = jsonDecode(jsonOutput) as Map<String, dynamic>;
      configError = configJson?['error'] as String?;
      if (configError != null) configJson = null;
    } catch (e) {
      configError = e.toString();
      configJson = null;
    } finally {
      isLoadingConfig = false;
    }
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
    _isDirty = false;
    _history.clear();
    _historyIndex = 0;
    _history.add(_deepCopy(configJson));
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

  void editConfigNode(List<String> path, dynamic newValue) {
    if (configJson == null) return;
    // Mirror bxp-ui's `readOnly = configHasErrors`: when the loaded tree
    // contains $err_* diagnostic markers, all mutations are blocked. The
    // ConfigView toolbar already greys out edit buttons, but the inline
    // tree editors (EditableString/Number/Boolean) commit through this
    // path — guarding here covers both surfaces uniformly.
    if (configHasErrors) return;

    final oldValue = _getAt(path);
    if (oldValue == newValue) return;
    
    // We clone the root to trigger a new reference, although Provider just needs notifyListeners()
    Map<String, dynamic> root = Map.from(configJson!);
    dynamic current = root;
    
    for (int i = 0; i < path.length - 1; i++) {
      final key = path[i];
      if (current is Map) {
        current[key] = current[key] is Map 
            ? Map<String, dynamic>.from(current[key] as Map)
            : current[key] is List
                ? List<dynamic>.from(current[key] as List)
                : current[key];
        current = current[key];
      } else if (current is List) {
        final idx = int.tryParse(key);
        if (idx != null && idx >= 0 && idx < current.length) {
          current[idx] = current[idx] is Map 
              ? Map<String, dynamic>.from(current[idx] as Map)
              : current[idx] is List
                  ? List<dynamic>.from(current[idx] as List)
                  : current[idx];
          current = current[idx];
        }
      }
    }
    
    final lastKey = path.last;
    if (current is Map) {
      current[lastKey] = newValue;
    } else if (current is List) {
      final idx = int.tryParse(lastKey);
      if (idx != null && idx >= 0 && idx < current.length) {
        current[idx] = newValue;
      }
    }
    
    configJson = root;
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
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

  bool get canUndo => _historyIndex > 0;
  bool get canRedo => _historyIndex < _history.length - 1;

  void _pushHistory() {
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(_deepCopy(configJson));
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
    if (configHasErrors) return; // edits are blocked anyway in this state
    configJson = _deepCopy(_savedBaseline);
    _isDirty = false;
    _history
      ..clear()
      ..add(_deepCopy(configJson));
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
      _recomputeDirty();
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
      _historyIndex++;
      configJson = _deepCopy(_history[_historyIndex]);
      _recomputeDirty();
      if (selectedExprPath != null) {
        final val = _getAt(selectedExprPath!);
        selectedExprText = val is String ? val : '';
        exprGeneration++;
      }
      notifyListeners();
    }
  }

  bool _deepEquals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final e in a.entries) {
        if (!b.containsKey(e.key)) return false;
        if (!_deepEquals(e.value, b[e.key])) return false;
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
    if (configJson == null || path.isEmpty || configHasErrors) return;
    final parentPath = path.sublist(0, path.length - 1);
    final lastKey = path.last;
    final parent = _getAt(parentPath);

    // Selection invalidation BEFORE the mutation so we can still inspect
    // the current path. Two cases that both clear the selection:
    //   - the deleted node IS the selected leaf
    //   - the deleted node is an ancestor of the selected leaf
    if (selectedExprPath != null &&
        _pathStartsWith(selectedExprPath!, path)) {
      clearSelectedExpr();
    }

    if (parent is Map) {
      parent.remove(lastKey);
    } else if (parent is List) {
      final removedIdx = int.tryParse(lastKey);
      if (removedIdx == null) return;
      parent.removeAt(removedIdx);
      // Shift sibling-selections downward: indices > removedIdx slide
      // up by one; the removed index itself was already cleared above.
      _shiftSelectionOnArrayEdit(parentPath, (oldIdx) {
        if (oldIdx == removedIdx) return -1; // shouldn't happen (cleared)
        if (oldIdx > removedIdx) return oldIdx - 1;
        return oldIdx;
      });
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
  }

  void duplicateConfigNode(List<String> path) {
    if (configJson == null || path.isEmpty || configHasErrors) return;
    final parentPath = path.sublist(0, path.length - 1);
    final lastKey = path.last;
    final parent = _getAt(parentPath);
    final value = _deepCopy(_getAt(path));
    if (parent is Map) {
      // Find unique key.
      String newKey = '${lastKey}_copy';
      int i = 2;
      while (parent.containsKey(newKey)) { newKey = '${lastKey}_copy$i'; i++; }
      parent[newKey] = value;
      // Map duplicate: appended at end → no array-index shift, selection
      // unaffected (sibling keys keep their map keys).
    } else if (parent is List) {
      final idx = int.tryParse(lastKey);
      if (idx == null) return;
      parent.insert(idx + 1, value);
      // Selection lives under same array AND was at index >= idx+1?
      // Then it slid one slot right. Selection on the duplicated source
      // (idx) stays put — the user still has the original highlighted.
      _shiftSelectionOnArrayEdit(parentPath, (oldIdx) {
        if (oldIdx > idx) return oldIdx + 1;
        return oldIdx;
      });
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
  }

  /// Reorder an array entry by swapping with its sibling.
  ///
  /// [path] points at the entry to move. [delta] is +1 (down) or -1 (up).
  /// Only works when the parent is a List. No-op at list edges.
  void moveConfigNode(List<String> path, int delta) {
    if (configJson == null || path.isEmpty || configHasErrors) return;
    final parentPath = path.sublist(0, path.length - 1);
    final parent = _getAt(parentPath);
    if (parent is! List) return;
    final idx = int.tryParse(path.last);
    if (idx == null) return;
    final newIdx = idx + delta;
    if (newIdx < 0 || newIdx >= parent.length) return;
    final tmp = parent[idx];
    parent[idx] = parent[newIdx];
    parent[newIdx] = tmp;
    // Two indices swapped places — selections on either follow.
    _shiftSelectionOnArrayEdit(parentPath, (oldIdx) {
      if (oldIdx == idx) return newIdx;
      if (oldIdx == newIdx) return idx;
      return oldIdx;
    });
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
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
    if (configJson == null || configHasErrors) return;
    final target = _getAt(path);
    if (target is Map && newKey != null) {
      target[newKey] = defaultValue;
    } else if (target is List) {
      final clamped = atIndex == null
          ? target.length
          : atIndex.clamp(0, target.length);
      target.insert(clamped, defaultValue);
      // Selections under the same array at indices >= clamped shifted up.
      _shiftSelectionOnArrayEdit(path, (oldIdx) {
        if (oldIdx >= clamped) return oldIdx + 1;
        return oldIdx;
      });
    }
    _recomputeDirty();
    _pushHistory();
    notifyListeners();
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
    configSaveError = null;
    isSaving = true;
    notifyListeners();
    final tmpPath = '$configPath.bxp-tmp';
    final tmpFile = File(tmpPath);
    try {
      // Emit JSON5 with comments preserved. The in-memory configJson
      // carries bxp-fmt's $comm_N annotations which the emitter converts
      // back into `// comment` lines; $err_N diagnostic markers are
      // dropped by the emitter.
      final text = Json5Emitter.emit(configJson);

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

      // History compresses to a single "saved" baseline so the undo stack
      // starts fresh after a successful write.
      _savedBaseline = _deepCopy(configJson);
      _history
        ..clear()
        ..add(_deepCopy(configJson));
      _historyIndex = 0;
      _isDirty = false;
      notifyListeners();

      // Re-run bxp-fmt so validation markers ($err_/$comm_) refresh against
      // the new on-disk content.
      await loadConfig();
    } catch (e) {
      // Clean up the tmp file if it leaked through an unexpected exception
      // path (e.g. rename failed after validation passed).
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      configSaveError = e.toString();
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
    lastExitCode = null;
    selectedFileId = null;
    selectedRowId = null;

    // Fresh builder so subsequent runs start clean.
    final builder = TraceBuilder();
    traceModel = builder.model;
    notifyListeners();

    // Throttle notifyListeners during the stream — rebuilding on every line
    // would tank rendering performance on fast pipelines.
    bool dirty = false;
    final ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (dirty) {
        dirty = false;
        notifyListeners();
      }
    });

    // bxp-cli interprets an omitted --template as "process everything".
    try {
      final spawn = dry ? BxpProcessClient.runDryRun : BxpProcessClient.runFullRun;
      final result = await spawn(
        configPath: configPath,
        templateId: templateId,
        onLine: (line) {
          rawLines++;
          builder.parseLine(line);
          // Auto-select the first file as soon as it streams in so the
          // RowList / RowDetail / OutputPanel populate live instead of
          // staying blank until the whole pipeline finishes. Mirrors
          // bxp-ui's pushLine handler. Only the *first* file_start
          // assigns selectedFileId; later files don't steal focus.
          if (selectedFileId == null && builder.model.fileOrder.isNotEmpty) {
            selectedFileId = builder.model.fileOrder.first;
          }
          dirty = true;
        },
        // Live stderr stream — the StatusBar surfaces it via the
        // expandable "stderr (NB)" detail. Mirrors bxp-ui pushStderr so
        // the user sees pipeline warnings as they happen rather than
        // batched at the end.
        onStderr: (chunk) {
          stderrText += chunk;
          dirty = true;
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
        if (k.startsWith(r'$err_') || k.startsWith(r'$comm_')) continue;
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
