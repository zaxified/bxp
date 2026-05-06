import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../store/trace_store.dart';
import 'components/file_list.dart';
import 'components/row_list.dart';
import 'components/row_detail.dart';
import 'components/output_panel.dart';
import 'components/panel_header.dart';
import 'components/resize_handle.dart';
import 'theme/bxp_theme.dart';
import 'theme/bxp_text.dart';

class DebugPanes extends StatefulWidget {
  const DebugPanes({super.key});

  @override
  State<DebugPanes> createState() => _DebugPanesState();
}

class _DebugPanesState extends State<DebugPanes> {
  double _leftWidth = 260;
  double _rowsInHeight = 210;
  double _outputHeight = 176;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final t = context.bxpTheme;
    final dividerColor = t.borderColor;
    final bgColor = t.surfaceBg;
    final toolbarBg = t.surfaceBg;

    final isRunning = store.status == RunStatus.running;
    final model = store.traceModel;
    final fileCount = model?.files.length ?? 0;

    return Container(
      decoration: BoxDecoration(color: bgColor),
      child: Column(
        children: [
          // ── Controls Bar ──────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: toolbarBg,
              border: Border(bottom: BorderSide(color: dividerColor)),
            ),
            child: Row(
              children: [
                // DRY RUN button — label flips to "running…" while a dry
                // run is in flight; mirrors bxp-ui's per-mode "running…"
                // state so the user can see which button they pressed.
                _RunBtn(
                  label: (isRunning && store.runMode == RunMode.dry)
                      ? 'running…'
                      : 'dry-run',
                  bgColor: t.okBg,
                  textColor: t.okText,
                  disabled: isRunning || store.configPath.isEmpty,
                  onTap: () => store.runDryRun(),
                ),
                const SizedBox(width: 8),
                // FULL RUN button — same per-mode "running…" treatment.
                _RunBtn(
                  label: (isRunning && store.runMode == RunMode.full)
                      ? 'running…'
                      : 'full-run',
                  bgColor: t.infoBg,
                  textColor: t.infoText,
                  disabled: isRunning || store.configPath.isEmpty,
                  onTap: () => store.runFullRun(),
                ),
            const SizedBox(width: 8),
            if (store.availableTemplates.isNotEmpty)
              _TemplateSelect(store: store),
            if (store.status == RunStatus.error && store.runError != null) ...[
              const SizedBox(width: 16),
              Flexible(
                child: Text('⚠ ${store.runError}',
                    style: BxpText.body(context,
                        color: t.errorText, size: BxpSize.sm),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
              ],
            ),
          ),

          // ── Main split pane ───────────────────────────────────────
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left: File list
                SizedBox(
                  width: _leftWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PanelHeader(
                        title: 'FILES',
                        count: fileCount,
                      ),
                      const Expanded(child: FileList()),
                    ],
                  ),
                ),
                // Vertical splitter (FileList | right column)
                ResizeHandle(
                  axis: Axis.horizontal,
                  onDelta: (dx) => setState(() {
                    _leftWidth = (_leftWidth + dx).clamp(140.0, 600.0);
                  }),
                ),
                // Right: RowList + RowDetail + OutputPanel (3-row stack)
                Expanded(
                  child: LayoutBuilder(builder: (ctx, constraints) {
                    final totalH = constraints.maxHeight;
                    // Clamp heights so middle (RowDetail) keeps >= 60 px.
                    final maxStackH = totalH - 60.0 - 8.0; // splitters = 8
                    final rowsInH = _rowsInHeight
                        .clamp(60.0, maxStackH > 60.0 ? maxStackH - 60.0 : 60.0);
                    final outputH = _outputHeight
                        .clamp(60.0, (maxStackH - rowsInH).clamp(60.0, 600.0));
                    final selectedFile = store.selectedFileId == null
                        ? null
                        : model?.files[store.selectedFileId];
                    final rowsInCount = selectedFile?.rowIds.length ?? 0;

                    return Column(
                      children: [
                        SizedBox(
                          height: rowsInH,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              PanelHeader(
                                title: 'ROWS IN',
                                count: rowsInCount,
                              ),
                              const Expanded(child: RowList()),
                            ],
                          ),
                        ),
                        // Horizontal splitter (RowList / RowDetail)
                        ResizeHandle(
                          axis: Axis.vertical,
                          onDelta: (dy) => setState(() {
                            _rowsInHeight =
                                (_rowsInHeight + dy).clamp(60.0, 500.0);
                          }),
                        ),
                        const Expanded(child: RowDetail()),
                        // Horizontal splitter (RowDetail / OutputPanel) —
                        // dy is inverted because the OutputPanel grows
                        // upward (drag up = bigger output pane).
                        ResizeHandle(
                          axis: Axis.vertical,
                          onDelta: (dy) => setState(() {
                            _outputHeight =
                                (_outputHeight - dy).clamp(60.0, 500.0);
                          }),
                        ),
                        SizedBox(height: outputH, child: const OutputPanel()),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RunBtn extends StatelessWidget {
  final String label;
  final Color bgColor;
  final Color textColor;
  final bool disabled;
  final VoidCallback onTap;

  const _RunBtn({
    required this.label,
    required this.bgColor,
    required this.textColor,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Material(
      color: disabled ? t.borderColor : bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
        side: BorderSide(
            color: disabled
                ? Colors.transparent
                : textColor.withValues(alpha: 0.3)),
      ),
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(2),
        hoverColor: t.hoverOverlay,
        highlightColor: t.activeOverlay,
        splashColor: t.activeOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            label.toLowerCase(),
            style: BxpText.body(context,
                color: disabled
                    ? t.textMuted.withValues(alpha: 0.5)
                    : textColor,
                weight: BxpWeight.semiBold,
                size: BxpSize.sm),
          ),
        ),
      ),
    );
  }
}

class _TemplateSelect extends StatelessWidget {
  final TraceStore store;
  const _TemplateSelect({required this.store});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final label =
        store.templateId.isEmpty ? 'all templates' : store.templateId;
    // Pre-compute item styles in build phase — BxpText calls context.watch
    // internally, which is only valid during a build, not inside callbacks.
    final varStyle =
        BxpText.body(context, color: t.codeVariable, size: BxpSize.sm);
    final allStyle = BxpText.body(context,
        color: t.textMuted, fontStyle: FontStyle.italic, size: BxpSize.sm);
    return PopupMenuButton<String>(
      position: PopupMenuPosition.under,
      color: t.panelBg,
      elevation: 2,
      padding: EdgeInsets.zero,
      onSelected: (val) => store.setTemplateId(val),
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          value: '',
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text('all templates', style: allStyle),
        ),
        ...store.availableTemplates.map((id) => PopupMenuItem<String>(
              value: id,
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(id, style: varStyle),
            )),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: t.panelBg,
          border: Border.all(color: t.borderColor),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: BxpText.body(context,
                    color: t.codeVariable, size: BxpSize.sm)),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down, color: t.textMuted, size: 14),
          ],
        ),
      ),
    );
  }
}
