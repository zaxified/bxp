import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/dev_trace.dart';
import '../services/gui_mcp_server.dart';
import '../services/schema_gate.dart';
import '../store/trace_store.dart';
import 'debug_panes.dart';
import 'config_view.dart';
import 'layout_defaults.dart';
import 'components/top_bar.dart';
import 'components/open_dialog.dart';
import 'theme/bxp_theme.dart';
import 'theme/bxp_text.dart';
import 'theme/theme_inspector.dart';
import 'settings_inspector.dart';
import 'platform_shortcuts.dart';

class MainView extends StatefulWidget {
  const MainView({super.key});

  @override
  State<MainView> createState() => _MainViewState();
}

class _MainViewState extends State<MainView> {
  /// Ctrl+Shift+T toggles the [ThemeInspector] floating drawer. Lives
  /// in MainView state (not TraceStore) because it's a debug-only
  /// affordance — no need to persist across restarts or notify other
  /// widgets.
  bool _inspectorOpen = false;

  /// Ctrl+Shift+S toggles the [SettingsInspector] floating drawer.
  /// Same rationale as `_inspectorOpen` — transient overlay, no need
  /// to round-trip through TraceStore.
  bool _settingsOpen = false;

  @override
  void initState() {
    super.initState();
    // App-wide shortcut handler. CallbackShortcuts at the root only fires
    // when the focused widget bubbles the key event up — many tree InkWells
    // and scroll containers don't, so Ctrl+S etc. used to be dead unless
    // focus happened to be on a bubbling TextField (e.g. the expr editor).
    // HardwareKeyboard sees every key before focus routing, so we get true
    // global coverage; we still ignore Ctrl+S/O/R/T while a TextField is
    // focused so internal editing keystrokes (Ctrl+A select-all etc.) keep
    // their meaning, but Ctrl+S we always intercept — there's no in-field
    // semantics for Save and the user expects it to fire from anywhere.
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  /// True when keyboard focus is inside an editable text field (TextField,
  /// CodeMirror-style editor, etc.). Used to opt out of global Ctrl+Z/Y so
  /// in-field typo-undo / redo keep their native meaning.
  bool _focusInEditableText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText;
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!isCommandModifierPressed()) return false;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final shift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
    final store = context.read<TraceStore>();
    // Mirror the toolbar's disabled conditions so a shortcut never fires
    // an action the equivalent button greys out (save while invalid,
    // undo with empty history, reset on a clean tree, …).
    final readOnly = store.configLoadHadErrors;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyS:
        // Ctrl+Shift+S toggles the settings/runtime inspector. Mirrors the
        // Ctrl+Shift+T branch in keyT below — keep both shift-modified
        // shortcuts firing regardless of save preconditions, since they're
        // pure UI overlays and have nothing to do with the config.
        if (shift) {
          devTrace('action.shortcut',
              {'combo': 'Ctrl+Shift+S', 'action': 'toggleSettings'});
          setState(() => _settingsOpen = !_settingsOpen);
          return true;
        }
        if (readOnly ||
            !store.isDirty ||
            store.isSaving ||
            store.configHasErrors) {
          return true;
        }
        devTrace('action.shortcut', {'combo': 'Ctrl+S', 'action': 'save'});
        store.saveConfig();
        return true;
      case LogicalKeyboardKey.keyZ:
        // Ctrl+Z inside any editable text field must keep its native
        // typo-undo meaning. Only intercept for the global config undo
        // when focus is somewhere structural (tree, panels, top bar).
        if (_focusInEditableText()) return false;
        if (readOnly || !store.canUndo) return true;
        devTrace('action.shortcut', {'combo': 'Ctrl+Z', 'action': 'undo'});
        store.undo();
        return true;
      case LogicalKeyboardKey.keyY:
        if (_focusInEditableText()) return false;
        if (readOnly || !store.canRedo) return true;
        devTrace('action.shortcut', {'combo': 'Ctrl+Y', 'action': 'redo'});
        store.redo();
        return true;
      case LogicalKeyboardKey.keyO:
        devTrace('action.shortcut', {'combo': 'Ctrl+O', 'action': 'openDialog'});
        OpenDialog.show(context, (path) async {
          store.setConfigPath(path);
          await store.loadConfig();
        });
        return true;
      case LogicalKeyboardKey.keyR:
        if (store.configPath.isEmpty) return true;
        devTrace('action.shortcut', {'combo': 'Ctrl+R', 'action': 'reload'});
        store.loadConfig();
        return true;
      case LogicalKeyboardKey.keyE:
        // Ctrl+E for validate. Ctrl+V was the obvious mnemonic but
        // collides with paste inside text fields; Ctrl+E has no native
        // text-editing semantics and is unused by the rest of the app.
        if (store.configPath.isEmpty ||
            store.astRoot == null ||
            store.isValidating ||
            store.isSaving ||
            store.isLoadingConfig) {
          return true;
        }
        devTrace('action.shortcut', {'combo': 'Ctrl+E', 'action': 'validate'});
        store.runValidate();
        return true;
      case LogicalKeyboardKey.keyT:
        if (shift) {
          devTrace('action.shortcut',
              {'combo': 'Ctrl+Shift+T', 'action': 'toggleThemeInspector'});
          setState(() => _inspectorOpen = !_inspectorOpen);
          return true;
        }
        if (readOnly || !store.isDirty) return true;
        devTrace('action.shortcut', {'combo': 'Ctrl+T', 'action': 'resetDraft'});
        store.resetDraft();
        return true;
      case LogicalKeyboardKey.arrowUp:
        if (!shift) return false;
        return _moveFocused(store, -1);
      case LogicalKeyboardKey.arrowDown:
        if (!shift) return false;
        return _moveFocused(store, 1);
      case LogicalKeyboardKey.delete:
        if (!shift) return false;
        return _deleteFocused(store);
      case LogicalKeyboardKey.insert:
        if (!shift) return false;
        return _addChildFocused(store);
    }
    return false;
  }

  /// Move the keyboard-focused tree node by [delta] positions. Mirrors
  /// the toolbox up/down arrow buttons.
  bool _moveFocused(TraceStore store, int delta) {
    final path = store.focusedNodePath;
    if (path == null || path.isEmpty) return true;
    if (store.configLoadHadErrors) return true;
    devTrace('action.shortcut', {
      'combo': delta < 0 ? 'Ctrl+Shift+Up' : 'Ctrl+Shift+Down',
      'action': 'moveFocused',
      'path': path,
    });
    store.moveConfigNode(path, delta);
    return true;
  }

  /// Delete the keyboard-focused tree node. Mirrors the toolbox × button
  /// — silently no-ops on required keys (so a held-down Ctrl+Shift+Del
  /// doesn't accidentally wipe sibling content past the required gate).
  /// Comment rows (`$comm_<N>` last segment) route through the comment-
  /// specific store API so the AST patcher uses `DeleteCommentOp`.
  bool _deleteFocused(TraceStore store) {
    final path = store.focusedNodePath;
    if (path == null || path.isEmpty) return true;
    if (store.configLoadHadErrors) return true;
    if (path.last.startsWith(r'$comm_')) {
      devTrace('action.shortcut', {
        'combo': 'Ctrl+Shift+Del',
        'action': 'deleteCommentFocused',
        'path': path,
      });
      store.deleteCommentNode(path);
      return true;
    }
    if (!SchemaGate(store).canDelete(path)) return true;
    devTrace('action.shortcut',
        {'combo': 'Ctrl+Shift+Del', 'action': 'deleteFocused', 'path': path});
    store.deleteConfigNode(path);
    return true;
  }

  /// Request the Add-Child dialog over the keyboard-focused tree node.
  /// The dialog needs the parent JsonObject reference held by the
  /// matching `_JsonNodeState` — we signal via `requestAddChildAt` and
  /// the node consumes the request in its `pendingAddChildPath` listener.
  bool _addChildFocused(TraceStore store) {
    final path = store.focusedNodePath;
    if (path == null) return true;
    if (store.configLoadHadErrors) return true;
    devTrace('action.shortcut', {
      'combo': 'Ctrl+Shift+Insert',
      'action': 'addChildFocused',
      'path': path,
    });
    store.requestAddChildAt(path);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final activeTab = store.activeTabIndex;

    // Shortcuts are wired via HardwareKeyboard in initState — see comment
    // there. We still keep autofocus so text fields don't capture initial
    // focus before the user clicks anywhere.
    return Focus(
      autofocus: true,
      child: Scaffold(
          body: Stack(
            children: [
              Column(
                children: [
                  // Top navigation bar (CONFIG · RUNNER · GITHUB · BLUE/GRAY)
                  const TopBar(),
                  // Main content
                  Expanded(
                    child: IndexedStack(
                      index: activeTab,
                      children: const [
                        ConfigView(),
                        DebugPanes(),
                      ],
                    ),
                  ),
                  // Status bar
                  const _StatusBar(),
                ],
              ),
              if (_inspectorOpen)
                ThemeInspector(
                    onClose: () => setState(() => _inspectorOpen = false)),
              if (_settingsOpen)
                SettingsInspector(
                    onClose: () => setState(() => _settingsOpen = false)),
            ],
          ),
        ),
    );
  }
}

class _StatusBar extends StatefulWidget {
  const _StatusBar();

  @override
  State<_StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<_StatusBar> {
  bool _stderrExpanded = false;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final model = store.traceModel;
    final t = context.bxpTheme;

    // Dev/testing banner: the gui-mcp's confirmation dialogs are being
    // auto-approved (BXP_GUI_MCP_AUTO_APPROVE). Surfaced as a red-framed chip
    // so a watching user always sees the safety gate is off. Constant for the
    // app's lifetime, so a plain read (no rebuild dependency) is enough.
    final autoApprove = context.read<GuiMcpServer>().autoApprove;

    final bg = t.panelBg;
    final borderColor = t.borderColor;

    // If the diagnostic blob drained out from under us (new run started
    // cleanly, or store reloaded) collapse the expanded panel — otherwise
    // the next chunk of stderr would make it snap open without the user
    // clicking it.
    if (store.diagnosticBlob.isEmpty && _stderrExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (store.diagnosticBlob.isEmpty && _stderrExpanded) {
          setState(() => _stderrExpanded = false);
        }
      });
    }

    // Config-level status: IDLE (nothing loaded) / LOADED / ERROR.
    final String configStatusText;
    final Color configStatusColor;
    if (store.configPath.isEmpty) {
      configStatusText = 'IDLE';
      configStatusColor = t.textMuted;
    } else if (store.configError != null || store.configHasErrors) {
      configStatusText = 'ERROR';
      configStatusColor = t.errorText;
    } else if (store.astRoot != null) {
      configStatusText = 'LOADED';
      configStatusColor = t.okText;
    } else {
      configStatusText = 'IDLE';
      configStatusColor = t.textMuted;
    }

    // Run status label + color. Exit code maps to bxp-cli's contract:
    //   0 = OK, 1 = error, 2 = warnings. Exit 2 already painted orange but
    //   used to say "done - ERR" — the text and color disagreed. Distinct
    //   text per band keeps the status bar legible without forcing the user
    //   to read the color to know which kind of "done" it was.
    final String runStatusText;
    final Color runStatusColor;
    switch (store.status) {
      case RunStatus.idle:
        runStatusText = 'idle';
        runStatusColor = t.textMuted;
        break;
      case RunStatus.running:
        runStatusText = 'running';
        runStatusColor = t.warnText;
        break;
      case RunStatus.done:
        final ec = store.lastExitCode ?? 0;
        if (ec == 0) {
          runStatusText = 'done - OK';
          runStatusColor = t.okText;
        } else if (ec == 2) {
          runStatusText = 'done - WARN';
          runStatusColor = t.warnText;
        } else {
          runStatusText = 'done - ERR';
          runStatusColor = t.errorText;
        }
        break;
      case RunStatus.error:
        runStatusText = 'error';
        runStatusColor = t.errorText;
        break;
    }

    void toggleStderr() {
      if (store.diagnosticBlob.isEmpty) return;
      setState(() => _stderrExpanded = !_stderrExpanded);
    }

    // Status-bar aggregates (input rows / output rows / errors / warnings /
    // stderr badge) live-update via `traceLinesCounter`. The notifier ticks
    // ~10 Hz during a stream, so these small Text cells refresh smoothly
    // without pulling the heavy widgets (RowList / FileList) along —
    // they're outside this VLB and stay quiet until the main notify on
    // first file_end / done.
    return ValueListenableBuilder<int>(
      valueListenable: store.traceLinesCounter,
      builder: (context, _, _) {
        int inputRows = 0;
        int outputRows = 0;
        int errors = 0;
        int warnings = 0;
        if (model != null) {
          for (final id in model.fileOrder) {
            final f = model.files[id];
            if (f == null) continue;
            // Authoritative source-row count lands at file_end; during the
            // stream we approximate with rowIds.length (= number of bin
            // row-level frames received so far). For 1:N templates the
            // running approximation may exceed source rows briefly, then
            // snaps to the exact figure when file_end arrives.
            final stats = f.stats;
            inputRows += (stats?['rows'] as int?) ?? f.rowIds.length;
            if (stats != null) {
              outputRows += (stats['written'] as int? ?? 0);
              // bxp-cli severity: `file_end.errors` carries the count of
              // input_schema expression failures, which bxp-cli itself
              // routes through `stats.warnings` (exit code 2, "warning:
              // N input_schema expression error(s)" stderr text). To
              // honour that 1:1 we sum it into the GUI warnings counter
              // alongside the dedicated `file_end.warnings` (other
              // per-file warnings — date filter no-range, malformed
              // range, ...). The GUI's `errors` counter stays reserved
              // for process-level fatals surfaced via the stderr badge.
              warnings += (stats['warnings'] as int? ?? 0) +
                  (stats['errors'] as int? ?? 0);
            }
          }
        }
        final parseIssues = model?.issues.length ?? 0;

        // Single source of truth for "is there anything wrong?": the
        // combined diagnostic blob (config error, save error, the bridge
        // first trace, runtime stderr). One clickable `stderr (NB)`
        // badge replaces the three inline labels we used to render
        // (the bridge: …, config: …, save: …). Same UX as the runner panel.
        final diagBlob = store.diagnosticBlob;
        final showErrRow = diagBlob.isNotEmpty;

        return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Expanded diagnostic panel lives ABOVE the err-msg badge in the
        // column flow (instead of as a Stack overlay) so the badge row
        // stays visible and clickable while the panel is open — that's
        // the user's only way to dismiss the panel.
        if (_stderrExpanded && diagBlob.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height *
                  LayoutDefaults.stderrPanelMaxHeightFrac,
            ),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: t.surfaceBg,
                border: Border(
                  top: BorderSide(color: borderColor),
                  left: BorderSide(color: t.errorBorder),
                  right: BorderSide(color: t.errorBorder),
                ),
              ),
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                child: SelectableText(
                  diagBlob,
                  style: BxpText.body(context,
                      color: t.errorText, size: BxpSize.sm),
                ),
              ),
            ),
          ),
        if (showErrRow)
          MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: toggleStderr,
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: bg,
                      border: Border(top: BorderSide(color: borderColor)),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 3),
                    // Single clickable label. Same UX as the runner panel:
                    // a count badge that hides the actual text behind one
                    // click. Replaces the older trio (the bridge: …, config:
                    // …, save: …) that showed the same content inline.
                    child: Text(
                      'stderr (${diagBlob.length}B)',
                      style: BxpText.body(context,
                          color: t.warnText, size: BxpSize.sm),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border(top: BorderSide(color: borderColor)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          height: 36,
          child: Row(
            children: [
              // Config status: IDLE / LOADED / ERROR
              Text(configStatusText,
                  style: BxpText.status(context, color: configStatusColor)),
              if (store.configPath.isNotEmpty) ...[
                const SizedBox(width: 8),
                // Click target spans icon + full file path so the user
                // doesn't have to aim at the 13 px icon to open the
                // config in the host's default editor.
                Flexible(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => store.openInEditor(store.configPath),
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.description_outlined,
                              size: 13, color: t.textMuted),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              store.configPath,
                              style: BxpText.body(context,
                                  color: t.textSubtle, size: BxpSize.sm),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 16),
              // Run status: idle / running / done - exit N / error
              Text(runStatusText,
                  style: BxpText.body(context,
                      color: runStatusColor, size: BxpSize.sm)),
              if (store.status == RunStatus.running) ...[
                const SizedBox(width: 6),
                _BrailleSpinner(color: runStatusColor),
              ],
              if (store.lastRunDuration != null) ...[
                const SizedBox(width: 12),
                _StatCell(
                    label: 'last run',
                    value: _formatRunDuration(store.lastRunDuration!)),
              ],
              const SizedBox(width: 16),
              ValueListenableBuilder<int>(
                valueListenable: store.tracesBytesCounter,
                builder: (_, v, _) =>
                    _StatCell(label: 'traces', value: _formatTraces(v)),
              ),
              const SizedBox(width: 12),
              _StatCell(label: 'input rows', value: '$inputRows'),
              const SizedBox(width: 12),
              _OutputStatCell(
                  outputs: outputRows, errors: errors, warnings: warnings),
              if (parseIssues > 0) ...[
                const SizedBox(width: 12),
                Text('parse issues: $parseIssues',
                    style: BxpText.body(context,
                        color: t.errorText, size: BxpSize.sm)),
              ],
              // `runError` (rpc: …) intentionally NOT rendered here. The
              // run status word above (`done - ERR` / `error`) flags that
              // something failed; the clickable `stderr (NB)` badge below
              // surfaces the actual diagnostic on click.
              const Spacer(),
              if (autoApprove)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(color: t.errorBorder),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'devel-auto-approve-mode',
                    style: BxpText.body(context,
                        color: t.errorText, size: BxpSize.xs),
                    maxLines: 1,
                  ),
                ),
            ],
          ),
        ),
      ],
        );
      },
    );
  }
}

/// Human-readable run duration with a unit chosen by magnitude:
///   < 1 s   → whole milliseconds   ("847 ms")
///   < 60 s  → seconds, 1 decimal   ("3.4 s")
///   ≥ 60 s  → minutes + seconds    ("2 m 05 s")
String _formatRunDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '$ms ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)} s';
  final m = d.inMinutes;
  final s = d.inSeconds - m * 60;
  return '$m m ${s.toString().padLeft(2, '0')} s';
}

/// Format raw bytes received from bxp-cli stdout into a tier display:
/// `N B` while under ~1 MB, `N KB` until ~1 GB, then `N MB`, `N GB`,
/// `N TB`. Decimal thresholds for tier switches (more predictable) but
/// binary division (1024-based) for the integer shown — matches what
/// file managers display.
String _formatTraces(int b) {
  if (b < 1000000) return '$b B';
  if (b < 1000000000) return '${b ~/ 1024} KB';
  if (b < 1000000000000) return '${b ~/ (1024 * 1024)} MB';
  if (b < 1000000000000000) return '${b ~/ (1024 * 1024 * 1024)} GB';
  return '${b ~/ (1024 * 1024 * 1024 * 1024)} TB';
}

class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  const _StatCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final base = BxpText.body(context, color: t.textMuted, size: BxpSize.sm);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: '$label: '),
          TextSpan(
              text: value,
              style: TextStyle(
                  color: t.textSubtle, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _OutputStatCell extends StatelessWidget {
  final int outputs;
  final int errors;
  final int warnings;
  const _OutputStatCell(
      {required this.outputs, required this.errors, required this.warnings});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final base = BxpText.body(context, color: t.textMuted, size: BxpSize.sm);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          const TextSpan(text: 'output rows: '),
          TextSpan(
              text: '$outputs',
              style: TextStyle(
                  color: t.textSubtle, fontWeight: FontWeight.bold)),
          if (errors > 0)
            TextSpan(
                text: ' · errors: $errors',
                style: TextStyle(
                    color: t.errorText, fontWeight: FontWeight.bold)),
          if (warnings > 0)
            TextSpan(
                text: ' · warnings: $warnings',
                style: TextStyle(
                    color: t.warnText, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}


class _BrailleSpinner extends StatefulWidget {
  final Color color;
  const _BrailleSpinner({required this.color});

  @override
  State<_BrailleSpinner> createState() => _BrailleSpinnerState();
}

class _BrailleSpinnerState extends State<_BrailleSpinner>
    with SingleTickerProviderStateMixin {
  static const _frames = [
    "⠋", "⠙", "⠹", "⠸", "⠼",
    "⠴", "⠦", "⠧", "⠇", "⠏",
  ];
  late final Ticker _ticker;
  int _frame = 0;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (elapsed - _last < const Duration(milliseconds: 100)) return;
      _last = elapsed;
      setState(() => _frame = (_frame + 1) % _frames.length);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _frames[_frame],
      style: BxpText.body(context, color: widget.color, size: BxpSize.sm),
    );
  }
}
