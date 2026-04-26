import 'dart:ui';

// Logical content size that the UI is currently designed for. Reflects the
// largest hard-coded element (OpenDialog 820×500) plus headroom for the
// surrounding chrome. The reactive overflow guard in main.dart catches any
// future widget that exceeds these dimensions, so this constant is a hint
// for the proactive pre-check, not a single point of correctness.
const double kLogicalMinWidth = 1024.0;
const double kLogicalMinHeight = 768.0;

const double kMinZoom = 0.5;
const double kMaxZoom = 3.0;
const double kZoomStep = 0.1;

double maxSafeZoom(Size windowSize) {
  final w = windowSize.width / kLogicalMinWidth;
  final h = windowSize.height / kLogicalMinHeight;
  final ratio = w < h ? w : h;
  if (ratio < kMinZoom) return kMinZoom;
  if (ratio > kMaxZoom) return kMaxZoom;
  return ratio;
}
