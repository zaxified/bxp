import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'panel_header.dart';

/// 4th panel in the Runner layout: displays the output rows written
/// for the currently selected input row.
///
/// Column headers are derived from the template's `output_schema`
/// (not from the file_start event), so we see both the CSV header name
/// (e.g. `date`) and the variable that populated it (e.g. `$date`) —
/// matching bxp-ui's OutputPanel layout.
class OutputPanel extends StatelessWidget {
  const OutputPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final model = store.traceModel;
    final rowId = store.selectedRowId;
    final fileId = store.selectedFileId;

    if (model == null || rowId == null || fileId == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PanelHeader(title: 'ROWS OUT'),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Select a row above.',
                  style: BxpText.italic(context, size: BxpSize.sm)),
            ),
          ),
        ],
      );
    }

    final row = model.rows[rowId];
    final file = model.files[fileId];
    if (row == null || file == null) return const SizedBox.shrink();

    final cols = _resolveColumns(store.configJson, file.template, row.outputs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(title: 'ROWS OUT', count: row.outputs.length),
        Expanded(
          child: row.outputs.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('No output (row not written).',
                      style: BxpText.italic(context, size: BxpSize.sm)),
                )
              : _OutputTable(cols: cols, rows: row.outputs),
        ),
      ],
    );
  }

  /// Prefer config-declared schema (gives us `header` + `variable`),
  /// fall back to positional `[1]..[N]` placeholders when not available.
  List<_ColDef> _resolveColumns(
      Map<String, dynamic>? config, String templateId, List<List<String>> outputs) {
    if (config != null) {
      final templates = config['conversion_templates'];
      if (templates is Map) {
        final tpl = templates[templateId];
        if (tpl is Map) {
          final schema = tpl['output_schema'];
          if (schema is Map && schema.isNotEmpty) {
            // bxp-fmt's annotated JSON interleaves UI metadata keys with
            // real schema pairs: `$comm_N` (comments), `$err_N`
            // (diagnostics), `$meta_<key>` / `$elem_meta_<key>` /
            // `$meta_self` (byte-span info from bxp-fmt). All `$`-prefixed
            // entries are render-only artefacts and must not surface as
            // output columns. Schema keys themselves start with `$`
            // (`$action`, `$ticker`, …) so we exclude only the meta forms.
            return schema.entries
                .where((e) {
                  final k = e.key.toString();
                  return !k.startsWith(r'$comm_') &&
                      !k.startsWith(r'$err_') &&
                      !k.startsWith(r'$meta_') &&
                      !k.startsWith(r'$elem_meta_') &&
                      k != r'$meta_self';
                })
                .map((e) => _ColDef(
                      header: e.key.toString(),
                      variable: e.value?.toString() ?? '',
                    ))
                .toList();
          }
        }
      }
    }
    final cols = outputs.isNotEmpty ? outputs.first.length : 0;
    return List.generate(cols, (i) => _ColDef(header: '[${i + 1}]', variable: ''));
  }
}

class _ColDef {
  final String header;
  final String variable;
  const _ColDef({required this.header, required this.variable});
}

class _OutputTable extends StatefulWidget {
  final List<_ColDef> cols;
  final List<List<String>> rows;
  const _OutputTable({required this.cols, required this.rows});

  @override
  State<_OutputTable> createState() => _OutputTableState();
}

class _OutputTableState extends State<_OutputTable> {
  final _vCtrl = ScrollController();
  final _hCtrl = ScrollController();

  @override
  void dispose() {
    _vCtrl.dispose();
    _hCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final cols = widget.cols;
    final rows = widget.rows;

    const indexColWidth = 48.0;
    const cellPad = 37.0; // 8px each side + ~3 chars breathing room
    const minWidth = 60.0;
    const maxWidth = 320.0;

    // Measure column widths with TextPainter — same approach as ROWS IN so
    // both panels size consistently (header + variable + all cell values).
    final headerStyle =
        BxpText.body(context, size: BxpSize.sm, weight: BxpWeight.semiBold);
    final varStyle = BxpText.body(context, size: BxpSize.xs);
    final cellStyle = BxpText.body(context, size: BxpSize.md);

    final colWidths = <int, TableColumnWidth>{
      0: const FixedColumnWidth(indexColWidth),
    };
    for (int i = 0; i < cols.length; i++) {
      double maxW = _measureText(cols[i].header, headerStyle);
      if (cols[i].variable.isNotEmpty) {
        final vw = _measureText(cols[i].variable, varStyle);
        if (vw > maxW) maxW = vw;
      }
      for (final row in rows) {
        if (i < row.length && row[i].isNotEmpty) {
          final w = _measureText(row[i], cellStyle);
          if (w > maxW) maxW = w;
        }
      }
      colWidths[i + 1] =
          FixedColumnWidth((maxW + cellPad).clamp(minWidth, maxWidth));
    }

    return Scrollbar(
      controller: _vCtrl,
      thumbVisibility: true,
      child: Scrollbar(
        controller: _hCtrl,
        thumbVisibility: true,
        notificationPredicate: (n) => n.depth == 1,
        child: SingleChildScrollView(
          controller: _vCtrl,
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            controller: _hCtrl,
            scrollDirection: Axis.horizontal,
            child: Table(
              columnWidths: colWidths,
              border: TableBorder(
                horizontalInside: BorderSide(color: t.borderColor),
                verticalInside: BorderSide(color: t.borderColor),
                bottom: BorderSide(color: t.borderColor),
              ),
              children: [
                TableRow(
                  decoration: BoxDecoration(color: t.panelBg),
                  children: [
                    _HeaderCell(header: '#', variable: '', align: TextAlign.right),
                    for (final c in cols)
                      _HeaderCell(header: c.header, variable: c.variable),
                  ],
                ),
                for (int r = 0; r < rows.length; r++)
                  TableRow(
                    children: [
                      _IndexCell('${r + 1}'),
                      for (int i = 0; i < cols.length; i++)
                        _ValueCell(i < rows[r].length ? rows[r][i] : ''),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static double _measureText(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.size.width;
  }
}

class _HeaderCell extends StatelessWidget {
  final String header;
  final String variable;
  final TextAlign align;
  const _HeaderCell(
      {required this.header, required this.variable, this.align = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: align == TextAlign.right
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (variable.isNotEmpty)
            Text(variable,
                style: BxpText.body(context,
                    color: t.codeVariable, size: BxpSize.xs, height: 1.15)),
          Text(header,
              style: BxpText.body(context,
                  color: t.textSubtle,
                  size: BxpSize.sm,
                  weight: BxpWeight.semiBold,
                  height: 1.2),
              textAlign: align),
        ],
      ),
    );
  }
}

class _IndexCell extends StatelessWidget {
  final String text;
  const _IndexCell(this.text);
  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(text,
          textAlign: TextAlign.right,
          style: BxpText.body(context, color: t.textMuted, size: BxpSize.sm)),
    );
  }
}

class _ValueCell extends StatelessWidget {
  final String value;
  const _ValueCell(this.value);
  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: SizedBox.shrink(),
      );
    }
    final t = context.bxpTheme;
    final Color color;
    if (value.toLowerCase() == 'true' || value.toLowerCase() == 'false') {
      color = t.valueBool;
    } else if (num.tryParse(value) != null) {
      color = t.valueNumber;
    } else {
      color = t.valueString;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(value,
          style: BxpText.body(context,
              color: color, weight: BxpWeight.regular, size: BxpSize.md)),
    );
  }
}
