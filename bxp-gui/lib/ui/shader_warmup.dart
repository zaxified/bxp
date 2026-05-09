import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Pre-compiles the Skia shader programs that BXP's steady-state UI
/// uses, so the (~100-300 ms) compilation cost is paid once at startup
/// instead of as scattered jank during the user's first interactions.
///
/// Wired in [main] via `PaintingBinding.shaderWarmUp = const
/// BxpShaderWarmUp()` BEFORE the binding is initialised — the warm-up
/// is dispatched from `PaintingBinding.initInstances`, which runs as
/// part of the first `WidgetsBinding.instance` construction.
///
/// The exact geometry below is irrelevant — the engine caches by shader
/// program identity, not by the specific draw rect. Targets BXP's
/// observed paint mix:
///
///   - axis-aligned filled and stroked rects (panel chrome, JsonTree
///     cells, PlutoGrid cells, dividers);
///   - shadowed rectangles (tooltips, dialogs, snackbars, autocomplete
///     popup);
///   - antialiased circles and arcs (CircularProgressIndicator on the
///     startup gate, theme-cycle / status badges);
///   - antialiased paths (Material icon vectors);
///   - text runs at small / base / large sizes in regular and semibold
///     weights (every panel header, button label, cell text).
class BxpShaderWarmUp extends ShaderWarmUp {
  const BxpShaderWarmUp();

  @override
  Future<void> warmUpOnCanvas(ui.Canvas canvas) async {
    final fill = Paint()..color = const Color(0xFF202020);
    final stroke = Paint()
      ..color = const Color(0xFF606060)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final aa = Paint()
      ..color = const Color(0xFFC8C8C8)
      ..isAntiAlias = true;
    final shadow = Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

    // Filled and stroked axis-aligned rects.
    canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 14), fill);
    canvas.drawRect(const Rect.fromLTWH(0, 18, 100, 14), stroke);

    // Divider line.
    canvas.drawLine(const Offset(0, 36), const Offset(100, 36), stroke);

    // Drop-shadow + filled rounded rect (dialog/tooltip stack).
    final rrect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(5, 40, 90, 16),
      const Radius.circular(2),
    );
    canvas.drawRRect(rrect, shadow);
    canvas.drawRRect(rrect, fill);

    // Antialiased circle (progress arc, status badge).
    canvas.drawCircle(const Offset(15, 70), 6, aa);

    // Antialiased path (icon vector).
    final icon = Path()
      ..moveTo(45, 64)
      ..lineTo(55, 74)
      ..lineTo(65, 64)
      ..close();
    canvas.drawPath(icon, aa);

    // Text runs — sm regular, base regular, lg semibold. The glyph
    // identity does not matter for shader caching; only the text
    // rendering pipeline does.
    void drawText(String s, double size, FontWeight w, Offset at) {
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(textAlign: TextAlign.left),
      )
        ..pushStyle(ui.TextStyle(
          color: const Color(0xFFE0E0E0),
          fontSize: size,
          fontWeight: w,
        ))
        ..addText(s);
      final p = builder.build()
        ..layout(const ui.ParagraphConstraints(width: 100));
      canvas.drawParagraph(p, at);
      p.dispose();
    }

    drawText('Aa', 11, FontWeight.w400, const Offset(0, 80));
    drawText('Aa', 13, FontWeight.w400, const Offset(30, 80));
    drawText('Aa', 16, FontWeight.w600, const Offset(60, 80));
  }
}
