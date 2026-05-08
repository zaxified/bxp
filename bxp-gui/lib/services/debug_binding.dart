import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'debug_settings.dart';

/// Custom `WidgetsFlutterBinding` that intercepts pointer events before
/// they reach the framework's hit-test + dispatch chain. Used for the
/// Windows freeze investigation:
///
///   - **Counters**: every event arriving from the engine is counted
///     into a 1-second rolling bucket. The CounterOverlay polls those
///     buckets to render live "PE/s" / "PE/frame" stats.
///   - **Button block**: when [DebugSettings.blockMiddleButton] /
///     [blockRightButton] is on, events whose buttons mask includes the
///     blocked button never reach the framework — the user can confirm
///     whether middle-click + drag accelerates the freeze by toggling
///     the gate live.
///   - **Throttle**: when [DebugSettings.pointerThrottleHz] > 0, hover
///     and move events are coalesced down to that rate. Button presses
///     and signal events always pass.
///
/// Install by calling [DebugBinding.ensureInitialized] from main()
/// instead of `WidgetsFlutterBinding.ensureInitialized()`.
class DebugBinding extends WidgetsFlutterBinding {
  /// Total number of pointer events received from the engine since
  /// startup. Counter is bumped before any filtering, so it reflects
  /// raw input volume even when the framework isn't seeing it.
  int _eventsTotal = 0;

  /// Total number of pointer events forwarded to the framework after
  /// any blocking / throttling. Useful for proving that a throttle
  /// actually drops events.
  int _eventsForwarded = 0;

  /// Last timestamp at which a hover/move event was forwarded —
  /// throttle reference.
  DateTime _lastForwarded = DateTime.fromMillisecondsSinceEpoch(0);

  static DebugBinding ensureInitialized() {
    final existing = WidgetsBinding.instance;
    if (existing is DebugBinding) return existing;
    return DebugBinding();
  }

  /// Total events seen so far. Use deltas across two reads to derive a
  /// rate; absolute value is monotonic and never resets.
  int get eventsTotal => _eventsTotal;

  /// Total events that were not dropped by [DebugSettings] filtering.
  int get eventsForwarded => _eventsForwarded;

  @override
  void handlePointerEvent(PointerEvent event) {
    _eventsTotal++;

    final s = DebugSettings.instance;

    // Button-block gate. `event.buttons` is the bitmask of currently-
    // pressed buttons; for hover events it's 0, but for moves while a
    // button is held it includes the held button. Drop the entire
    // event so the framework never sees the gesture.
    if (s.blockMiddleButton &&
        (event.buttons & kMiddleMouseButton) != 0) {
      return;
    }
    if (s.blockRightButton &&
        (event.buttons & kSecondaryMouseButton) != 0) {
      return;
    }

    // Throttle gate: only applied to passive events (hover / move).
    // Clicks / scrolls / button-down events always pass so user input
    // intent stays responsive.
    if (s.pointerThrottleHz > 0 &&
        (event is PointerHoverEvent || event is PointerMoveEvent)) {
      final intervalUs = 1000000 ~/ s.pointerThrottleHz;
      final now = DateTime.now();
      if (now.difference(_lastForwarded).inMicroseconds < intervalUs) {
        return;
      }
      _lastForwarded = now;
    }

    _eventsForwarded++;
    super.handlePointerEvent(event);
  }
}
