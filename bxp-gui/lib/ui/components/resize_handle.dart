import 'package:flutter/material.dart';
import '../theme/bxp_theme.dart';

/// Thin draggable splitter with hover + active visual feedback.
///
/// The handle is a 4 px line that brightens when the cursor enters and
/// brightens further during an active drag. Without this feedback the
/// user can't tell which slim border is interactive.
///
/// One widget covers both axes — `Axis.horizontal` is for column-style
/// (left/right) resizers, `Axis.vertical` for row-style (top/bottom).
/// `onDelta` receives signed pixel deltas per drag tick; the parent
/// owns the actual width/height state and clamping.
class ResizeHandle extends StatefulWidget {
  final Axis axis;
  final ValueChanged<double> onDelta;
  final double thickness;

  const ResizeHandle({
    super.key,
    required this.axis,
    required this.onDelta,
    this.thickness = 4.0,
  });

  @override
  State<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<ResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;

    // Three-tier brightness on top of the panel background. Picking
    // colours from the theme tokens (rather than hard-coded slate
    // values) keeps the feedback in scale with whatever preset is
    // active — on amoled the highlight stays subtle, on slate it
    // matches the original Tailwind hover intensity.
    final Color bg;
    if (_dragging) {
      bg = t.textSubtle.withValues(alpha: 0.5);
    } else if (_hovered) {
      bg = t.textMuted.withValues(alpha: 0.35);
    } else {
      bg = t.borderColor;
    }

    final cursor = widget.axis == Axis.horizontal
        ? SystemMouseCursors.resizeColumn
        : SystemMouseCursors.resizeRow;

    return MouseRegion(
      cursor: cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _dragging = true),
        onPanEnd: (_) => setState(() => _dragging = false),
        onPanCancel: () => setState(() => _dragging = false),
        onPanUpdate: (d) {
          widget.onDelta(
              widget.axis == Axis.horizontal ? d.delta.dx : d.delta.dy);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: widget.axis == Axis.horizontal ? widget.thickness : null,
          height: widget.axis == Axis.vertical ? widget.thickness : null,
          color: bg,
        ),
      ),
    );
  }
}
