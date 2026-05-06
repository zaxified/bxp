import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import 'bxp_theme.dart';

/// Wraps a widget subtree and exposes an interpolated [BxpTheme] via
/// [BxpThemeScope] (an InheritedWidget). When [TraceStore.themePresetName]
/// changes, an [AnimationController] runs for [duration] and rebuilds
/// each tick with `BxpTheme.lerp(old, new, t)`. Components reading via
/// `context.bxpTheme` automatically rebuild on each tick — the chrome
/// cross-fades instead of snapping.
///
/// Without this wrapper, [BxpThemeContext.bxpTheme] reads directly from
/// the store and snaps. Both code paths are supported (extension checks
/// for [BxpThemeScope] first), so removing this animator just disables
/// the cross-fade — nothing else breaks.
class BxpThemeAnimator extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Curve curve;

  const BxpThemeAnimator({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 200),
    this.curve = Curves.easeOut,
  });

  @override
  State<BxpThemeAnimator> createState() => _BxpThemeAnimatorState();
}

class _BxpThemeAnimatorState extends State<BxpThemeAnimator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: widget.duration);

  late BxpTheme _current;
  BxpTheme? _previous;
  String? _lastName;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final name = context.watch<TraceStore>().themePresetName;
    if (name != _lastName) {
      final next = themeByName(name);
      if (_lastName == null) {
        // First build — no animation, just adopt the resolved theme.
        _current = next;
      } else {
        _previous = _current;
        _current = next;
        _ctrl.forward(from: 0);
      }
      _lastName = name;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        final BxpTheme resolved;
        if (_previous == null || _ctrl.value >= 1.0) {
          resolved = _current;
        } else {
          final t = widget.curve.transform(_ctrl.value);
          resolved = BxpTheme.lerp(_previous!, _current, t);
        }
        return BxpThemeScope(theme: resolved, child: child!);
      },
      child: widget.child,
    );
  }
}

/// InheritedWidget surface for the animated theme. Holds the
/// per-frame interpolated [BxpTheme] so descendants rebuild when the
/// animation ticks.
///
/// Equality is identity-based on the theme instance — every animation
/// frame creates a new lerped instance so [updateShouldNotify] returns
/// true and the subtree rebuilds. Once the controller settles at
/// 1.0, the same `_current` instance is returned and [updateShouldNotify]
/// returns false, so post-animation rebuilds stay cheap.
class BxpThemeScope extends InheritedWidget {
  final BxpTheme theme;
  const BxpThemeScope({super.key, required this.theme, required super.child});

  static BxpTheme? of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<BxpThemeScope>();
    return scope?.theme;
  }

  @override
  bool updateShouldNotify(BxpThemeScope oldWidget) =>
      !identical(oldWidget.theme, theme);
}
