import 'package:flutter/foundation.dart';

/// Runtime-toggleable knobs used during the Windows freeze investigation.
/// All defaults match the production GUI baseline (everything on, no
/// pointer filtering) so a fresh build behaves the same as v0.2.x.
///
/// The user opens the SettingsInspector via Ctrl+Shift+S; the Debug
/// section there hosts the master "Diagnostic mode" switch (which
/// controls both the floating [CounterOverlay] and the file-backed
/// `DiagnosticLog`) plus per-feature investigation gates. Pointer-event
/// filtering happens in [DebugBinding].
///
/// Singleton because the binding overrides need access from a place
/// (handlePointerEvent) that doesn't have a Flutter BuildContext, and
/// because there's only ever one set of debug settings per process.
class DebugSettings extends ChangeNotifier {
  static final DebugSettings instance = DebugSettings._();
  DebugSettings._();

  // ── Diagnostic mode (overlay + trace) ────────────────────────────────

  /// Whether the floating [CounterOverlay] is rendered. Default OFF —
  /// flipped on by the master "Diagnostic mode" switch in
  /// SettingsInspector, or automatically on activation via
  /// `BXP_DIAGNOSTIC=1` / marker file at startup.
  bool _overlayVisible = false;
  bool get overlayVisible => _overlayVisible;
  set overlayVisible(bool v) {
    if (_overlayVisible == v) return;
    _overlayVisible = v;
    notifyListeners();
  }

  /// Mirror of `DiagnosticLog.isEnabled`. The log itself is the source
  /// of truth (only it knows whether the file open succeeded); we
  /// shadow the state here so the SettingsInspector can react via the
  /// existing ChangeNotifier wiring without subscribing separately.
  /// Updated by `DiagnosticLog.start` / `DiagnosticLog.stop`.
  bool _diagnosticTraceActive = false;
  bool get diagnosticTraceActive => _diagnosticTraceActive;
  String? _diagnosticTracePath;
  String? get diagnosticTracePath => _diagnosticTracePath;

  void setDiagnosticTraceState({required bool active, String? path}) {
    if (_diagnosticTraceActive == active &&
        _diagnosticTracePath == path) {
      return;
    }
    _diagnosticTraceActive = active;
    _diagnosticTracePath = path;
    notifyListeners();
  }

  /// True when both the overlay and the file trace are active. The
  /// SettingsInspector's master switch reads this and toggles both
  /// at once.
  bool get diagnosticMode => _overlayVisible && _diagnosticTraceActive;

  // ── Tree feature gates (production defaults: ON) ─────────────────────

  /// Render the Material `Tooltip` wrapping each tree key in
  /// `_SchemaTooltipKey`. Off was iter6 — confirmed not to fix the
  /// freeze, but cumulatively contributes to layer count.
  bool _tooltipsInTree = true;
  bool get tooltipsInTree => _tooltipsInTree;
  set tooltipsInTree(bool v) {
    if (_tooltipsInTree == v) return;
    _tooltipsInTree = v;
    notifyListeners();
  }

  /// Per-row hover background highlight. Off was iter7 — substantial
  /// improvement, suspected biggest contributor to the rebuild cascade.
  bool _hoverBackground = true;
  bool get hoverBackground => _hoverBackground;
  set hoverBackground(bool v) {
    if (_hoverBackground == v) return;
    _hoverBackground = v;
    notifyListeners();
  }

  /// Per-row trailing action buttons (↑↓×) appearing on hover. Off was
  /// iter8 — fixed the "click expr value → freeze" pattern. With this
  /// off, buttons only render when the row's State.isHovered is true
  /// AND _hoverActionButtons is true; otherwise the entire button
  /// subtree is unmounted (no Opacity wrapper).
  bool _hoverActionButtons = true;
  bool get hoverActionButtons => _hoverActionButtons;
  set hoverActionButtons(bool v) {
    if (_hoverActionButtons == v) return;
    _hoverActionButtons = v;
    notifyListeners();
  }

  /// Use Material `InkWell` for tap detection on expandable rows. Off
  /// (iter9) replaces with `GestureDetector`, which has no internal
  /// MouseRegion + AnimationController. Both the layer count and the
  /// ticker count drop substantially with this off.
  bool _useInkWell = true;
  bool get useInkWell => _useInkWell;
  set useInkWell(bool v) {
    if (_useInkWell == v) return;
    _useInkWell = v;
    notifyListeners();
  }

  // ── Pointer-event filters (production defaults: OFF) ────────────────

  /// Drop pointer events whose button mask includes the middle button.
  /// User reported that middle-click + drag accelerates the freeze
  /// (Windows synthesises a high-rate event stream while the button is
  /// held). With this on, the entire middle-button gesture is invisible
  /// to the widget tree.
  bool _blockMiddleButton = false;
  bool get blockMiddleButton => _blockMiddleButton;
  set blockMiddleButton(bool v) {
    if (_blockMiddleButton == v) return;
    _blockMiddleButton = v;
    notifyListeners();
  }

  /// Same as [blockMiddleButton] but for the secondary (right) button.
  bool _blockRightButton = false;
  bool get blockRightButton => _blockRightButton;
  set blockRightButton(bool v) {
    if (_blockRightButton == v) return;
    _blockRightButton = v;
    notifyListeners();
  }

  /// Cap PointerHoverEvent / PointerMoveEvent rate. 0 = no cap. 30 / 60
  /// drop intermediate events so the framework only ever sees N hover
  /// events per second. Button-down / -up / signal events always pass
  /// through to keep clicks responsive.
  int _pointerThrottleHz = 0;
  int get pointerThrottleHz => _pointerThrottleHz;
  set pointerThrottleHz(int v) {
    if (_pointerThrottleHz == v) return;
    _pointerThrottleHz = v;
    notifyListeners();
  }

  // ── Render pipeline diagnostics (production defaults: OFF) ──────────

  /// Skip the `Transform.scale` wrapper in `ZoomContainer` so the app
  /// content paints at native resolution with no transform layer. If
  /// the freeze disappears with this on, the wedge is in compositor
  /// handling of the scaled subtree — likely too many layers under a
  /// single transform, or hit-test traversal cost through it. With
  /// this on, the zoom keyboard shortcuts keep firing (the value gets
  /// stored in TraceStore) but visually nothing changes.
  bool _bypassZoom = false;
  bool get bypassZoom => _bypassZoom;
  set bypassZoom(bool v) {
    if (_bypassZoom == v) return;
    _bypassZoom = v;
    notifyListeners();
  }
}
