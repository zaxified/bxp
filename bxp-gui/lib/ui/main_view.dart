import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../store/trace_store.dart';
import 'debug_panes.dart';
import 'config_view.dart';
import 'components/top_bar.dart';
import 'components/open_dialog.dart';
import 'theme/bxp_theme.dart';
import 'theme/bxp_text.dart';
import 'theme/theme_inspector.dart';

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

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final activeTab = store.activeTabIndex;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            store.saveConfig(),
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
            store.undo(),
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): () =>
            store.redo(),
        SingleActivator(LogicalKeyboardKey.keyO, control: true): () {
          OpenDialog.show(context, (path) async {
            store.setConfigPath(path);
            await store.loadConfig();
          });
        },
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): () {
          if (store.configPath.isNotEmpty) store.loadConfig();
        },
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): () {
          // Discard unsaved edits, snap back to baseline (no disk re-read).
          if (store.configPath.isNotEmpty) store.resetDraft();
        },
        const SingleActivator(LogicalKeyboardKey.keyT,
            control: true, shift: true): () {
          setState(() => _inspectorOpen = !_inspectorOpen);
        },
      },
      child: Focus(
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
            ],
          ),
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
    } else if (store.configJson != null) {
      configStatusText = 'LOADED';
      configStatusColor = t.okText;
    } else {
      configStatusText = 'IDLE';
      configStatusColor = t.textMuted;
    }

    // Run status label + color.
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
        runStatusText = 'done - exit $ec';
        if (ec == 0) {
          runStatusColor = t.okText;
        } else if (ec == 2) {
          runStatusColor = t.warnText;
        } else {
          runStatusColor = t.errorText;
        }
        break;
      case RunStatus.error:
        runStatusText = 'error';
        runStatusColor = t.errorText;
        break;
    }

    // Aggregate stats.
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

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasConfigError)
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: bg,
                  border: Border(top: BorderSide(color: borderColor)),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (firstErr != null)
                      Text(
                        'bxp-fmt: $firstErr',
                        style: BxpText.body(context,
                            color: t.warnText, size: BxpSize.sm),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (store.configError != null)
                      Text(
                        store.configError!,
                        style: BxpText.body(context,
                            color: t.errorText, size: BxpSize.sm),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (store.configSaveError != null)
                      Text(
                        'save: ${store.configSaveError!}',
                        style: BxpText.body(context,
                            color: t.errorText, size: BxpSize.sm),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
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
              const SizedBox(width: 16),
              _StatCell(label: 'trace lines', value: '${store.rawLines}'),
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
              if (store.stderrText.isNotEmpty)
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _stderrExpanded = !_stderrExpanded),
                    child: Text(
                      'stderr (${store.stderrText.length}B)',
                      style: BxpText.body(context,
                          color: t.errorText,
                          size: BxpSize.sm,
                          decoration: TextDecoration.underline),
                    ),
                  ),
                ),
            ],
          ),
        ),
          ],
        ),
        if (_stderrExpanded && store.stderrText.isNotEmpty)
          Positioned(
            right: 12,
            bottom: 32,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640, maxHeight: 400),
              child: Container(
                decoration: BoxDecoration(
                  color: t.surfaceBg,
                  border: Border.all(color: t.errorBorder),
                  boxShadow: [
                    BoxShadow(color: t.dialogShadow, blurRadius: 8),
                  ],
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
          ),
      ],
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
