import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../../store/trace_model.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import '../layout_defaults.dart';
import 'expr_highlight.dart';
import 'resize_handle.dart';

class RowDetail extends StatefulWidget {
  const RowDetail({super.key});

  @override
  State<RowDetail> createState() => _RowDetailState();
}

class _RowDetailState extends State<RowDetail> {
  double _leftFrac = LayoutDefaults.rowSelectedLeft.defaultFrac;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final model = store.traceModel;
    final rowId = store.selectedRowId;
    final fileId = store.selectedFileId;

    if (model == null || rowId == null || fileId == null) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Text('Select a row to inspect.', style: BxpText.italic(context)),
      );
    }

    final row = model.rows[rowId];
    final file = model.files[fileId];
    if (row == null || file == null) return const SizedBox.shrink();

    final t = context.bxpTheme;

    // Btrace mode: per-row drill-down detail (vars, rules, output values,
    // raw fields) is fetched lazily on first selection. Trigger the fetch
    // after the current build frame so we don't notifyListeners() while
    // building. The spinner branch below covers the loading state; once
    // detailLoaded flips true, the next watch() rebuild renders normally.
    if (model.fromBtrace && !row.detailLoaded && !row.detailLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        store.ensureDetailLoaded(rowId);
      });
    }
    if (model.fromBtrace && row.detailLoading) {
      return const Center(
        child: SizedBox(
          width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    // bxp-cli severity: var/rule eval failures are WARNINGS (the
    // `error` kind on VarEntry is a legacy field name). Banner copy +
    // colour reflect "warning" semantics.
    final warningCount = row.vars.where((v) => v.kind == 'error').length;
    // Prefer the per-frame detail captured during ingest (carries
    // errorKind + the bridge detail text). Falls back to the re-eval
    // VarEntry list above when ingest didn't see error_row frames.
    final ingestDetails = row.warningDetails;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Warning banner ──────────────────────────────────────────
        if (warningCount > 0 || ingestDetails.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: t.errorBg,
              border: Border(
                bottom: BorderSide(color: t.errorBorder),
                left: BorderSide(color: t.errorBorder, width: 2),
              ),
            ),
            child: Row(
              children: [
                Text('⚠', style: TextStyle(color: t.errorText, fontSize: 12)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ingestDetails.isNotEmpty
                        ? '${ingestDetails.length} variable '
                            '${ingestDetails.length == 1 ? "warning" : "warnings"} '
                            'in this row — ${ingestDetails.first}'
                        : '$warningCount variable '
                            '${warningCount == 1 ? "warning" : "warnings"} '
                            'in this row — see Variables below.',
                    style: BxpText.body(
                      context,
                      color: t.errorText,
                      size: BxpSize.sm,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // ── Main split: ROW SELECTED | ROW TRANSFORM ───────────────
        Expanded(
          child: LayoutBuilder(builder: (ctx, c) {
            final totalW = c.maxWidth;
            const cfg = LayoutDefaults.rowSelectedLeft;
            final leftWidth = totalW * cfg.clamp(_leftFrac);
            return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. ROW SELECTED
              SizedBox(
                width: leftWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _SectionHeader('ROW SELECTED'),
                    Expanded(
                      child: _FieldsTable(
                        headers: file.headers,
                        values: row.fields,
                      ),
                    ),
                  ],
                ),
              ),
              // Vertical Splitter (Row selected | Row transform)
              ResizeHandle(
                axis: Axis.horizontal,
                onDelta: (dx) => setState(() {
                  _leftFrac = cfg.clamp(_leftFrac + dx / totalW);
                }),
              ),
              // 2. ROW TRANSFORM
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _SectionHeader('ROW TRANSFORM'),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Section(
                              title: 'VARIABLES',
                              subtitle: warningCount > 0
                                  ? '${row.vars.length} entries · $warningCount warning${warningCount == 1 ? "" : "s"}'
                                  : '${row.vars.length} entries',
                              child: _VariablesTable(vars: row.vars),
                            ),
                            const SizedBox(height: 24),
                            _Section(
                              title: 'RULES',
                              subtitle: row.matchedRuleIndex != null
                                  ? 'matched rule [${row.matchedRuleIndex}]'
                                  : 'no rule matched',
                              child: _RulesTable(
                                rules: row.rules,
                                matchedIndex: row.matchedRuleIndex,
                                filtered: row.filteredReason,
                              ),
                            ),
                            if (row.matchedRuleIndex != null) ...[
                              const SizedBox(height: 24),
                              Builder(
                                builder: (ctx) {
                                  final matched = row.rules
                                      .where(
                                        (r) =>
                                            r.ruleIndex == row.matchedRuleIndex,
                                      )
                                      .firstOrNull;
                                  if (matched == null) {
                                    return const SizedBox.shrink();
                                  }
                                  final ruleVars = row.vars
                                      .where(
                                        (v) =>
                                            v.origin == 'row_rules' &&
                                            v.ruleIndex ==
                                                row.matchedRuleIndex,
                                      )
                                      .toList();
                                  return _Section(
                                    title: 'RULE RESULTS',
                                    subtitle: 'rule [${row.matchedRuleIndex}]',
                                    child: ruleVars.isEmpty
                                        ? Text(
                                            'No override rows.',
                                            style: BxpText.italic(
                                              context,
                                              size: BxpSize.sm,
                                            ),
                                          )
                                        : _RuleResultsTable(vars: ruleVars),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            );
          }),
        ),
      ],
    );
  }
}

class DataColorText extends StatelessWidget {
  final String text;
  final BxpSize size;
  const DataColorText({super.key, required this.text, this.size = BxpSize.md});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final t = context.bxpTheme;
    return Text(
      text,
      style: BxpText.body(
        context,
        color: t.valueColorOf(text),
        weight: BxpWeight.regular,
        size: size,
      ),
    );
  }
}

// ── Section header ──────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: t.panelBg,
        border: Border(bottom: BorderSide(color: t.borderColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: BxpText.label(context, color: t.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section ─────────────────────────────────────────────────────────
class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const _Section({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title, style: BxpText.heading(context, color: t.textSubtle)),
            if (subtitle != null) ...[
              const SizedBox(width: 8),
              Text(subtitle!, style: BxpText.subtle(context, size: BxpSize.sm)),
            ],
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

// ── Fields Table ─────────────────────────────────────────────────────
//
// Two paths:
//
// • headers.length <= kWideColLimit — `Table` with IntrinsicColumnWidth
//   on column 0 so the header column auto-shrinks to its longest entry
//   (capped at 50 % of panel). Nice ergonomics for broker exports.
//
// • headers.length > kWideColLimit — `ListView.builder` virtualises
//   the row list (offscreen rows are not built) and a fixed 40 % first
//   column avoids the all-rows layout pass that IntrinsicColumnWidth
//   forces. Row-select on a 900-col file otherwise builds 900 TableRow
//   widgets up front and runs an intrinsic-width pass over all of them
//   on the main isolate — multi-second hang.
class _FieldsTable extends StatelessWidget {
  final List<String> headers;
  final List<String> values;
  const _FieldsTable({required this.headers, required this.values});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final headerStyle = BxpText.body(
      context,
      color: t.textMuted,
      size: BxpSize.sm,
    );

    if (headers.length > kWideColLimit) {
      // Render at most kMaxDisplayCols fields — bxp-gui is a debug view, not
      // a wide-CSV viewer, and the row-selected dump matches the grid's
      // column cap. A trailing banner reports how many were hidden. The
      // referenced columns are still visible in the row-transform variable
      // trace, so capping the raw dump loses no debug signal.
      final shownCount =
          headers.length > kMaxDisplayCols ? kMaxDisplayCols : headers.length;
      final hiddenCount = headers.length - shownCount;
      return LayoutBuilder(
        builder: (context, constraints) {
          final headerColWidth = constraints.maxWidth * 0.4;
          return ListView.builder(
            itemCount: shownCount + (hiddenCount > 0 ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == shownCount) {
                // Trailing cap banner.
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                  child: Text(
                    '⚠ Showing first $shownCount of ${headers.length} fields '
                    '— bxp-gui is a debug view, not a wide-CSV viewer.',
                    style: BxpText.body(
                      context,
                      color: t.textMuted,
                      size: BxpSize.sm,
                    ),
                  ),
                );
              }
              final val = i < values.length ? values[i] : '';
              return DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t.borderColor)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: headerColWidth,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 5, 10, 5),
                        child: Text(headers[i], style: headerStyle),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 5, 12, 5),
                        child: DataColorText(text: val, size: BxpSize.md),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    }

    return SingleChildScrollView(
      child: Table(
        // Header column shrinks to fit its content but is capped at 50 %
        // of the panel width — long header names wrap inside that cap
        // instead of pushing the value column off-screen.
        columnWidths: const {
          0: MinColumnWidth(IntrinsicColumnWidth(), FractionColumnWidth(0.5)),
          1: FlexColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: headers.asMap().entries.map((e) {
          final val = e.key < values.length ? values[e.key] : '';
          return TableRow(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.borderColor)),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 5, 10, 5),
                child: Text(e.value, style: headerStyle),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 5, 12, 5),
                child: DataColorText(text: val, size: BxpSize.md),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

// ── Variables Table ──────────────────────────────────────────────────
//
// Two-column Table: `variable` (intrinsic width, auto-fit across all rows)
// and `expr → result` (flex, fills the rest). The result is rendered on the
// line below the formula. Vars from `row_rules` (origin != 'input_schema')
// are filtered out — they belong to the Rule Results panel where they
// surface alongside the matched rule.
class _VariablesTable extends StatefulWidget {
  final List<VarEntry> vars;
  const _VariablesTable({required this.vars});

  @override
  State<_VariablesTable> createState() => _VariablesTableState();
}

class _VariablesTableState extends State<_VariablesTable> {
  int? _hoverIdx;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final shown = widget.vars
        .where((v) => v.origin == 'input_schema')
        .toList();

    if (shown.isEmpty) {
      return Text('No vars.', style: BxpText.italic(context, size: BxpSize.sm));
    }

    final headerStyle = BxpText.body(
      context,
      color: t.textMuted,
      size: BxpSize.sm,
    );

    return Container(
      decoration: BoxDecoration(border: Border.all(color: t.borderColor)),
      child: Table(
        columnWidths: const {
          0: IntrinsicColumnWidth(),
          1: FlexColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [
          TableRow(
            decoration: BoxDecoration(color: t.panelBg),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('variable', style: headerStyle),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('expr → result', style: headerStyle),
              ),
            ],
          ),
          ...shown.asMap().entries.map((entry) {
            final i = entry.key;
            final v = entry.value;
            final isError = v.kind == 'error';
            final isHovered = _hoverIdx == i;
            final Color rowBg;
            if (isError) {
              rowBg = Color.alphaBlend(
                t.errorBg.withValues(alpha: isHovered ? 0.32 : 0.2),
                Colors.transparent,
              );
            } else if (isHovered) {
              rowBg = t.panelBg;
            } else {
              rowBg = Colors.transparent;
            }
            return TableRow(
              decoration: BoxDecoration(
                color: rowBg,
                border: Border(top: BorderSide(color: t.borderColor)),
              ),
              children: [
                _JumpCell(
                  onEnter: () => setState(() => _hoverIdx = i),
                  onExit: () => setState(() {
                    if (_hoverIdx == i) _hoverIdx = null;
                  }),
                  onTap: () => context.read<TraceStore>().jumpToConfigVar(
                    v.name,
                    v.expr ?? '',
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(
                      v.name,
                      style: BxpText.body(
                        context,
                        color: t.codeVariable,
                        size: BxpSize.sm,
                      ),
                    ),
                  ),
                ),
                _JumpCell(
                  onEnter: () => setState(() => _hoverIdx = i),
                  onExit: () => setState(() {
                    if (_hoverIdx == i) _hoverIdx = null;
                  }),
                  onTap: () => context.read<TraceStore>().jumpToConfigVar(
                    v.name,
                    v.expr ?? '',
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: _ExprResultCell(v: v),
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

// MouseRegion + GestureDetector wrapper for cells that participate in row-
// level hover and click. Sized to fill the cell so the whole row reacts.
class _JumpCell extends StatelessWidget {
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onTap;
  final Widget child;
  const _JumpCell({
    required this.onEnter,
    required this.onExit,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
  }
}

// Two-line cell: `expr` on top, `→ result` (or `→ ⚠ <error>`) below.
// Used by both the Variables table and the Rule Results panel.
class _ExprResultCell extends StatelessWidget {
  final VarEntry v;
  const _ExprResultCell({required this.v});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final isError = v.kind == 'error';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (v.expr != null && v.expr!.isNotEmpty)
          ExprHighlight(text: v.expr!, size: BxpSize.sm, hoverContext: true)
        else
          Text(
            '—',
            style: BxpText.body(context, color: t.textMuted, size: BxpSize.sm),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: isError
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '→ ⚠ ',
                      style: BxpText.body(
                        context,
                        color: t.errorText,
                        size: BxpSize.sm,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            v.error ?? '',
                            style: BxpText.body(
                              context,
                              color: t.errorText,
                              size: BxpSize.sm,
                              weight: BxpWeight.semiBold,
                            ),
                          ),
                          if (v.detail != null && v.detail!.isNotEmpty)
                            Text(
                              v.detail!,
                              style: BxpText.body(
                                context,
                                color: t.errorText,
                                size: BxpSize.xs,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '→ ',
                      style: BxpText.body(
                        context,
                        color: t.textMuted,
                        size: BxpSize.sm,
                      ),
                    ),
                    Expanded(
                      child: DataColorText(
                        text: v.value ?? '',
                        size: BxpSize.md,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

// ── Rules Table ──────────────────────────────────────────────────────
class _RulesTable extends StatefulWidget {
  final List<RuleEntry> rules;
  final int? matchedIndex;
  final String? filtered;
  const _RulesTable({required this.rules, this.matchedIndex, this.filtered});

  @override
  State<_RulesTable> createState() => _RulesTableState();
}

class _RulesTableState extends State<_RulesTable> {
  int? _hoverIdx;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final t = context.bxpTheme;
    final rules = widget.rules;
    final matchedIndex = widget.matchedIndex;
    final filtered = widget.filtered;

    if (rules.isEmpty && filtered == null) {
      return Text(
        'No rules evaluated.',
        style: BxpText.italic(context, size: BxpSize.sm),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (filtered != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              'Row filtered: $filtered',
              style: BxpText.body(context, color: t.warnText, size: BxpSize.sm),
            ),
          ),
        Container(
          decoration: BoxDecoration(border: Border.all(color: t.borderColor)),
          child: Column(
            children: [
              // Header row mirrors the layout below: #-column (right-aligned)
              // + match-glyph spacer + condition. The match column has no
              // header text — its glyph (✓/·) is self-explanatory and a
              // label there would just clutter a 28 px slot.
              Container(
                decoration: BoxDecoration(
                  color: t.panelBg,
                  border: Border(bottom: BorderSide(color: t.borderColor)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          '#',
                          style: BxpText.body(
                            context,
                            color: t.textMuted,
                            size: BxpSize.sm,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ),
                    const SizedBox(width: 28),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          'condition',
                          style: BxpText.body(
                            context,
                            color: t.textMuted,
                            size: BxpSize.sm,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ...rules.asMap().entries.map((entry) {
              final idx = entry.key;
              final r = entry.value;
              final isMatched = r.ruleIndex == matchedIndex;
              final isHovered = _hoverIdx == idx;
              // Hover background uses the same `withHover` token as the
              // variables table above so both row-transform tables share
              // one visual idiom. On the matched row we lift the tint
              // through `withHover` instead of dropping it so the green
              // anchor stays visible and hover still gives feedback.
              final Color bg;
              if (isMatched && isHovered) {
                bg = t.withHover(t.matchedRowTint);
              } else if (isMatched) {
                bg = t.matchedRowTint;
              } else if (isHovered) {
                bg = t.withHover(t.surfaceBg);
              } else {
                bg = Colors.transparent;
              }
              return MouseRegion(
                onEnter: (_) => setState(() => _hoverIdx = idx),
                onExit: (_) {
                  if (_hoverIdx == idx) setState(() => _hoverIdx = null);
                },
                child: InkWell(
                  onTap: () => store.jumpToConfigRule(r.ruleIndex, r.when),
                  hoverColor: Colors.transparent,
                  child: Container(
                    decoration: BoxDecoration(
                      color: bg,
                      border: Border(bottom: BorderSide(color: t.borderColor)),
                    ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(
                            '${r.ruleIndex}',
                            style: BxpText.body(
                              context,
                              color: t.textMuted,
                              size: BxpSize.sm,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 28,
                        child: Center(
                          child: Text(
                            r.matched ? '✓' : '·',
                            style: TextStyle(
                              color: r.matched ? t.valueOk : t.valueEmpty,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: ExprHighlight(
                            text: r.when,
                            size: BxpSize.sm,
                            hoverContext: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  ),
                ),
              );
            }),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Rule Results Table ───────────────────────────────────────────────
//
// Wide tabular layout for the rule-local variables that fired for the
// matched rule:
//   * one column per `$var` defined in the rule's `rows[]` block
//     (union of all output rows, in first-occurrence order)
//   * one row per output_row_index (`row1`, `row2`, …)
//   * each cell is two-line: syntax-highlighted formula on top,
//     `→ value` (or `→ ⚠ error`) below
//   * column width auto-fits the widest expression in the column
//   * horizontal scrollbar when the table doesn't fit the panel
// Cell click jumps to the source override expression in the config tree
// via TraceStore.jumpToConfigRuleVar.
class _RuleResultsTable extends StatefulWidget {
  final List<VarEntry> vars;
  const _RuleResultsTable({required this.vars});

  @override
  State<_RuleResultsTable> createState() => _RuleResultsTableState();
}

class _RuleResultsTableState extends State<_RuleResultsTable> {
  final ScrollController _hCtrl = ScrollController();
  // Track hovered cell as (rowIdx, colIdx) so the row-detail panel can
  // give the typical clickable-row visual feedback.
  int? _hoverRow;
  int? _hoverCol;

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  static double _measureText(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.size.width;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    // Group vars by output_row_index, preserving insertion order so rows
    // render in the same order as the rule's `rows[]` block in config.
    final groups = <int, Map<String, VarEntry>>{};
    final rowOrder = <int>[];
    final colOrder = <String>[];
    final colSeen = <String>{};
    for (final v in widget.vars) {
      final ri = v.outputRowIndex ?? 0;
      if (!groups.containsKey(ri)) {
        groups[ri] = <String, VarEntry>{};
        rowOrder.add(ri);
      }
      groups[ri]![v.name] = v;
      if (colSeen.add(v.name)) colOrder.add(v.name);
    }

    // Per-column auto-fit: header text width vs. widest expression text in
    // that column. Clamped to a sensible range so a single very long expr
    // doesn't blow the table off-screen.
    final headerStyle = BxpText.body(
      context,
      color: t.codeVariable,
      size: BxpSize.sm,
      weight: BxpWeight.semiBold,
    );
    final exprStyle = BxpText.body(context, size: BxpSize.sm);
    const cellPad = 32.0; // 8 px each side + breathing room
    const minColWidth = 80.0;
    const maxColWidth = 360.0;
    const indexColWidth = 48.0;

    final colWidths = <String, double>{};
    for (final col in colOrder) {
      double maxW = _measureText(col, headerStyle);
      for (final ri in rowOrder) {
        final v = groups[ri]?[col];
        final expr = v?.expr ?? '';
        if (expr.isEmpty) continue;
        final w = _measureText(expr, exprStyle);
        if (w > maxW) maxW = w;
      }
      colWidths[col] = (maxW + cellPad).clamp(minColWidth, maxColWidth);
    }
    final tableWidth =
        indexColWidth + colWidths.values.fold<double>(0, (sum, w) => sum + w);

    return Container(
      decoration: BoxDecoration(border: Border.all(color: t.borderColor)),
      child: Scrollbar(
        controller: _hCtrl,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _hCtrl,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row: # | $var1 | $var2 | …
                Container(
                  decoration: BoxDecoration(
                    color: t.panelBg,
                    border: Border(bottom: BorderSide(color: t.borderColor)),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: indexColWidth,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          child: Text(
                            '#',
                            style: BxpText.body(
                              context,
                              color: t.textMuted,
                              size: BxpSize.sm,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ),
                      ...colOrder.map(
                        (col) => SizedBox(
                          width: colWidths[col],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Text(col, style: headerStyle),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Data rows: one per output_row_index, two-line cells.
                ...rowOrder.asMap().entries.map((entry) {
                  final ri = entry.key;
                  final outIdx = entry.value;
                  return Container(
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: t.borderColor)),
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: indexColWidth,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 6,
                              ),
                              child: Text(
                                '$outIdx',
                                style: BxpText.body(
                                  context,
                                  color: t.textMuted,
                                  size: BxpSize.sm,
                                ),
                                textAlign: TextAlign.right,
                              ),
                            ),
                          ),
                          ...colOrder.asMap().entries.map((cEntry) {
                            final ci = cEntry.key;
                            final col = cEntry.value;
                            final v = groups[outIdx]?[col];
                            final isHovered =
                                _hoverRow == ri && _hoverCol == ci;
                            final isError = v?.kind == 'error';
                            final Color cellBg;
                            if (isError) {
                              cellBg = Color.alphaBlend(
                                t.errorBg.withValues(
                                  alpha: isHovered ? 0.32 : 0.2,
                                ),
                                Colors.transparent,
                              );
                            } else if (isHovered) {
                              cellBg = t.panelBg;
                            } else {
                              cellBg = Colors.transparent;
                            }
                            return Container(
                              width: colWidths[col],
                              decoration: BoxDecoration(color: cellBg),
                              child: v == null
                                  ? const SizedBox.shrink()
                                  : _JumpCell(
                                      onEnter: () => setState(() {
                                        _hoverRow = ri;
                                        _hoverCol = ci;
                                      }),
                                      onExit: () => setState(() {
                                        if (_hoverRow == ri &&
                                            _hoverCol == ci) {
                                          _hoverRow = null;
                                          _hoverCol = null;
                                        }
                                      }),
                                      onTap: () => context
                                          .read<TraceStore>()
                                          .jumpToConfigRuleVar(
                                            v.ruleIndex ?? 0,
                                            v.outputRowIndex ?? outIdx,
                                            v.name,
                                            v.expr ?? '',
                                          ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 6,
                                        ),
                                        child: _ExprResultCell(v: v),
                                      ),
                                    ),
                            );
                          }),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

