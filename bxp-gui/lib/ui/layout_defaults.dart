// Percentage-based defaults / minima / maxima for every resizable
// splitter pane in the app. Single source of truth — change one line
// here to retune the layout without hunting through individual widgets.

class SplitConfig {
  final double defaultFrac;
  final double minFrac;
  final double maxFrac;
  const SplitConfig(this.defaultFrac, this.minFrac, this.maxFrac);

  double clamp(double v) => v < minFrac ? minFrac : (v > maxFrac ? maxFrac : v);
}

class LayoutDefaults {
  // ConfigView: ConfigTree | ExprPanel (left fraction).
  static const treeExprLeft = SplitConfig(0.40, 0.25, 0.75);

  // DebugPanes top: Files | (right 3-pane stack) (left fraction).
  static const filesDetailsLeft = SplitConfig(0.25, 0.10, 0.60);

  // DebugPanes right column — 3-pane vertical stack.
  // Constraints: rows_in.max + rows_out.max = 60% so middle is
  // implicitly forced to >= 40% even though its own min is 30%. That
  // is intentional — the inspect/rules pane is the focal area.
  static const rowsIn = SplitConfig(0.25, 0.10, 0.30);
  static const rowsMid = SplitConfig(0.55, 0.30, 0.80);
  static const rowsOut = SplitConfig(0.20, 0.10, 0.30);

  // RowDetail: ROW SELECTED | ROW TRANSFORM (left fraction).
  // Lives inside the middle pane, which itself shrinks when the
  // outer 3-pane stack rebalances — fractional keeps it sane.
  static const rowSelectedLeft = SplitConfig(0.23, 0.15, 0.65);

  // MainView: stderr expanded panel max height as a fraction of
  // available viewport. Caps the panel before it shoves the status
  // bar off-screen on small windows.
  static const stderrPanelMaxHeightFrac = 0.40;

  // Floating right-side overlay drawers (ThemeInspector, SettingsInspector).
  // Single fraction shared by both so they look identical-width regardless
  // of which the user toggled.
  static const sidePanelFrac = 0.40;
}
