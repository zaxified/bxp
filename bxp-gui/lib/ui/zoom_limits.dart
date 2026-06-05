import 'dart:ui';

// Logical content size that the UI is currently designed for. Reflects the
// largest hard-coded element (OpenDialog 820×500) plus headroom for the
// surrounding chrome. The reactive overflow guard in main.dart catches any
// future widget that exceeds these dimensions, so this constant is a hint
// for the proactive pre-check, not a single point of correctness.
//
// Distinct from the OS window minimum, which is enforced by the native
// runners (Linux/Windows pin 1280×800 via `linux/runner/my_application.cc`
// + `windows/runner/main.cpp`; macOS sets a 1024×768 content-min in
// `macos/Runner/MainFlutterWindow.swift`): this is the rendering target
// for the zoom math — when the physical window shrinks toward the logical
// box (1024×768) we cap zoom so the frame still fits without overflow.
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
