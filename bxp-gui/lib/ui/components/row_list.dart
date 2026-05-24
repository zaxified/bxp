import 'dart:async';
import 'dart:math' as math;

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
    // bxp-cli treats var/rule eval failures as WARNINGS (stats.warnings,
    // --debug log) — same severity surfaces here. Field name `hasError`
    // is legacy; semantics is "warning".
    if (row.hasError) return 'warning';
    // `outputs` stays empty until drill-down loads, so we infer "written"
    // from the `btraceAction` populated by the `output_row` frame.
    // 1:N templates (single source producing >1 output) get a distinct
    // glyph so the user can spot the expansion without drill-down.
    final outCount = row.outputIdxs.isNotEmpty
        ? row.outputIdxs.length
        : row.outputs.length;
    if (outCount > 1) return 'written-multi';
    if (row.outputs.isNotEmpty) return 'written';
    if (row.btraceAction != null) return 'written';
    // Split the historical catch-all `filtered` into three semantic
    // sub-statuses based on the `filteredReason` payload carried by the
    // `filtered_row` btrace frame (synthetic in two of the three cases).
    final reason = row.filteredReason;
    if (reason == 'date_filter_from_filename') return 'filtered';
    if (reason == 'rule_skip') return 'skipped';
    if (reason == 'no_rule_match') return 'unmatched';
    if (reason != null) return 'filtered'; // unknown reason → safe fallback
    return 'unmatched';
  }

  String _statusIcon(String status) {
    switch (status) {
      case 'written':
        return '▶';
      case 'written-multi':
        return '⏩';
      case 'filtered':
        return '▼';
      case 'skipped':
        return '⊘';
      case 'unmatched':
        return '?';
      case 'warning':
        return '⚠';
      default:
        return '·';
    }
  }

  String _statusTooltip(String status) {
    switch (status) {
      case 'written':
        return 'Written — row produced one output';
      case 'written-multi':
        return 'Written — row produced multiple outputs (1:N expansion)';
      case 'filtered':
        return 'Filtered — outside filename date range';
      case 'skipped':
        return 'Skipped — matched a rule with empty rows '
            '(often a pre_pass lookup source)';
      case 'unmatched':
        return 'Unmatched — no rule\'s `when` evaluated truthy';
      case 'warning':
        return 'Warning — variable expression failed; row processed '
            'with empty substitute (bxp-cli severity: warning)';
      default:
        return '';
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
      key: ValueKey(
          'rowlist::$fileId::${file.headers.join("|")}::${file.populateGen}'),
      fileId: fileId,
      file: file,
      model: model,
      store: store,
      rowStatus: _rowStatus,
      statusIcon: _statusIcon,
      statusTooltip: _statusTooltip,
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
  final String Function(String) statusTooltip;

  const _RowListInner({
    super.key,
    required this.fileId,
    required this.file,
    required this.model,
    required this.store,
    required this.rowStatus,
    required this.statusIcon,
    required this.statusTooltip,
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

  /// Subset of `widget.file.rowIds` currently materialised into
  /// PlutoRows. For eager (small) files this equals `widget.file.rowIds`
  /// after activation; for lazy (large) files it starts at the first
  /// [kLazyInitialRows] and grows in batches of [kLazyExpandBatch] as
  /// the user scrolls near the end. Populated in [_resyncVisibleRows];
  /// the build method reads it to construct PlutoRows.
  List<String> _visibleRowIds = const [];

  /// True when [_visibleRowIds] is shorter than `widget.file.rowIds` —
  /// i.e. there are more rows on disk we could materialise. Used by the
  /// scroll listener to decide whether to expand.
  bool _hasMoreToShow = false;

  /// Currently-running filter scan key (for large files). Each launch
  /// stamps a fresh key; the scan's `isAborted` closure compares against
  /// this so a newer keystroke supersedes an older one without races.
  Object? _filterScanKey;
  /// Latest progress tick from a running filter scan, surfaced in the
  /// spinner overlay. `null` when no scan is in flight.
  ({int matched, int scanned})? _filterScanProgress;
  /// Resume cursor for paginated filter scans. Equals `file.rowIds.length`
  /// when the scan walked the file end-to-end. Used by `_expandVisibleWindow`
  /// to continue a filter scan past its first 1000-match page.
  int _filterScanCursor = 0;
  /// True while the active visible set is a filter-scan match list (as
  /// opposed to the unfiltered initial window). Drives the scroll-
  /// expansion branch: "scan next page" vs "append next file rows".
  bool _filterScanActive = false;
  /// Guards against re-entrant scroll-expansion triggers while the
  /// previous batch is still being populated (or the debug delay is
  /// running). Scroll fires can repeat rapidly; without this they would
  /// schedule N parallel appends that all race on PlutoGrid state.
  bool _expandInFlight = false;

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
    _resyncVisibleRows();
    // First-row auto-select used to live here as a postFrameCallback,
    // but it raced the activation pipeline: clicking a file while a big
    // sibling file was still streaming would auto-select r0 before the
    // RAF was open, kicking off `ensureDetailLoaded` against an empty
    // `row.fields`. Auto-select for the click path now lives in
    // `TraceStore.selectFile` (deferred to after `_activateFile`); the
    // initial-load streams set `selectedRowId` themselves before RowList
    // mounts, so no auto-select is needed here.
  }

  /// Seed [_visibleRowIds] from the file's eager/lazy mode. Eager files
  /// show all rows; lazy files show only the first [kLazyInitialRows].
  /// Called once at init and again after a filter scan completes.
  void _resyncVisibleRows() {
    final rowIds = widget.file.rowIds;
    if (widget.file.sourceLoadEager || rowIds.length <= kLazyInitialRows) {
      _visibleRowIds = rowIds;
      _hasMoreToShow = false;
    } else {
      _visibleRowIds = rowIds.take(kLazyInitialRows).toList();
      _hasMoreToShow = true;
    }
    _filterScanActive = false;
    _filterScanCursor = 0;
    _publishDisplayedCount();
  }

  /// Push the currently-displayed row count up to the store so the
  /// PanelHeader above us can render a "(total) — N filtered" suffix.
  /// For eager files we read PlutoGrid's filtered view (refRows.length)
  /// because the stock filter narrows it imperatively; for lazy files
  /// the visible-window list is authoritative.
  void _publishDisplayedCount() {
    final count = widget.file.sourceLoadEager
        ? (_stateManager?.refRows.length ?? _visibleRowIds.length)
        : _visibleRowIds.length;
    widget.store.setRowsInDisplayed(count);
  }

  /// Resolve the display value for one source-CSV cell. While the file
  /// is being activated (RAF open + initial populate) `row.fields` is
  /// still empty — render `…` so the user sees a "loading" placeholder
  /// rather than a blank cell. The widget key folds in `populateGen` so
  /// the rebuild triggered when populate finishes remounts PlutoGrid
  /// and re-creates the PlutoRows from real values. Synthetic rows
  /// (`sourceLocator < 0`, e.g. summary placeholders) always render
  /// blank — they have no source row to load.
  static String _cellValueFor(RowModel row, int i) {
    if (row.fieldsPopulated) {
      return i < row.fields.length ? row.fields[i] : '';
    }
    return row.sourceLocator >= 0 ? '…' : '';
  }

  /// Append the next [kLazyExpandBatch] rowIds to [_visibleRowIds] and
  /// trigger a populate sweep so the new rows arrive with content. Adds
  /// the new PlutoRows directly to the stateManager (PlutoGrid does NOT
  /// react to widget.rows changes after mount — only to its imperative
  /// API).
  ///
  /// Two branches:
  ///   * Filter scan paginated (`_filterScanActive == true`) — fetch
  ///     the next [kLazyExpandBatch] matches from the resume cursor and
  ///     append.
  ///   * Otherwise — append the next slice of `file.rowIds`.
  ///
  /// No-op when no more rows to show or while a filter scan is already
  /// in flight.
  void _expandVisibleWindow() {
    if (!_hasMoreToShow) return;
    if (_filterScanKey != null) return;
    if (_expandInFlight) return;
    if (_filterScanActive) {
      _expandInFlight = true;
      _continueLargeFilterScan().whenComplete(() {
        if (mounted) _expandInFlight = false;
      });
      return;
    }
    unawaited(_expandUnfilteredWindow());
  }

  Future<void> _expandUnfilteredWindow() async {
    _expandInFlight = true;
    try {
      if (kLazyBatchDebugDelayMs > 0) {
        await Future<void>.delayed(
            const Duration(milliseconds: kLazyBatchDebugDelayMs));
        if (!mounted) return;
      }
      final sm = _stateManager;
      if (sm == null) return;
    final rowIds = widget.file.rowIds;
    final start = _visibleRowIds.length;
    if (start >= rowIds.length) {
      _hasMoreToShow = false;
      return;
    }
    final end = (start + kLazyExpandBatch).clamp(0, rowIds.length);
    widget.store.ensureRowsPopulated(widget.fileId, start, end);
    final newIds = rowIds.sublist(start, end);
    final headers = widget.file.headers;
    final newPlutoRows = <PlutoRow>[];
    for (final id in newIds) {
      final row = widget.model.rows[id];
      if (row == null) continue;
      final status = widget.rowStatus(row);
      String statusValue = status;
      if (status == 'warning' && row.warningDetails.isNotEmpty) {
        statusValue =
            'warning|${row.warningDetails.length}|${row.warningDetails.first}';
      }
      final cells = <String, PlutoCell>{
        'row_num': PlutoCell(value: '${row.fileRow}'),
        'status': PlutoCell(value: statusValue),
      };
      for (int i = 0; i < headers.length; i++) {
        cells[headers[i]] = PlutoCell(
          value: _cellValueFor(row, i),
        );
      }
      newPlutoRows.add(PlutoRow(cells: cells));
    }
    if (newPlutoRows.isNotEmpty) {
      sm.appendRows(newPlutoRows);
    }
    if (!mounted) return;
    setState(() {
      _visibleRowIds = rowIds.sublist(0, end);
      _hasMoreToShow = end < rowIds.length;
    });
    _publishDisplayedCount();
    } finally {
      _expandInFlight = false;
    }
  }

  /// Scroll listener on PlutoGrid's body vertical controller. When the
  /// user scrolls within `kLazyExpandBatch * rowHeight` of the end, kick
  /// an expand. Multiple firings are idempotent — `_expandVisibleWindow`
  /// short-circuits on no-more-rows.
  void _onBodyScroll() {
    if (!_hasMoreToShow) return;
    final ctrl = _bodyVertCtrl;
    if (ctrl == null || !ctrl.hasClients) return;
    const rowHeight = 28.0;
    final threshold = kLazyExpandBatch * rowHeight;
    if (ctrl.position.maxScrollExtent - ctrl.position.pixels < threshold) {
      _expandVisibleWindow();
    }
  }

  /// Kick off a paginated filter scan. Cancels any previous scan by
  /// stamping a fresh [_filterScanKey] — the older scan's `isAborted`
  /// closure detects the mismatch and bails. Returns just the first
  /// [kLazyExpandBatch] matches; further pages are fetched lazily by
  /// `_expandVisibleWindow` when the user scrolls past the displayed
  /// set.
  Future<void> _startLargeFilterScan() async {
    final scanKey = Object();
    setState(() {
      _filterScanKey = scanKey;
      _filterScanProgress = (matched: 0, scanned: 0);
      _filterScanCursor = 0;
      _filterScanActive = true;
    });
    final result = await widget.store.filterScanLargeFile(
      fileId: widget.fileId,
      filters: _filters,
      fromIdx: 0,
      maxMatches: kLazyExpandBatch,
      onProgress: (m, s) {
        if (!mounted || _filterScanKey != scanKey) return;
        setState(() => _filterScanProgress = (matched: m, scanned: s));
      },
      isAborted: () => !mounted || _filterScanKey != scanKey,
    );
    if (!mounted || _filterScanKey != scanKey) return;
    // PlutoGrid doesn't react to `widget.rows` changes after mount — we
    // must replace its internal refRows via the state manager. Clear
    // the existing rows, build PlutoRows for every match, append.
    final sm = _stateManager;
    if (sm != null) {
      _replacePlutoRows(sm, result.matched);
    }
    setState(() {
      _filterScanKey = null;
      _filterScanProgress = null;
      _visibleRowIds = List<String>.of(result.matched);
      _filterScanCursor = result.nextFromIdx;
      _hasMoreToShow = !result.done;
    });
    _publishDisplayedCount();
  }

  /// Continue an active filter scan past its first page. Called from
  /// the scroll-expansion path when the user nears the bottom of the
  /// match list. Appends to (rather than replaces) the visible set.
  Future<void> _continueLargeFilterScan() async {
    if (!_filterScanActive) return;
    if (!_hasMoreToShow) return;
    if (_filterScanKey != null) return; // already running
    final scanKey = Object();
    // Reset progress to the cumulative starting point so the spinner
    // shows continuity instead of jumping back to (0, 0) between pages.
    final priorMatches = _visibleRowIds.length;
    final priorCursor = _filterScanCursor;
    setState(() {
      _filterScanKey = scanKey;
      _filterScanProgress =
          (matched: priorMatches, scanned: priorCursor);
    });
    final result = await widget.store.filterScanLargeFile(
      fileId: widget.fileId,
      filters: _filters,
      fromIdx: _filterScanCursor,
      maxMatches: kLazyExpandBatch,
      onProgress: (m, s) {
        if (!mounted || _filterScanKey != scanKey) return;
        setState(() => _filterScanProgress =
            (matched: priorMatches + m, scanned: s));
      },
      isAborted: () => !mounted || _filterScanKey != scanKey,
    );
    if (!mounted || _filterScanKey != scanKey) return;
    // Append the new matches to the existing PlutoRow list.
    final sm = _stateManager;
    if (sm != null && result.matched.isNotEmpty) {
      _appendPlutoRows(sm, result.matched);
    }
    setState(() {
      _filterScanKey = null;
      _filterScanProgress = null;
      _visibleRowIds.addAll(result.matched);
      _filterScanCursor = result.nextFromIdx;
      _hasMoreToShow = !result.done;
    });
    _publishDisplayedCount();
  }

  /// Build PlutoRows for `rowIds` and append them to the live grid via
  /// the state manager (same logic as `_expandVisibleWindow` minus the
  /// `_visibleRowIds` bookkeeping). Used by `_continueLargeFilterScan`.
  void _appendPlutoRows(PlutoGridStateManager sm, List<String> rowIds) {
    final headers = widget.file.headers;
    final fresh = <PlutoRow>[];
    for (final id in rowIds) {
      final row = widget.model.rows[id];
      if (row == null) continue;
      final status = widget.rowStatus(row);
      String statusValue = status;
      if (status == 'warning' && row.warningDetails.isNotEmpty) {
        statusValue =
            'warning|${row.warningDetails.length}|${row.warningDetails.first}';
      }
      final cells = <String, PlutoCell>{
        'row_num': PlutoCell(value: '${row.fileRow}'),
        'status': PlutoCell(value: statusValue),
      };
      for (int i = 0; i < headers.length; i++) {
        cells[headers[i]] = PlutoCell(
          value: _cellValueFor(row, i),
        );
      }
      fresh.add(PlutoRow(cells: cells));
    }
    if (fresh.isNotEmpty) sm.appendRows(fresh);
  }

  /// Rebuild PlutoGrid's refRows from the given list of rowIds. Used by
  /// the filter-scan completion path (and the abort path back to the
  /// initial window) — both need to replace the entire grid contents
  /// without remounting.
  void _replacePlutoRows(PlutoGridStateManager sm, List<String> rowIds) {
    final headers = widget.file.headers;
    final fresh = <PlutoRow>[];
    for (final id in rowIds) {
      final row = widget.model.rows[id];
      if (row == null) continue;
      final status = widget.rowStatus(row);
      String statusValue = status;
      if (status == 'warning' && row.warningDetails.isNotEmpty) {
        statusValue =
            'warning|${row.warningDetails.length}|${row.warningDetails.first}';
      }
      final cells = <String, PlutoCell>{
        'row_num': PlutoCell(value: '${row.fileRow}'),
        'status': PlutoCell(value: statusValue),
      };
      for (int i = 0; i < headers.length; i++) {
        cells[headers[i]] = PlutoCell(
          value: _cellValueFor(row, i),
        );
      }
      fresh.add(PlutoRow(cells: cells));
    }
    sm.removeRows(sm.refRows.toList());
    if (fresh.isNotEmpty) sm.appendRows(fresh);
  }

  /// Cancel any in-flight scan and restore the unfiltered initial
  /// window. Called when all filters are cleared.
  void _abortLargeFilterScan() {
    setState(() {
      _filterScanKey = null;
      _filterScanProgress = null;
      _resyncVisibleRows();
    });
    final sm = _stateManager;
    if (sm != null) _replacePlutoRows(sm, _visibleRowIds);
    _publishDisplayedCount();
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

  /// Apply current `_filters` map to the grid. Two code paths:
  ///
  /// • Eager (small) file — every row's content is already populated
  ///   in `RowModel.fields` and mirrored into PlutoCells, so PlutoGrid's
  ///   built-in `setFilter` does the work without any disk read.
  /// • Lazy (large) file — most rows have empty cells (their bytes
  ///   are still on disk). Built-in filter would miss matches in the
  ///   unloaded rows entirely. We bypass it and run a sequential scan
  ///   via [TraceStore.filterScanLargeFile] which populates rows as it
  ///   walks, yielding to the event loop so the UI stays responsive.
  void _applyFilter() {
    final sm = _stateManager;
    final headers = widget.file.headers;
    final allEmpty = _filters.values.every((v) => v.isEmpty);

    if (widget.file.sourceLoadEager) {
      if (sm == null) return;
      if (allEmpty) {
        sm.setFilter(null);
        _publishDisplayedCount();
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
      _publishDisplayedCount();
      return;
    }

    // Lazy file path — scan via the store, replace the materialised
    // window with the result set when done.
    if (allEmpty) {
      _abortLargeFilterScan();
      return;
    }
    // Fire-and-forget. Subsequent keystrokes stamp a fresh
    // `_filterScanKey` and the older scan aborts.
    unawaited(_startLargeFilterScan());
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
    // For eager (small) files this is identical to `widget.file.rowIds`.
    // For lazy (large) files this is the materialised window — first
    // [kLazyInitialRows] initially, growing in batches as the user
    // scrolls or contracted to a filter-scan match list. PlutoGrid
    // receives only this subset.
    final rowList = _visibleRowIds
        .map((id) => widget.model.rows[id])
        .whereType<RowModel>()
        .toList();

    // Width the row-number column for the largest `fileRow` we expect to
    // render. `file.rowIds.length` is the count of TRACED rows; the
    // physical CSV row number can be even larger when bxp-cli skipped
    // input rows pre-rule (header, filtered date ranges). For both cases
    // the digit-count of `rowIds.length` is a close upper bound — pick
    // it and convert to pixels with a small base + per-digit allowance.
    final rowNumDigits = math.max(
      2,
      widget.file.rowIds.length.toString().length,
    );
    final rowNumWidth = 22.0 + 8.0 * rowNumDigits;
    final columns = <PlutoColumn>[
      PlutoColumn(
        title: '#',
        field: 'row_num',
        type: PlutoColumnType.text(),
        width: rowNumWidth,
        minWidth: rowNumWidth,
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
        // Icon-only status column — the glyph itself is small, but a hover
        // tooltip explains what each one means (▶ written, ▼ filtered,
        // ⊘ skipped, ? unmatched, ✕ error).
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
          // Cell value carries the status NAME (e.g. "written") — or for
          // warning rows a `warning|<count>|<first-detail>` triple. We
          // resolve glyph + colour from the status name and append the
          // detail string to the tooltip when present.
          final raw = ctx.cell.value.toString();
          final parts = raw.split('|');
          final status = parts[0];
          final glyph = widget.statusIcon(status);
          var tooltip = widget.statusTooltip(status);
          if (status == 'warning' && parts.length >= 3) {
            final count = int.tryParse(parts[1]) ?? 0;
            final detail = parts.sublist(2).join('|');
            tooltip = '$tooltip\n\n'
                '$count warning${count == 1 ? "" : "s"} on this row\n'
                '• $detail';
          }
          Color color = t.textMuted;
          if (status == 'written' || status == 'written-multi') {
            color = t.valueOk;
          }
          if (status == 'filtered' || status == 'skipped' ||
              status == 'warning') {
            color = t.valueWarn;
          }
          return Tooltip(
            message: tooltip,
            waitDuration: const Duration(milliseconds: 400),
            child: Text(
              glyph,
              style: BxpText.body(context, color: color, size: BxpSize.md),
            ),
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
      // Cell value encodes status NAME + (when a warning) the count and
      // first detail string so the renderer can build a hover tooltip
      // that explains *why* the row was flagged without a row lookup.
      // Format: `<status>` or `<status>|<count>|<first-detail>`.
      String statusValue = status;
      if (status == 'warning' && row.warningDetails.isNotEmpty) {
        statusValue =
            'warning|${row.warningDetails.length}|${row.warningDetails.first}';
      }
      final cells = <String, PlutoCell>{
        'row_num': PlutoCell(value: '${row.fileRow}'),
        // Store the status NAME, not the glyph — the renderer resolves
        // glyph + colour + tooltip together so they can't drift apart.
        'status': PlutoCell(value: statusValue),
      };
      for (int i = 0; i < headers.length; i++) {
        cells[headers[i]] = PlutoCell(
          value: _cellValueFor(row, i),
        );
      }
      return PlutoRow(cells: cells);
    }).toList();

    // Total width matches the actual rendered grid columns. We mirror
    // _colWidths (populated from stateManager after autoFitColumn and
    // again on any user resize) so each filter cell sits flush with
    // its column. Falls back to 150 per column on first paint, before
    // onLoaded has had a chance to publish real widths.
    // row_num column was hard-coded to 44 px before — now it grows by
    // digit count of `rowIds.length` (rowNumWidth), so the filter row's
    // leading spacer has to follow that. status column stays 28 px.
    double filterContentWidth = rowNumWidth + 28.0;
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
              rowNumWidth: rowNumWidth,
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
          child: Stack(
            children: [
              Positioned.fill(
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
              // Scroll-driven lazy expansion for large files: when the user
              // nears the bottom of the materialised window, append the
              // next batch of rowIds + populate their fields via the active
              // RAF. No-op for eager (small) files since `_hasMoreToShow`
              // stays false there.
              _bodyVertCtrl?.addListener(_onBodyScroll);
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
              if (_filterScanProgress != null)
                Positioned(
                  top: 8,
                  right: 8,
                  child: _FilterScanSpinner(
                    progress: _filterScanProgress!,
                    total: widget.file.rowIds.length,
                    onCancel: _abortLargeFilterScan,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Progress + cancel button shown while a large-file filter scan is in
/// flight. Floats over the top-right of the rows grid; non-blocking so
/// the user can still scroll the partial results landing underneath.
class _FilterScanSpinner extends StatelessWidget {
  final ({int matched, int scanned}) progress;
  final int total;
  final VoidCallback onCancel;
  const _FilterScanSpinner({
    required this.progress,
    required this.total,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final pct = total == 0
        ? 0
        : ((progress.scanned / total) * 100).clamp(0, 100).round();
    return Material(
      color: t.panelBg.withValues(alpha: 0.92),
      elevation: 2,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: t.textPrimary,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${progress.matched} matches · '
              'scanned ${progress.scanned} of $total ($pct%)',
              style: BxpText.body(context, size: BxpSize.sm),
            ),
            const SizedBox(width: 10),
            InkWell(
              onTap: onCancel,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  'Stop',
                  style: BxpText.body(
                    context,
                    size: BxpSize.sm,
                    color: t.valueWarn,
                    weight: BxpWeight.medium,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sticky filter row above the column headers — one input per column,
/// case-insensitive substring match.
class _FilterRow extends StatelessWidget {
  final List<String> headers;
  final Map<String, String> filters;
  final Map<String, double> widths;
  final double rowNumWidth;
  final void Function(String header, String value) onChanged;
  final VoidCallback? onFocus;
  const _FilterRow({
    required this.headers,
    required this.filters,
    required this.widths,
    required this.rowNumWidth,
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
          SizedBox(width: rowNumWidth),
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
