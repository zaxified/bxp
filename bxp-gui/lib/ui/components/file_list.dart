import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';

/// Single row in the file list. Manages its own hover state so only the
/// hovered row repaints — lifting hover into the parent would cause the
/// whole FileList to rebuild on every mouse move.
class _FileRow extends StatefulWidget {
  final bool active;
  final Color activeBg;
  final Color hoverBg;
  final Color borderColor;
  final VoidCallback onTap;
  final Widget child;

  const _FileRow({
    required this.active,
    required this.activeBg,
    required this.hoverBg,
    required this.borderColor,
    required this.onTap,
    required this.child,
  });

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.active
        ? widget.activeBg
        : (_hovered ? widget.hoverBg : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            border: Border(bottom: BorderSide(color: widget.borderColor)),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class FileList extends StatefulWidget {
  const FileList({super.key});

  @override
  State<FileList> createState() => _FileListState();
}

class _FileListState extends State<FileList> {
  // Separate controllers so the vertical and horizontal Scrollbars
  // don't fight over the same ScrollPosition.
  final ScrollController _vCtrl = ScrollController();
  final ScrollController _hCtrl = ScrollController();

  @override
  void dispose() {
    _vCtrl.dispose();
    _hCtrl.dispose();
    super.dispose();
  }

  /// Extract the filename from an absolute path. Handles both POSIX `/`
  /// and Windows `\` separators — bxp-cli builds paths via
  /// `std.fs.path.join`, which on Windows yields backslash-separated paths.
  String _basename(String path) {
    final i = path.lastIndexOf(RegExp(r'[\\/]'));
    return i >= 0 ? path.substring(i + 1) : path;
  }

  @override
  Widget build(BuildContext context) {
    // Listen to BOTH the main store (for selection / theme / config events)
    // and `store.fileGen` (bumped on every `file_start` during a stream so
    // FileList grows live without main `notifyListeners`, which would
    // otherwise cascade into a quadratic PlutoGrid rebuild in RowList).
    final store = context.watch<TraceStore>();
    return ListenableBuilder(
      listenable: store.fileGen,
      builder: (context, _) => _buildBody(context, store),
    );
  }

  Widget _buildBody(BuildContext context, TraceStore store) {
    final model = store.traceModel;
    final t = context.bxpTheme;

    if (model == null || model.fileOrder.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12.0),
        child: Text('No files yet. Click Run Dry-Run.',
            style: BxpText.italic(context)),
      );
    }

    final borderColor = t.borderColor;
    final activeBg = t.selectionBg;
    final hoverBg = t.withHover(t.panelBg);

    // Build all rows as a Column inside an IntrinsicWidth so each row
    // sizes to its widest line (no ellipsis), and the column itself
    // takes the width of the widest row. Nested vert+horiz scroll
    // views give scrollbars on both axes when the content overflows.
    // ListView.builder was virtualized but couldn't size to content
    // width; FileList typically holds <100 entries so a non-virtualized
    // Column is fine.
    return Scrollbar(
      controller: _vCtrl,
      thumbVisibility: true,
      child: Scrollbar(
        controller: _hCtrl,
        thumbVisibility: true,
        notificationPredicate: (n) => n.depth == 1,
        child: SingleChildScrollView(
          controller: _vCtrl,
          child: SingleChildScrollView(
            controller: _hCtrl,
            scrollDirection: Axis.horizontal,
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: model.fileOrder.map((id) {
                  final file = model.files[id];
                  if (file == null) return const SizedBox.shrink();

                  final name = _basename(file.path);
                  final written = file.stats?['written'];
                  // bxp-cli severity: file_end.errors (input_schema expr
                  // failures) + file_end.warnings (other per-file
                  // warnings) both flow through `stats.warnings` /
                  // exit 2 on the producer side — surface them as a
                  // single GUI "warn" badge.
                  final warnings =
                      ((file.stats?['warnings'] as int?) ?? 0) +
                          ((file.stats?['errors'] as int?) ?? 0);
                  // Once file_end has populated stats, prefer its authoritative
                  // source-row count (matches between NDJSON and btrace modes,
                  // even when one source row produces N outputs). During
                  // streaming fall back to the running rowIds length.
                  final rows = file.stats?['rows'] ?? file.rowIds.length;
                  final active = id == store.selectedFileId;

                  // Active row text uses theme's selectionText
                  // (emerald-derived on dark, near-black on light);
                  // idle rows use textPrimary so the row name stays
                  // the highest-contrast token.
                  final textColor =
                      active ? t.selectionText : t.textPrimary;

                  return _FileRow(
                    active: active,
                    activeBg: activeBg,
                    hoverBg: hoverBg,
                    borderColor: borderColor,
                    onTap: () => store.selectFile(id),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          softWrap: false,
                          maxLines: 1,
                          style: BxpText.body(context,
                              color: textColor, weight: BxpWeight.medium),
                        ),
                        const SizedBox(height: 2),
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                  text: '${file.template} · $rows rows'),
                              if (written != null)
                                TextSpan(text: ' · $written written'),
                              if (warnings > 0)
                                TextSpan(
                                    text: ' · $warnings warn',
                                    style: TextStyle(color: t.valueWarn)),
                              // Pre-pass badge: surfaces the count of
                              // LOOKUP table entries gathered before
                              // the main row loop.
                              if (file.prepass.isNotEmpty)
                                TextSpan(
                                    text:
                                        ' · ${file.prepass.length} prepass',
                                    style:
                                        TextStyle(color: t.codeVariable)),
                            ],
                          ),
                          maxLines: 1,
                          softWrap: false,
                          style: BxpText.muted(context),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
