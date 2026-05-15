import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../../store/trace_model.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';

/// Renders the input rows table for the currently selected file.
///
/// PlutoGrid keeps internal state (columns, row cache, focused cell) that
/// does NOT refresh on rebuild alone — so we key the widget by fileId to
/// force a hard re-mount when the user picks a different file. Without
/// this, clicking a file in FileList leaves the grid showing the previous
/// file's data.
class RowList extends StatelessWidget {
  const RowList({super.key});

  String _rowStatus(RowModel row) {
    if (row.hasError) return 'error';
    if (row.outputs.isNotEmpty) return 'written';
    if (row.filteredReason != null) return 'filtered';
    return 'no-match';
  }

  String _statusIcon(String status) {
    switch (status) {
      case 'written':
        return '▶';
      case 'filtered':
        return '▼';
      case 'error':
        return '✕';
      case 'no-match':
      default:
        return '·';
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final model = store.traceModel;
    final fileId = store.selectedFileId;

    if (model == null || fileId == null) {
      return Padding(
        padding: const EdgeInsets.all(12.0),
        child: Text(
          'Select a file on the left.',
          style: BxpText.italic(context),
        ),
      );
    }

    final file = model.files[fileId];
    if (file == null) return const SizedBox.shrink();

    return _RowListInner(
      // Hard remount on file change — PlutoGrid would otherwise keep the
      // old columns/rows and ignore new inputs.
      key: ValueKey('rowlist::$fileId::${file.headers.join("|")}'),
      fileId: fileId,
      file: file,
      model: model,
      store: store,
      rowStatus: _rowStatus,
      statusIcon: _statusIcon,
    );
  }
}

class _RowListInner extends StatefulWidget {
  final String fileId;
  final FileModel file;
  final TraceModel model;
  final TraceStore store;
  final String Function(RowModel) rowStatus;
  final String Function(String) statusIcon;

  const _RowListInner({
    super.key,
    required this.fileId,
    required this.file,
    required this.model,
    required this.store,
    required this.rowStatus,
    required this.statusIcon,
  });

  @override
  State<_RowListInner> createState() => _RowListInnerState();
}

class _RowListInnerState extends State<_RowListInner> {
  PlutoGridStateManager? _stateManager;
  /// Previous-frame `activeTabIndex` snapshot. When the user swaps to a
  /// non-Runner tab and returns, PlutoGrid's keyboard focus snaps back
  /// to (row 0, row_num) instead of the previously selected row — a
  /// stale highlight rectangle that doesn't match what RowDetail /
  /// OutputPanel are showing. Detecting the tab transition lets us
  /// drop the grid focus on the way out so the return doesn't render
  /// the wrong cell as focused.
  int? _lastTabIndex;

  /// Per-column substring filter (case-insensitive). Empty string = no
  /// filter on that column. Filtering is applied imperatively via
  /// [PlutoGridStateManager.setFilter] — passing a pre-filtered `rows`
  /// list to PlutoGrid doesn't work because the grid keeps its own copy
  /// in `stateManager.refRows`.
  final Map<String, String> _filters = {};

  /// Horizontal scroll controller for the sticky filter row above the
  /// grid. Kept in sync with PlutoGrid's body scroll so the filter
  /// inputs stay aligned with their columns when the grid is wider
  /// than the viewport.
  final ScrollController _filterHCtrl = ScrollController();

  /// Fallback scroll controllers used before PlutoGrid's onLoaded fires.
  /// Replaced by PlutoGrid's real body controllers once they are available,
  /// keeping the widget tree shape constant so PlutoGrid is never remounted.
  final ScrollController _fallbackVertCtrl = ScrollController();
  final ScrollController _fallbackHorizCtrl = ScrollController();

  /// Real body scroll controllers sourced from PlutoGrid's stateManager.
  /// Set synchronously inside onLoaded (before the postFrameCallback setState)
  /// so the next rebuild triggered by _publishColumnWidths sees them already.
  ScrollController? _bodyVertCtrl;
  ScrollController? _bodyHorizCtrl;

  /// Live column widths read from PlutoGrid's stateManager. Updated
  /// after autoFitColumn fires on load and whenever the user drags a
  /// column edge. The filter row above the grid uses these to keep
  /// each input perfectly aligned with the column it filters — the
  /// previous hardcoded 150 px diverged the moment auto-fit picked a
  /// different size.
  Map<String, double> _colWidths = {};

  /// Measurement styles cached during build — BxpText calls
  /// context.watch internally, which is invalid inside post-frame
  /// callbacks. Cached here so _autoFitDataColumns can use them safely.
  TextStyle? _cachedHeaderStyle;
  TextStyle? _cachedCellStyle;

  @override
  void initState() {
    super.initState();
    // Auto-select the first row when a file with rows is opened but no
    // row is yet selected — primes RowDetail / OutputPanel so they
    // aren't "empty" on first paint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.store.selectedRowId != null) return;
      final firstId = widget.file.rowIds.firstOrNull;
      if (firstId != null && widget.model.rows[firstId] != null) {
        widget.store.selectRow(firstId);
      }
    });
  }

  @override
  void dispose() {
    _stateManager?.resizingChangeNotifier.removeListener(_publishColumnWidths);
    _filterHCtrl.dispose();
    _fallbackVertCtrl.dispose();
    _fallbackHorizCtrl.dispose();
    // _bodyVertCtrl / _bodyHorizCtrl are owned by PlutoGrid — do not dispose.
    super.dispose();
  }

  /// Per-column width measurement. Considers BOTH the column header
  /// text and every visible cell, using their respective real text
  /// styles (PlutoGrid's built-in autoFitColumn picks the longer
  /// string by char count, then measures with the *default* text
  /// style — which is wrong for our monospace cells and ignores the
  /// title outright). Result is clamped to [minWidth, maxWidth]:
  /// minWidth keeps short data + short header readable; maxWidth
  /// stops a single long URL/UUID from eating half the viewport
  /// (the user can still drag wider).
  void _autoFitDataColumns(PlutoGridStateManager sm) {
    final headerStyle = _cachedHeaderStyle;
    final cellStyle = _cachedCellStyle;
    if (headerStyle == null || cellStyle == null) return;
    const cellHorizontalPadding = 14.0; // PlutoGrid default cell pad
    const cellExtraChars = 21.0; // ~3 chars breathing room
    const minWidth = 60.0;
    const maxWidth = 320.0;

    for (final col in sm.refColumns) {
      if (col.field == 'row_num' || col.field == 'status') continue;
      double maxW = _measureText(col.title, headerStyle);
      for (final row in sm.refRows) {
        final v = row.cells[col.field]?.value?.toString() ?? '';
        if (v.isEmpty) continue;
        final w = _measureText(v, cellStyle);
        if (w > maxW) maxW = w;
      }
      final target = (maxW + cellHorizontalPadding + cellExtraChars).clamp(
        minWidth,
        maxWidth,
      );
      sm.resizeColumn(col, target - col.width);
    }
  }

  static double _measureText(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.size.width;
  }

  /// Snapshot the current rendered widths from the grid's stateManager
  /// into `_colWidths` and trigger a rebuild so the filter row above
  /// resizes its inputs to match. Called once after the post-frame
  /// autoFitColumn pass, and again whenever the user drags a column
  /// edge (see `onColumnResized`).
  void _publishColumnWidths() {
    final sm = _stateManager;
    if (sm == null) return;
    final next = <String, double>{};
    for (final col in sm.refColumns) {
      next[col.field] = col.width;
    }
    if (!mapEquals(next, _colWidths)) {
      setState(() => _colWidths = next);
    }
  }

  /// Apply current `_filters` map to the grid via PlutoGrid's own
  /// filter API. Called every time a `_FilterCell` notifies a change.
  void _applyFilter() {
    final sm = _stateManager;
    if (sm == null) return;
    final headers = widget.file.headers;
    if (_filters.values.every((v) => v.isEmpty)) {
      sm.setFilter(null); // null clears all filters
      return;
    }
    sm.setFilter((row) {
      for (final h in headers) {
        final f = _filters[h];
        if (f == null || f.isEmpty) continue;
        final cell = row.cells[h]?.value?.toString() ?? '';
        if (!cell.toLowerCase().contains(f.toLowerCase())) return false;
      }
      return true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    // Detect Runner ↔ other-tab transitions. When the user swaps
    // *away* from Runner, drop PlutoGrid's keyboard focus + current
    // cell so the eventual return doesn't render a stale focus
    // rectangle on (row 0, row_num) instead of the previously
    // selected row. Re-syncing back to `selectedRowId` on return
    // would also be valid, but the user said "either restore or
    // clear" — clearing is simpler and matches the "tab switch is a
    // context switch" mental model.
    final tabIndex = context.select<TraceStore, int>((s) => s.activeTabIndex);
    const runnerTabIndex = 1;
    if (_lastTabIndex != null &&
        _lastTabIndex == runnerTabIndex &&
        tabIndex != runnerTabIndex) {
      // Leaving Runner — drop focus on the next frame (we're mid-build).
      final sm = _stateManager;
      if (sm != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          sm.clearCurrentCell();
          sm.gridFocusNode.unfocus();
        });
      }
    }
    _lastTabIndex = tabIndex;
    // Cache measurement styles — used later in the post-frame callback
    // _autoFitDataColumns where context.watch would be illegal.
    _cachedHeaderStyle = BxpText.body(
      context,
      size: BxpSize.sm,
      weight: BxpWeight.medium,
    );
    _cachedCellStyle = BxpText.body(context, size: BxpSize.md);
    final headers = widget.file.headers;
    // Pass ALL rows to PlutoGrid; filtering happens imperatively via
    // setFilter() below. Recomputing the rows list on every keystroke
    // would force a full rebuild (and lose scroll position).
    final rowList = widget.file.rowIds
        .map((id) => widget.model.rows[id])
        .whereType<RowModel>()
        .toList();

    final columns = <PlutoColumn>[
      PlutoColumn(
        title: '#',
        field: 'row_num',
        type: PlutoColumnType.text(),
        width: 44,
        minWidth: 44,
        enableEditingMode: false,
        enableSorting: false,
        enableFilterMenuItem: false,
        enableContextMenu: false,
        enableDropToResize: false,
        enableColumnDrag: false,
        textAlign: PlutoColumnTextAlign.right,
        renderer: (ctx) => Text(
          ctx.cell.value.toString(),
          textAlign: TextAlign.right,
          style: BxpText.body(context, color: t.textMuted, size: BxpSize.md),
        ),
      ),
      PlutoColumn(
        // Icon-only status column — no header text; the glyph is self-explanatory.
        title: '',
        field: 'status',
        type: PlutoColumnType.text(),
        width: 28,
        minWidth: 28,
        enableEditingMode: false,
        enableFilterMenuItem: false,
        enableContextMenu: false,
        enableDropToResize: false,
        enableColumnDrag: false,
        enableSorting: false,
        textAlign: PlutoColumnTextAlign.center,
        renderer: (ctx) {
          final status = ctx.cell.value.toString();
          Color color = t.textMuted;
          if (status == '▶') color = t.valueOk;
          if (status == '▼') color = t.valueWarn;
          if (status == '✕') color = t.valueError;
          return Text(
            status,
            style: BxpText.body(context, color: color, size: BxpSize.md),
          );
        },
      ),
      ...headers.map(
        (h) => PlutoColumn(
          title: h,
          field: h,
          type: PlutoColumnType.text(),
          // Initial width — auto-fit kicks in on load (see onLoaded
          // below) and resizes per column to its widest cell. User
          // can then drag the column edge to override.
          width: 150,
          minWidth: 60,
          enableEditingMode: false,
          enableSorting: false,
          enableFilterMenuItem: false,
          enableContextMenu: false,
          enableColumnDrag: false,
          enableDropToResize: true,
          renderer: (ctx) =>
              DataColorText(text: ctx.cell.value.toString(), size: BxpSize.md),
        ),
      ),
    ];

    final rows = rowList.map((row) {
      final status = widget.rowStatus(row);
      final cells = <String, PlutoCell>{
        'row_num': PlutoCell(value: '${row.fileRow}'),
        'status': PlutoCell(value: widget.statusIcon(status)),
      };
      for (int i = 0; i < headers.length; i++) {
        cells[headers[i]] = PlutoCell(
          value: i < row.fields.length ? row.fields[i] : '',
        );
      }
      return PlutoRow(cells: cells);
    }).toList();

    // Total width matches the actual rendered grid columns. We mirror
    // _colWidths (populated from stateManager after autoFitColumn and
    // again on any user resize) so each filter cell sits flush with
    // its column. Falls back to 150 per column on first paint, before
    // onLoaded has had a chance to publish real widths.
    double filterContentWidth = 44.0 + 28.0;
    for (final h in headers) {
      filterContentWidth += _colWidths[h] ?? 150.0;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          controller: _filterHCtrl,
          // Disable independent user-scroll on this row — it tracks
          // the grid's scroll position via the listener attached in
          // onLoaded; letting the user drag the filter row would
          // desync the alignment with the grid columns.
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: filterContentWidth,
            child: _FilterRow(
              headers: headers,
              filters: _filters,
              // Per-column widths sourced from the live grid; missing
              // entries (first paint) fall back to 150 px so the row
              // doesn't render with zero-width inputs.
              widths: {for (final h in headers) h: _colWidths[h] ?? 150.0},
              onChanged: (h, v) {
                setState(() {
                  if (v.isEmpty) {
                    _filters.remove(h);
                  } else {
                    _filters[h] = v;
                  }
                });
                _applyFilter();
              },
              // Drop the grid's current-cell highlight when the user
              // moves focus into a filter input — otherwise the last
              // clicked cell keeps its border, making it look like the
              // grid still owns input focus.
              //
              // Guard `mounted`: the focus listener can fire after this
              // RowList state has been disposed (e.g. tab switch under a
              // pending IME commit) — calling into a torn-down PlutoGrid
              // state manager throws asserts in debug builds.
              onFocus: () {
                if (!mounted) return;
                _stateManager?.clearCurrentCell();
              },
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Flutter Scrollbar computes _trackExtent = viewportDimension.
              // bodyRowsVertical.viewportDimension = PlutoGrid height minus
              // the column-header+padding offset (~33 px), leaving a gap at
              // the bottom. Compensate by injecting a negative MediaQuery
              // bottom-padding so the formula yields track = full height.
              final vCtrl = _bodyVertCtrl;
              final botPad = (vCtrl != null &&
                      vCtrl.hasClients &&
                      vCtrl.position.hasContentDimensions)
                  ? constraints.maxHeight - vCtrl.position.viewportDimension
                  : 0.0;
              // Horizontal Scrollbar must sit OUTSIDE the negative-bottom
              // MediaQuery, otherwise its cross-axis paint position uses
              // padding.bottom = -botPad and the thumb is drawn ~33 px
              // below the visible area (hidden behind the next panel's
              // header). The vertical Scrollbar still wraps the negative
              // padding so its track extends to the full panel height.
              return Scrollbar(
                controller: _bodyHorizCtrl ?? _fallbackHorizCtrl,
                thumbVisibility: _bodyHorizCtrl != null,
                notificationPredicate: (n) =>
                    n.metrics.axis == Axis.horizontal,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    padding: MediaQuery.paddingOf(context)
                        .copyWith(bottom: -botPad),
                  ),
                  child: Scrollbar(
                    controller: vCtrl ?? _fallbackVertCtrl,
                    thumbVisibility: vCtrl != null,
                    notificationPredicate: (n) =>
                        n.metrics.axis == Axis.vertical,
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                          padding: EdgeInsets.zero),
                      child: PlutoGrid(
            columns: columns,
            rows: rows,
            onLoaded: (event) {
              _stateManager = event.stateManager;
              _stateManager?.setShowColumnFilter(false);
              // Save PlutoGrid's real body scroll controllers synchronously so
              // the next rebuild (triggered by _publishColumnWidths below) can
              // swap them into the Flutter Scrollbar wrappers immediately.
              _bodyVertCtrl = event.stateManager.scroll.bodyRowsVertical;
              _bodyHorizCtrl = event.stateManager.scroll.bodyRowsHorizontal;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                final sm = _stateManager;
                if (sm == null) return;
                _autoFitDataColumns(sm);
                _publishColumnWidths();
                sm.resizingChangeNotifier.addListener(_publishColumnWidths);
              });
              // Mirror PlutoGrid's body horizontal scroll into our filter
              // row so the column header inputs stay aligned when the grid
              // scrolls sideways. We hop on the existing horizontal scroll
              // group's offset; PlutoGrid syncs body+header+footer via the
              // same controller group.
              final scroll = _stateManager?.scroll;
              scroll?.horizontal?.addOffsetChangedListener(() {
                if (!mounted || !_filterHCtrl.hasClients) return;
                final off = scroll.horizontal!.offset;
                if ((_filterHCtrl.offset - off).abs() > 0.5) {
                  _filterHCtrl.jumpTo(
                    off.clamp(
                      _filterHCtrl.position.minScrollExtent,
                      _filterHCtrl.position.maxScrollExtent,
                    ),
                  );
                }
              });
              // Re-apply any standing filters in case the grid was just
              // remounted (file change) while filters were still set.
              _applyFilter();
              // Auto-select the store's selectedRowId so the grid's visible
              // highlight matches what RowDetail/OutputPanel are showing.
              final selectedId = widget.store.selectedRowId;
              if (selectedId != null) {
                final idx = rowList.indexWhere((r) => r.id == selectedId);
                if (idx >= 0) {
                  _stateManager?.setCurrentCell(
                    rows[idx].cells['row_num'],
                    idx,
                    notify: false,
                  );
                }
              }
            },
            onSelected: (event) {
              if (event.row == null) return;
              final rowNum = event.row!.cells['row_num']?.value;
              final match = rowList
                  .where((r) => '${r.fileRow}' == rowNum.toString())
                  .firstOrNull;
              if (match != null) widget.store.selectRow(match.id);
            },
            mode: PlutoGridMode.selectWithOneTap,
            configuration: PlutoGridConfiguration(
              style: PlutoGridStyleConfig(
                // Chrome. PlutoGrid renders the column header strip with
                // `gridBackgroundColor`, so to match the OutputPanel header
                // (which uses `t.panelBg`) we set the grid background to
                // panelBg and override row colours back to surfaceBg below.
                // Net effect: header strip + filter row above it both sit on
                // panelBg; data rows sit on surfaceBg.
                gridBackgroundColor: t.panelBg,
                rowColor: t.surfaceBg,
                oddRowColor: t.surfaceBg,
                evenRowColor: t.surfaceBg,
                gridBorderColor: t.borderColor,
                borderColor: t.borderColor,
                // Selected row tint — subtle bg only, no accent outline.
                activatedColor: t.selectionBg,
                activatedBorderColor: Colors.transparent,
                // Columns header + cell text — both flow through
                // BxpText.body so any change to the central typography
                // scheme (font, size scale, letter spacing) propagates
                // straight into PlutoGrid without further wiring.
                columnTextStyle: BxpText.body(
                  context,
                  color: t.textSubtle,
                  size: BxpSize.sm,
                  weight: BxpWeight.medium,
                ),
                cellTextStyle: BxpText.body(
                  context,
                  color: t.textPrimary,
                  size: BxpSize.md,
                ),
                // Row height: tighter than Pluto default so the list is dense.
                rowHeight: 28,
                columnHeight: 30,
                // Show vertical column + cell separators so rows-in and
                // rows-out have the same gridded look. Previously verticals
                // were off, which made the rows-in panel feel "softer" than
                // its neighbour despite both being tabular data.
                enableColumnBorderVertical: true,
                enableCellBorderVertical: true,
                gridBorderRadius: BorderRadius.zero,
                cellColorInEditState: t.surfaceBg,
                cellColorInReadOnlyState: t.surfaceBg,
              ),
              scrollbar: const PlutoGridScrollbarConfig(
                isAlwaysShown: false,
                scrollbarThickness: 0,
                scrollbarThicknessWhileDragging: 0,
                hoverWidth: 0,
                onlyDraggingThumb: true,
                scrollBarColor: Colors.transparent,
                scrollBarTrackColor: Colors.transparent,
              ),
            ),
          ),
                    ),  // MediaQuery (reset padding for PlutoGrid)
            ),
          ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Sticky filter row above the column headers — one input per column,
/// case-insensitive substring match.
class _FilterRow extends StatelessWidget {
  final List<String> headers;
  final Map<String, String> filters;
  final Map<String, double> widths;
  final void Function(String header, String value) onChanged;
  final VoidCallback? onFocus;
  const _FilterRow({
    required this.headers,
    required this.filters,
    required this.widths,
    required this.onChanged,
    this.onFocus,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    // No horizontal padding on the Container: the parent gives us
    // exactly `44 + 28 + 150*N` width and the Row inside expects the
    // same. The 8 px that the previous `horizontal: 4` padding ate
    // was triggering a RenderFlex overflow on the right side of the
    // last filter cell. Vertical padding stays — it only affects
    // height, which the parent doesn't constrain.
    return Container(
      decoration: BoxDecoration(
        color: t.panelBg,
        border: Border(bottom: BorderSide(color: t.borderColor)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          // Two leading spacer cells matching the # and status columns
          // in the grid, so filter inputs align with their data columns.
          const SizedBox(width: 44),
          const SizedBox(width: 28),
          for (final h in headers)
            SizedBox(
              width: widths[h] ?? 150.0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _FilterCell(
                  // Keyed by header so the controller persists across
                  // rebuilds for the same column. Without a stable key,
                  // every keystroke would create a fresh controller and
                  // the cursor would jump to the end after each char.
                  key: ValueKey('filter::$h'),
                  initial: filters[h] ?? '',
                  onChanged: (v) => onChanged(h, v),
                  onFocus: onFocus,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterCell extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onChanged;
  // Fires when the input first gains focus, used by RowList to clear
  // PlutoGrid's lingering current-cell highlight so the grid doesn't
  // look like it still owns input focus.
  final VoidCallback? onFocus;
  const _FilterCell({
    super.key,
    required this.initial,
    required this.onChanged,
    this.onFocus,
  });

  @override
  State<_FilterCell> createState() => _FilterCellState();
}

class _FilterCellState extends State<_FilterCell> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
    _focus = FocusNode();
    _focus.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (_focus.hasFocus) widget.onFocus?.call();
  }

  @override
  void dispose() {
    _focus.removeListener(_handleFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      onChanged: widget.onChanged,
      style: BxpText.body(context, color: t.textPrimary, size: BxpSize.sm),
      cursorColor: t.textPrimary,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'filter',
        hintStyle: BxpText.body(
          context,
          color: t.inputPlaceholder,
          size: BxpSize.sm,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        filled: true,
        fillColor: t.inputFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: t.inputBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: t.inputBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: t.inputBorderFocused),
        ),
      ),
    );
  }
}

/// Type-aware text renderer used by RowList. Empty values are hidden
/// (no `""` placeholder) per user preference. Colour comes from the
/// active theme's `value*` tokens — light theme renders strings as
/// near-black while dark renders them as warm-tan (CE9178).
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
      overflow: TextOverflow.ellipsis,
    );
  }
}
