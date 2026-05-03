import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/dev_trace.dart';
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
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrl = keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
    if (!ctrl) return false;
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
    }
    return false;
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
                      children: const [ConfigView(), DebugPanes()],
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

    final bg = t.panelBg;
    final borderColor = t.borderColor;

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
      if (store.stderrText.isEmpty) return;
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
            inputRows += f.rowIds.length;
            final stats = f.stats;
            if (stats != null) {
              outputRows += (stats['written'] as int? ?? 0);
              errors += (stats['errors'] as int? ?? 0);
              warnings += (stats['warnings'] as int? ?? 0);
            }
          }
        }
        final parseIssues = model?.issues.length ?? 0;

        final firstErr = store.firstConfigErrorTrace;
        final hasConfigError = store.configError != null ||
            store.configSaveError != null ||
            firstErr != null;
        final hasStderr = store.stderrText.isNotEmpty;
        final showErrRow = hasConfigError || hasStderr;
        final stderrSuffix = hasStderr
            ? '  ›  stderr (${store.stderrText.length}B)'
            : '';

        return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Expanded stderr lives ABOVE the err-msg row in the column flow
        // (instead of as a Stack overlay) so the err-msg row stays
        // visible and clickable while the panel is open — that's the
        // user's only way to dismiss the panel.
        if (_stderrExpanded && store.stderrText.isNotEmpty)
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
                  store.stderrText,
                  style: BxpText.body(context,
                      color: t.errorText, size: BxpSize.sm),
                ),
              ),
            ),
          ),
        if (showErrRow)
          MouseRegion(
                cursor: hasStderr
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (firstErr != null)
                          Text(
                            'bxp-fmt: $firstErr$stderrSuffix',
                            style: BxpText.body(context,
                                color: t.warnText, size: BxpSize.sm),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (store.configError != null)
                          Text(
                            firstErr == null
                                ? '${store.configError!}$stderrSuffix'
                                : store.configError!,
                            style: BxpText.body(context,
                                color: t.errorText, size: BxpSize.sm),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (store.configSaveError != null)
                          Text(
                            firstErr == null && store.configError == null
                                ? 'save: ${store.configSaveError!}$stderrSuffix'
                                : 'save: ${store.configSaveError!}',
                            style: BxpText.body(context,
                                color: t.errorText, size: BxpSize.sm),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (!hasConfigError && hasStderr)
                          Text(
                            'stderr (${store.stderrText.length}B)',
                            style: BxpText.body(context,
                                color: t.warnText, size: BxpSize.sm),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
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
                // File icon: open the config in the host's default editor.
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => store.openInEditor(store.configPath),
                    child: Icon(Icons.description_outlined,
                        size: 13, color: t.textMuted),
                  ),
                ),
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
              const SizedBox(width: 16),
              // Run status: idle / running / done - exit N / error
              Text(runStatusText,
                  style: BxpText.body(context,
                      color: runStatusColor, size: BxpSize.sm)),
              if (store.status == RunStatus.running) ...[
                const SizedBox(width: 6),
                _BrailleSpinner(color: runStatusColor),
              ],
              const SizedBox(width: 16),
              ValueListenableBuilder<int>(
                valueListenable: store.traceLinesCounter,
                builder: (_, v, _) => _StatCell(label: 'trace lines', value: '$v'),
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
              if (store.runError != null) ...[
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'rpc: ${store.runError}',
                    style: BxpText.body(context,
                        color: t.errorText, size: BxpSize.sm),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const Spacer(),
            ],
          ),
        ),
      ],
        );
      },
    );
  }
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
