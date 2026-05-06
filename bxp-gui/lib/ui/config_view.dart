import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../store/trace_store.dart';
import 'components/json_tree.dart';
import 'components/expr_panel.dart';
import 'components/open_dialog.dart';
import 'components/resize_handle.dart';
import 'theme/bxp_theme.dart';
import 'theme/bxp_text.dart';

class ConfigView extends StatefulWidget {
  const ConfigView({super.key});

  @override
  State<ConfigView> createState() => _ConfigViewState();
}

class _ConfigViewState extends State<ConfigView> {
  double leftWidth = 400;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final t = context.bxpTheme;
    final dividerColor = t.borderColor;
    final bgColor = t.surfaceBg;
    final navColor = t.panelBg.withValues(alpha: 0.4);

    return Material(
      color: bgColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: navColor,
              border: Border(bottom: BorderSide(color: dividerColor)),
            ),
            child: Row(
              children: [
                // When the loaded config contains `$err_*` diagnostic
                // markers, bxp-fmt could parse it but treats it as broken
                // — same semantics as bxp-ui's `readOnly = configHasErrors`.
                // Editing buttons go inert so the user can't pile changes
                // on top of a broken file; only Open/Reload stay live so
                // they can recover by editing externally and re-loading.
                ...() {
                  final readOnly = store.configHasErrors;
                  return [
                    _ToolbarBtn(
                      title: 'OPEN',
                      tooltip: 'Open config file (Ctrl+O)',
                      onTap: () => OpenDialog.show(context, (path) async {
                        store.setConfigPath(path);
                        await store.loadConfig();
                      }),
                    ),
                    _ToolbarBtn(
                      title: 'RELOAD',
                      tooltip: 'Reload from disk (Ctrl+R)',
                      disabled: store.configPath.isEmpty,
                      onTap: () => store.loadConfig(),
                    ),
                    _ToolbarBtn(
                        title: 'RESET',
                        tooltip: 'Discard all unsaved changes (Ctrl+T)',
                        disabled: readOnly || !store.isDirty,
                        onTap: () => store.resetDraft()),
                    _ToolbarBtn(
                        title: 'UNDO',
                        tooltip: 'Undo (Ctrl+Z)',
                        disabled: readOnly || !store.canUndo,
                        onTap: () => store.undo()),
                    _ToolbarBtn(
                        title: 'REDO',
                        tooltip: 'Redo (Ctrl+Y)',
                        disabled: readOnly || !store.canRedo,
                        onTap: () => store.redo()),
                    _ToolbarBtn(
                      // "SAVING…" label mirrors bxp-ui's
                      // configSaveStatus === "saving" indicator. The
                      // re-entrancy guard in saveConfig() handles
                      // double-click; we still disable the button so
                      // the affordance matches the no-op behaviour.
                      title: store.isSaving ? 'SAVING…' : 'SAVE',
                      tooltip: 'Save config to disk (Ctrl+S)',
                      disabled: readOnly || !store.isDirty || store.isSaving,
                      onTap: () => store.saveConfig(),
                    ),
                  ];
                }(),
                const SizedBox(width: 8),
                if (store.configHasErrors)
                  Text('● read-only (syntax errors)',
                      style: BxpText.label(context, color: t.errorText))
                else if (store.isDirty && store.configError == null)
                  Text('● modified',
                      style: BxpText.label(context, color: t.warnText))
                else if (store.configError != null)
                  Text('● load error',
                      style: BxpText.label(context, color: t.errorText)),
                const Spacer(),
              ],
            ),
          ),
          // (The expression-path breadcrumb that used to render here was
          // a duplicate — the right-hand ExprPanel already shows the
          // same path inside its editor header. Keeping a second copy
          // under the toolbar wasted a row and made it look like the
          // path was a global state badge rather than a per-pane label.)
          // Split Content
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left Pane: ConfigTree. Three exclusive states ordered
                // by priority: configJson present → render tree (even
                // when configError is set, so the user can still browse
                // a partially-parsed file); spawn in flight → "Loading…"
                // placeholder (mirrors bxp-ui's configStatus="loading");
                // error without partial JSON → red error banner; nothing
                // loaded yet → empty-state hint.
                SizedBox(
                  width: leftWidth,
                  child: store.configJson != null
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(16.0),
                        child: JsonTree(json: store.configJson, expandAll: false),
                      )
                    : store.isLoadingConfig
                      ? Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text('Loading…',
                              style: BxpText.italic(context)),
                        )
                      : store.configError != null
                        ? Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Text('Error: ${store.configError}',
                                style: BxpText.body(context, color: t.errorText)),
                          )
                        : Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Text('Config not parsed.',
                                style: BxpText.italic(context)),
                          ),
                ),
                
                // Vertical Splitter (ConfigTree | ExprPanel)
                ResizeHandle(
                  axis: Axis.horizontal,
                  onDelta: (dx) => setState(() {
                    leftWidth = (leftWidth + dx).clamp(200.0, 1000.0);
                  }),
                ),
                
                // Right Pane: ExprPanel
                const Expanded(child: ExprPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// _Breadcrumb removed: the same path is now rendered exclusively in
// ExprPanel's editor header. The duplicate row under the toolbar gave
// the impression of a global selection state badge.

class _ToolbarBtn extends StatelessWidget {
  final String title;
  final String? tooltip;
  final bool disabled;
  final VoidCallback onTap;

  const _ToolbarBtn({
    required this.title,
    this.tooltip,
    this.disabled = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final btn = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(2),
        hoverColor: t.hoverOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            title,
            style: BxpText.label(context,
                color: disabled
                    ? t.textMuted.withValues(alpha: 0.5)
                    : t.textSubtle),
          ),
        ),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip!, child: btn);
  }
}
