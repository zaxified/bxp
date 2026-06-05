import 'package:flutter/material.dart';
import 'package:json5_ast/ast.dart';
import 'package:provider/provider.dart';
import '../store/trace_store.dart';
import 'components/json_tree.dart';
import 'components/expr_panel.dart';
import 'components/open_dialog.dart';
import 'components/resize_handle.dart';
import 'layout_defaults.dart';
import 'platform_shortcuts.dart';
import 'theme/bxp_theme.dart';
import 'theme/bxp_text.dart';

class ConfigView extends StatefulWidget {
  const ConfigView({super.key});

  @override
  State<ConfigView> createState() => _ConfigViewState();
}

class _ConfigViewState extends State<ConfigView> {
  double leftFrac = LayoutDefaults.treeExprLeft.defaultFrac;

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
                // — editing buttons go inert so the user can't pile changes
                // on top of a broken file; only Open/Reload stay live so
                // they can recover by editing externally and re-loading.
                ...() {
                  // Latch readonly to load-time errors only. Live $err_*
                  // introduced by an edit must NOT lock undo/redo/save —
                  // the user needs those to fix the mistake. saveConfig
                  // does its own pre-flight scan and refuses to write a
                  // broken file.
                  final readOnly = store.configLoadHadErrors;
                  final mod = commandModifierLabel;
                  return [
                    _ToolbarBtn(
                      title: 'OPEN',
                      tooltip: 'Open config file ($mod+O)',
                      onTap: () => OpenDialog.show(context, (path) async {
                        store.setConfigPath(path);
                        await store.loadConfig();
                      }),
                    ),
                    _ToolbarBtn(
                      title: 'RELOAD',
                      tooltip: 'Reload from disk ($mod+R)',
                      disabled: store.configPath.isEmpty,
                      onTap: () => store.loadConfig(),
                    ),
                    _ToolbarBtn(
                        title: 'RESET',
                        tooltip: 'Discard all unsaved changes ($mod+T)',
                        disabled: readOnly || !store.isDirty,
                        onTap: () => store.resetDraft()),
                    _ToolbarBtn(
                        title: 'UNDO',
                        tooltip: 'Undo ($mod+Z)',
                        disabled: readOnly || !store.canUndo,
                        onTap: () => store.undo()),
                    _ToolbarBtn(
                        title: 'REDO',
                        tooltip: 'Redo ($mod+Y)',
                        disabled: readOnly || !store.canRedo,
                        onTap: () => store.redo()),
                    _ToolbarBtn(
                        title: store.isValidating ? 'VALIDATING…' : 'VALIDATE',
                        tooltip:
                            'Run bxp-fmt --config --check-fs=2 ($mod+E)',
                        disabled: store.configPath.isEmpty ||
                            store.astRoot == null ||
                            store.isValidating ||
                            store.isSaving ||
                            store.isLoadingConfig,
                        onTap: () => store.runValidate()),
                    _ToolbarBtn(
                      // "SAVING…" label surfaces the in-flight save round-trip.
                      // The re-entrancy guard in saveConfig() handles
                      // double-click; we still disable the button so
                      // the affordance matches the no-op behaviour.
                      title: store.isSaving ? 'SAVING…' : 'SAVE',
                      tooltip: store.configHasErrors
                          ? 'Cannot save while config has syntax errors'
                          : 'Save config to disk ($mod+S)',
                      disabled: readOnly ||
                          !store.isDirty ||
                          store.isSaving ||
                          store.configHasErrors,
                      onTap: () => store.saveConfig(),
                    ),
                  ];
                }(),
                const SizedBox(width: 8),
                if (store.configLoadHadErrors)
                  Text('● read-only (syntax errors)',
                      style: BxpText.label(context, color: t.errorText))
                else if (store.isDirty && store.configError == null)
                  Text('● modified',
                      style: BxpText.label(context, color: t.warnText))
                else if (store.configError != null)
                  Text('● load error',
                      style: BxpText.label(context, color: t.errorText)),
                // Phase 5b — VALIDATE button result toast. Transient
                // (auto-clears after `_validateToastMs` = 8s in the
                // store). Coloured by semantic meaning: green when clean,
                // warn-yellow when any non-error diagnostic, red when any
                // error.
                if (store.validateToast != null) ...[
                  const SizedBox(width: 12),
                  Builder(builder: (ctx) {
                    final msg = store.validateToast!;
                    final isOk = msg == 'Validation OK';
                    final hasErr = msg.contains('error');
                    final color = isOk
                        ? t.okText
                        : (hasErr ? t.errorText : t.warnText);
                    return Text('● $msg',
                        style: BxpText.label(context, color: color));
                  }),
                ],
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
            child: LayoutBuilder(
              builder: (ctx, c) {
                final totalW = c.maxWidth;
                const cfg = LayoutDefaults.treeExprLeft;
                final leftWidth = totalW * cfg.clamp(leftFrac);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                // Left Pane: ConfigTree. Three exclusive states ordered
                // by priority: AST tree present → render (even when
                // configError is set, so the user can still browse a
                // partially-parsed file); spawn in flight → "Loading…"
                // placeholder; error without partial JSON → red error
                // banner; nothing loaded yet → empty-state hint.
                SizedBox(
                  width: leftWidth,
                  child: store.astRoot != null
                    ? _ConfigTreeScroll(root: store.astRoot)
                    : store.isLoadingConfig
                      ? Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text('Loading…',
                              style: BxpText.italic(context)),
                        )
                      : store.configError != null
                        ? Padding(
                            // Error text intentionally NOT rendered inline
                            // here. The clickable `stderr (NB)` badge in
                            // the bottom status bar surfaces every
                            // diagnostic source (configError, save error,
                            // bxp-fmt $err_*, runtime stderr) on click.
                            // Keep this branch only to suppress the empty
                            // hint below — config IS in error, not "no
                            // file loaded".
                            padding: const EdgeInsets.all(16.0),
                            child: Text(
                              '● load failed — see stderr badge',
                              style: BxpText.italic(context, color: t.errorText),
                            ),
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
                    leftFrac = cfg.clamp(leftFrac + dx / totalW);
                  }),
                ),

                // Right Pane: ExprPanel
                const Expanded(child: ExprPanel()),
              ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

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

/// Tree pane with persistent horizontal + vertical scrollbars. Holds its
/// own ScrollControllers so the Scrollbar widgets have stable thumbs;
/// without explicit controllers a single SingleChildScrollView with
/// `Axis.horizontal` nested inside a vertical one prevents the
/// Scrollbar from latching onto either axis cleanly.
class _ConfigTreeScroll extends StatefulWidget {
  final JsonAstNode? root;
  const _ConfigTreeScroll({required this.root});

  @override
  State<_ConfigTreeScroll> createState() => _ConfigTreeScrollState();
}

class _ConfigTreeScrollState extends State<_ConfigTreeScroll> {
  final _vCtrl = ScrollController();
  final _hCtrl = ScrollController();
  /// Drives the sticky row-action overlay anchored to the tree pane's
  /// right edge. Hovered rows publish their `trailingActions` + Y
  /// offset here; a single `Positioned` listens and paints the toolbox
  /// over the horizontally-scrollable row content underneath.
  final TreeActionsController _actionsCtrl = TreeActionsController();
  /// `RenderObject` anchor for `_RowEnvelope.localToGlobal` — must be
  /// the same `Stack` that owns the overlay so per-row Y coordinates
  /// land in the overlay's coord space without scroll-offset drift.
  final GlobalKey _stackKey = GlobalKey();

  @override
  void dispose() {
    _vCtrl.dispose();
    _hCtrl.dispose();
    _actionsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Save flow is async: write tmp → bxp-fmt validate → backup → rename →
    // post-save loadConfig. Anywhere from a few hundred ms to a second.
    // Edits made during that window race the final loadConfig, which
    // discards `_opLog` — the user's mid-flight changes silently
    // disappear. Cheapest fix: lock the tree (and visually grey it) so
    // the race window simply isn't reachable from the UI.
    final isSaving = context.select<TraceStore, bool>((s) => s.isSaving);
    return IgnorePointer(
      ignoring: isSaving,
      child: Opacity(
        opacity: isSaving ? 0.55 : 1.0,
        child: _buildTree(context),
      ),
    );
  }

  Widget _buildTree(BuildContext context) {
    return Padding(
      // Non-scrolling top + right gutter so the hover background of the
      // topmost / rightmost visible row can never sit flush against the
      // toolbar's bottom border or the vertical splitter (read as
      // "hover leaks into the menu / expr-panel").
      padding: const EdgeInsets.only(top: 6, right: 6),
      child: TreeActionsBinding(
        controller: _actionsCtrl,
        stackKey: _stackKey,
        child: Scrollbar(
          controller: _vCtrl,
          thumbVisibility: true,
          child: Scrollbar(
            controller: _hCtrl,
            thumbVisibility: true,
            notificationPredicate: (n) => n.depth == 1,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Each tree row stretches its min-width to the viewport
                // so the sticky action toolbox right-aligns against the
                // same X near the scrollbar regardless of the row's own
                // intrinsic content length. 16+16 accounts for the
                // SingleChildScrollView padding plus the vertical
                // scrollbar's thumb area.
                final viewportRowWidth = constraints.maxWidth - 32;
                return SingleChildScrollView(
                  controller: _vCtrl,
                  padding: const EdgeInsets.all(16.0),
                  // Stack hosts the row content (scrollable horizontally
                  // via the inner SingleChildScrollView) and a single
                  // overlay `Positioned` that paints the hovered row's
                  // action toolbox pinned to the right edge. The Stack
                  // sits INSIDE the vertical SCV so its coord space
                  // scrolls with the content — per-row Y stays stable
                  // and the overlay tracks the row through vertical
                  // scroll without listening to scroll events.
                  child: Stack(
                    key: _stackKey,
                    children: [
                      SingleChildScrollView(
                        controller: _hCtrl,
                        scrollDirection: Axis.horizontal,
                        child: JsonTree(
                          key: ValueKey(context.select<TraceStore, int>(
                              (s) => s.treeLoadGen)),
                          root: widget.root,
                          expandAll: false,
                          rowMinWidth:
                              viewportRowWidth > 0 ? viewportRowWidth : null,
                        ),
                      ),
                      _TreeActionsOverlay(controller: _actionsCtrl),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Listens to the per-tree [TreeActionsController] and paints the
/// currently-published row action toolbox at `right: 0` of its parent
/// `Stack`, vertically aligned to the row's `y` (in Stack coord space).
/// Returns a zero-sized placeholder when nothing is published so the
/// Stack's non-positioned sibling alone determines its size.
class _TreeActionsOverlay extends StatelessWidget {
  final TreeActionsController controller;
  const _TreeActionsOverlay({required this.controller});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (ctx, _) {
        final y = controller.y;
        final actions = controller.actions;
        if (y == null || actions == null) {
          return const SizedBox.shrink();
        }
        // `y` is already row-top compensated in `_RowEnvelopeState`
        // (`_rowPaddingTopCompensation`) so the overlay aligns with the
        // hover-rect top, not the text baseline — no extra Padding here.
        // Opaque elevated "card" — distinct from the tree's
        // `surfaceBg` background so the toolbox reads as a floating
        // overlay rather than blending into the row content underneath.
        // Accent-tinted border + soft drop shadow reinforce the
        // elevation; full alpha on the fill masks any long-row glyphs
        // behind the icons.
        return Positioned(
          top: y,
          right: 0,
          // `opaque: false` lets pointer hit-testing fall through to the
          // row's own MouseRegion underneath, so the row stays "entered"
          // while the cursor is over the toolbox. Without it the
          // opaque-by-default Stack overlay absorbs the hit, the row
          // fires onExit → clear → toolbox vanishes → cursor lands back
          // on the row → onEnter → publish → toolbox reappears, in a
          // tight flicker loop. The InkWells inside still register
          // their own hover/tap normally — they're descendants, not
          // siblings in the Stack hit-test.
          child: MouseRegion(
            opaque: false,
            child: Container(
              decoration: BoxDecoration(
                color: t.panelBg,
                border: Border.all(
                    color: t.accentHighlight.withValues(alpha: 0.55)),
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              child: actions,
            ),
          ),
        );
      },
    );
  }
}
