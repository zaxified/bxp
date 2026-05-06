import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../../store/trace_model.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_highlight.dart';
import 'resize_handle.dart';

class RowDetail extends StatefulWidget {
  const RowDetail({super.key});

  @override
  State<RowDetail> createState() => _RowDetailState();
}

class _RowDetailState extends State<RowDetail> {
  // Default left-pane width. Mirrors bxp-ui's `SEL_DEFAULT_W = 300`
  // so a side-by-side comparison lines up out of the box.
  double _leftWidth = 300;

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
    final errorCount = row.vars.where((v) => v.kind == 'error').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Error banner ────────────────────────────────────────────
        if (errorCount > 0)
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
                Text(
                  '$errorCount variable ${errorCount == 1 ? "error" : "errors"} in this row — see Variables below.',
                  style: BxpText.body(
                    context,
                    color: t.errorText,
                    size: BxpSize.sm,
                  ),
                ),
              ],
            ),
          ),

        // ── Main split: ROW SELECTED | ROW TRANSFORM ───────────────
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. ROW SELECTED
              SizedBox(
                width: _leftWidth,
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
                  _leftWidth = (_leftWidth + dx).clamp(160.0, 600.0);
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
                              subtitle: errorCount > 0
                                  ? '${row.vars.length} entries · $errorCount error${errorCount == 1 ? "" : "s"}'
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
                                  if (matched == null)
                                    return const SizedBox.shrink();
                                  return _Section(
                                    title: 'RULE RESULTS',
                                    subtitle: 'rule [${row.matchedRuleIndex}]',
                                    child: matched.rows.isEmpty
                                        ? Text(
                                            'No override rows.',
                                            style: BxpText.italic(
                                              context,
                                              size: BxpSize.sm,
                                            ),
                                          )
                                        : _RuleResultsTable(rows: matched.rows),
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
          ),
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
    final Color color;
    if (text.toLowerCase() == 'true' || text.toLowerCase() == 'false') {
      color = t.valueBool;
    } else if (num.tryParse(text) != null) {
      color = t.valueNumber;
    } else {
      color = t.valueString;
    }
    return Text(
      text,
      style: BxpText.body(
        context,
        color: color,
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

    return SingleChildScrollView(
      child: Table(
        // Header column shrinks to fit its content but is capped at 40 %
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
class _VariablesTable extends StatelessWidget {
  final List<VarEntry> vars;
  const _VariablesTable({required this.vars});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;

    if (vars.isEmpty) {
      return Text('No vars.', style: BxpText.italic(context, size: BxpSize.sm));
    }
    return Container(
      decoration: BoxDecoration(border: Border.all(color: t.borderColor)),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(color: t.panelBg),
            child: const Row(
              children: [
                _VarCell('result', width: 110, isHeader: true),
                _VarCell('', width: 24, isHeader: true),
                _VarCell('variable', width: 100, isHeader: true),
                Expanded(child: _VarCell('expr', isHeader: true)),
              ],
            ),
          ),
          ...vars.map((v) {
            final isError = v.kind == 'error';
            return Container(
              decoration: BoxDecoration(
                color: isError
                    ? Color.alphaBlend(
                        t.errorBg.withValues(alpha: 0.2),
                        Colors.transparent,
                      )
                    : Colors.transparent,
                border: Border(top: BorderSide(color: t.borderColor)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: isError
                          ? Column(
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
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (v.detail != null)
                                  Text(
                                    v.detail!,
                                    style: BxpText.body(
                                      context,
                                      color: t.errorText,
                                      size: BxpSize.xs,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            )
                          : Padding(
                              padding: const EdgeInsets.only(top: 0),
                              child: DataColorText(
                                text: v.value ?? '',
                                size: BxpSize.md,
                              ),
                            ),
                    ),
                  ),
                  SizedBox(
                    width: 24,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Center(
                        child: isError
                            ? Text(
                                '⚠',
                                style: TextStyle(
                                  color: t.errorText,
                                  fontSize: 11,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 100,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(
                        v.name,
                        style: BxpText.body(
                          context,
                          color: t.codeVariable,
                          size: BxpSize.sm,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: v.expr != null
                          ? ExprHighlight(text: v.expr!, size: BxpSize.sm)
                          : Text(
                              '—',
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
            );
          }),
        ],
      ),
    );
  }
}

class _VarCell extends StatelessWidget {
  final String label;
  final double? width;
  final bool isHeader;
  const _VarCell(this.label, {this.width, this.isHeader = false});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: BxpText.body(
            context,
            color: isHeader ? t.textMuted : t.textPrimary,
            size: BxpSize.sm,
          ),
        ),
      ),
    );
  }
}

// ── Rules Table ──────────────────────────────────────────────────────
class _RulesTable extends StatelessWidget {
  final List<RuleEntry> rules;
  final int? matchedIndex;
  final String? filtered;
  const _RulesTable({required this.rules, this.matchedIndex, this.filtered});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final t = context.bxpTheme;

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
            children: rules.map((r) {
              final isMatched = r.ruleIndex == matchedIndex;
              return InkWell(
                onTap: () => store.jumpToConfigRule(r.ruleIndex, r.when),
                child: Container(
                  decoration: BoxDecoration(
                    color: isMatched ? t.matchedRowTint : Colors.transparent,
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
                          child: ExprHighlight(text: r.when, size: BxpSize.sm),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

// ── Rule Results Table ───────────────────────────────────────────────
class _RuleResultsTable extends StatefulWidget {
  final List<Map<String, String>> rows;
  const _RuleResultsTable({required this.rows});

  @override
  State<_RuleResultsTable> createState() => _RuleResultsTableState();
}

class _RuleResultsTableState extends State<_RuleResultsTable> {
  final ScrollController _hCtrl = ScrollController();

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
    final rows = widget.rows;
    final t = context.bxpTheme;

    final allKeys = rows.expand((r) => r.keys).toSet().toList();

    // Per-column auto-fit: widest of header text and any non-empty cell
    // value, clamped to a sensible range. Mirrors the column-sizing
    // approach used in OutputPanel / RowList so the three tables size
    // consistently.
    final headerStyle = BxpText.body(
      context,
      color: t.codeVariable,
      size: BxpSize.sm,
    );
    final cellStyle = BxpText.body(context, size: BxpSize.md);
    const cellPad = 32.0; // 8 px each side + breathing room
    const minColWidth = 60.0;
    const maxColWidth = 320.0;
    const indexColWidth = 40.0;

    final colWidths = <String, double>{};
    for (final k in allKeys) {
      double maxW = _measureText(k, headerStyle);
      for (final row in rows) {
        final v = row[k];
        if (v == null || v.isEmpty) continue;
        final w = _measureText(v, cellStyle);
        if (w > maxW) maxW = w;
      }
      colWidths[k] = (maxW + cellPad).clamp(minColWidth, maxColWidth);
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
              Container(
                decoration: BoxDecoration(color: t.panelBg),
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
                        ),
                      ),
                    ),
                    ...allKeys.map(
                      (k) => SizedBox(
                        width: colWidths[k],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(k, style: headerStyle),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ...rows.asMap().entries.map(
                (e) => Container(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: t.borderColor)),
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
                            '${e.key + 1}',
                            style: BxpText.body(
                              context,
                              color: t.textMuted,
                              size: BxpSize.sm,
                            ),
                          ),
                        ),
                      ),
                      ...allKeys.map((k) {
                        final v = e.value[k];
                        return SizedBox(
                          width: colWidths[k],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: v == null
                                ? Text(
                                    '—',
                                    style: BxpText.body(
                                      context,
                                      color: t.borderColor,
                                      size: BxpSize.sm,
                                    ),
                                  )
                                : v.isEmpty
                                ? Text(
                                    '""',
                                    style: BxpText.body(
                                      context,
                                      color: t.valueEmpty,
                                      size: BxpSize.sm,
                                    ),
                                  )
                                : DataColorText(text: v, size: BxpSize.md),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
