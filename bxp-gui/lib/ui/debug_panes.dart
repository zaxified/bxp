import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../store/trace_store.dart';
import 'components/file_list.dart';
import 'components/row_list.dart';
import 'components/row_detail.dart';
import 'components/output_panel.dart';
import 'components/panel_header.dart';
import 'components/resize_handle.dart';
import 'layout_defaults.dart';
import 'theme/bxp_theme.dart';
import 'theme/bxp_text.dart';

class DebugPanes extends StatefulWidget {
  const DebugPanes({super.key});

  @override
  State<DebugPanes> createState() => _DebugPanesState();
}

class _DebugPanesState extends State<DebugPanes> {
  double _leftFrac = LayoutDefaults.filesDetailsLeft.defaultFrac;
  double _rowsInFrac = LayoutDefaults.rowsIn.defaultFrac;
  double _rowsOutFrac = LayoutDefaults.rowsOut.defaultFrac;

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
            child: LayoutBuilder(builder: (ctx, outer) {
              final totalW = outer.maxWidth;
              const leftCfg = LayoutDefaults.filesDetailsLeft;
              final leftWidth = totalW * leftCfg.clamp(_leftFrac);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                // Left: File list
                SizedBox(
                  width: leftWidth,
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
                    _leftFrac = leftCfg.clamp(_leftFrac + dx / totalW);
                  }),
                ),
                // Right: RowList + RowDetail + OutputPanel (3-row stack)
                Expanded(
                  child: LayoutBuilder(builder: (ctx, constraints) {
                    final totalH = constraints.maxHeight;
                    const inCfg = LayoutDefaults.rowsIn;
                    const midCfg = LayoutDefaults.rowsMid;
                    const outCfg = LayoutDefaults.rowsOut;

                    // Derive middle from the two side fractions and
                    // re-clamp the sides so middle stays in its band.
                    // When sides hit their max simultaneously middle is
                    // forced above its own min — that's intentional.
                    double inFrac = inCfg.clamp(_rowsInFrac);
                    double outFrac = outCfg.clamp(_rowsOutFrac);
                    double midFrac = 1.0 - inFrac - outFrac;
                    if (midFrac < midCfg.minFrac) {
                      final excess = midCfg.minFrac - midFrac;
                      final inSlack = inFrac - inCfg.minFrac;
                      final outSlack = outFrac - outCfg.minFrac;
                      final total = inSlack + outSlack;
                      if (total > 0) {
                        inFrac -= excess * (inSlack / total);
                        outFrac -= excess * (outSlack / total);
                      }
                      midFrac = 1.0 - inFrac - outFrac;
                    } else if (midFrac > midCfg.maxFrac) {
                      final deficit = midFrac - midCfg.maxFrac;
                      final inRoom = inCfg.maxFrac - inFrac;
                      final outRoom = outCfg.maxFrac - outFrac;
                      final total = inRoom + outRoom;
                      if (total > 0) {
                        inFrac += deficit * (inRoom / total);
                        outFrac += deficit * (outRoom / total);
                      }
                      midFrac = 1.0 - inFrac - outFrac;
                    }

                    final rowsInH = totalH * inFrac;
                    final outputH = totalH * outFrac;
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
                        // Horizontal splitter (RowList / RowDetail).
                        // Dragging adjusts rows-in only; middle absorbs
                        // the delta unless it hits its own band, in
                        // which case the clamp pins rows-in.
                        ResizeHandle(
                          axis: Axis.vertical,
                          onDelta: (dy) => setState(() {
                            final delta = dy / totalH;
                            final maxIn = math.min(
                                inCfg.maxFrac, 1.0 - outFrac - midCfg.minFrac);
                            final minIn = math.max(
                                inCfg.minFrac, 1.0 - outFrac - midCfg.maxFrac);
                            _rowsInFrac =
                                (inFrac + delta).clamp(minIn, maxIn);
                          }),
                        ),
                        const Expanded(child: RowDetail()),
                        // Horizontal splitter (RowDetail / OutputPanel)
                        // — dy inverted (drag up = bigger output pane).
                        ResizeHandle(
                          axis: Axis.vertical,
                          onDelta: (dy) => setState(() {
                            final delta = -dy / totalH;
                            final maxOut = math.min(
                                outCfg.maxFrac, 1.0 - inFrac - midCfg.minFrac);
                            final minOut = math.max(
                                outCfg.minFrac, 1.0 - inFrac - midCfg.maxFrac);
                            _rowsOutFrac =
                                (outFrac + delta).clamp(minOut, maxOut);
                          }),
                        ),
                        SizedBox(height: outputH, child: const OutputPanel()),
                      ],
                    );
                  }),
                ),
              ],
              );
            }),
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

class _TemplateSelect extends StatefulWidget {
  final TraceStore store;
  const _TemplateSelect({required this.store});

  @override
  State<_TemplateSelect> createState() => _TemplateSelectState();
}

class _TemplateSelectState extends State<_TemplateSelect> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final t = context.bxpTheme;
    final label =
        store.templateId.isEmpty ? 'all templates' : store.templateId;
    // Pre-compute item styles in build phase — BxpText calls context.watch
    // internally, which is only valid during a build, not inside callbacks.
    final varStyle =
        BxpText.body(context, color: t.codeVariable, size: BxpSize.sm);
    final allStyle = BxpText.body(context,
        color: t.textMuted, fontStyle: FontStyle.italic, size: BxpSize.sm);
    final subtitleStyle = BxpText.body(context,
        color: t.textMuted, size: BxpSize.xs, fontStyle: FontStyle.italic);
    // Build {id -> TemplateInfo} from the rich --list-templates result so
    // we can render data_dir + file_pattern as a subtitle. Fall back to
    // bare ids when the lookup is empty (CLI missing, old bxp-fmt, etc.).
    final infos = {
      for (final ti in store.availableTemplateInfos) ti.id: ti,
    };
    final ids = store.availableTemplates;
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
        ...ids.map((id) {
          final info = infos[id];
          final subtitle = info == null
              ? null
              : (info.description?.isNotEmpty == true
                  ? info.description!
                  : [info.dataDir, info.filePatternIn]
                      .where((s) => s != null && s.isNotEmpty)
                      .join(' · '));
          return PopupMenuItem<String>(
            value: id,
            // Two-line entry when subtitle exists, single-line otherwise.
            height: subtitle != null && subtitle.isNotEmpty ? 40 : 28,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(id, style: varStyle),
                if (subtitle != null && subtitle.isNotEmpty)
                  Text(subtitle, style: subtitleStyle),
              ],
            ),
          );
        }),
      ],
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _hovered ? t.withHover(t.panelBg) : t.panelBg,
            border: Border.all(
                color: _hovered ? t.accentHighlight : t.borderColor),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: BxpText.body(context,
                      color: t.codeVariable, size: BxpSize.sm)),
              const SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_down,
                  color: _hovered ? t.accentHighlight : t.textMuted,
                  size: 14),
            ],
          ),
        ),
      ),
    );
  }
}
