import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../services/debug_binding.dart';
import '../store/trace_store.dart';

/// Floating counter widget pinned to the bottom-right of the app when
/// [DebugSettings.overlayVisible] is on. Polls [DebugBinding] for raw
/// event totals, computes 1-second rates, shows alongside frame paint
/// count + build/raster timings + TraceStore notify count.
///
/// Visibility is gated by SettingsInspector's "Diagnostic mode" master
/// switch (Ctrl+Shift+S). The overlay carries no tap target — settings
/// and toggles live in the inspector.
class CounterOverlay extends StatefulWidget {
  const CounterOverlay({super.key});

  @override
  State<CounterOverlay> createState() => _CounterOverlayState();
}

class _CounterOverlayState extends State<CounterOverlay> {
  // Last-second snapshots, updated by [_tick] every 1 s.
  int _peLastSec = 0;
  int _peForwardedLastSec = 0;
  int _peDroppedLastSec = 0;
  int _scrollLastSec = 0;
  int _midBtnLastSec = 0;
  int _frLastSec = 0;
  int _peTotalAtLastTick = 0;
  int _peForwardedAtLastTick = 0;
  int _scrollTotalAtLastTick = 0;
  int _midBtnTotalAtLastTick = 0;

  // Frame counter. We bump on every persistent frame callback; the
  // ticker drains it once per second.
  int _frThisSec = 0;
  int _peakPePerFrame = 0;
  int _peThisFrameStart = 0;

  // Frame timing diagnostics. `addTimingsCallback` delivers a batch of
  // [FrameTiming] objects after each frame paints; we keep the maxes
  // seen in the current 1-second bucket and the previous bucket. The
  // previous-bucket value is what the overlay displays, so we don't
  // flicker mid-tick.
  int _buildUsThisSec = 0;
  int _rasterUsThisSec = 0;
  int _buildUsLastSec = 0;
  int _rasterUsLastSec = 0;

  // TraceStore notifyListeners() counter. We register as a plain
  // listener — the callback is called once per notifyListeners() call.
  // _notifyThisSec / _notifyThisFrame bump on every callback;
  // _onFrame / _tick drain them to last-bucket values for display.
  // _peakNotifyPerFrame is max-ever, like _peakPePerFrame, so the
  // user can see the worst burst even after the storm subsides.
  TraceStore? _store;
  int _notifyThisSec = 0;
  int _notifyThisFrame = 0;
  int _notifyLastSec = 0;
  int _peakNotifyPerFrame = 0;

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pick up the TraceStore once it's available in the inherited tree.
    // Provider.of with listen:false avoids a rebuild subscription —
    // we attach a manual addListener that just bumps counters.
    final store = Provider.of<TraceStore>(context, listen: false);
    if (!identical(store, _store)) {
      _store?.removeListener(_onStoreNotify);
      _store = store;
      _store!.addListener(_onStoreNotify);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _store?.removeListener(_onStoreNotify);
    super.dispose();
  }

  void _onStoreNotify() {
    _notifyThisSec++;
    _notifyThisFrame++;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final b = t.buildDuration.inMicroseconds;
      final r = t.rasterDuration.inMicroseconds;
      if (b > _buildUsThisSec) _buildUsThisSec = b;
      if (r > _rasterUsThisSec) _rasterUsThisSec = r;
    }
  }

  void _onFrame(Duration _) {
    _frThisSec++;
    final binding = WidgetsBinding.instance;
    if (binding is DebugBinding) {
      final delta = binding.eventsTotal - _peThisFrameStart;
      if (delta > _peakPePerFrame) _peakPePerFrame = delta;
      _peThisFrameStart = binding.eventsTotal;
    }
    // Snapshot notify-per-frame burst before the next inter-frame
    // notify cascade starts. _notifyThisFrame is bumped by
    // _onStoreNotify between frames; here we record the worst-ever
    // value (analogous to _peakPePerFrame) and reset for the next
    // frame's count.
    if (_notifyThisFrame > _peakNotifyPerFrame) {
      _peakNotifyPerFrame = _notifyThisFrame;
    }
    _notifyThisFrame = 0;
  }

  void _tick() {
    final binding = WidgetsBinding.instance;
    if (binding is! DebugBinding) return;
    final total = binding.eventsTotal;
    final forwarded = binding.eventsForwarded;
    final scrollTotal = binding.scrollEventsTotal;
    final midBtnTotal = binding.middleButtonEventsTotal;
    if (!mounted) return;
    setState(() {
      _peLastSec = total - _peTotalAtLastTick;
      _peForwardedLastSec = forwarded - _peForwardedAtLastTick;
      _peDroppedLastSec = _peLastSec - _peForwardedLastSec;
      _scrollLastSec = scrollTotal - _scrollTotalAtLastTick;
      _midBtnLastSec = midBtnTotal - _midBtnTotalAtLastTick;
      _peTotalAtLastTick = total;
      _peForwardedAtLastTick = forwarded;
      _scrollTotalAtLastTick = scrollTotal;
      _midBtnTotalAtLastTick = midBtnTotal;
      _frLastSec = _frThisSec;
      _frThisSec = 0;
      _buildUsLastSec = _buildUsThisSec;
      _rasterUsLastSec = _rasterUsThisSec;
      _buildUsThisSec = 0;
      _rasterUsThisSec = 0;
      _notifyLastSec = _notifyThisSec;
      _notifyThisSec = 0;
      // Don't reset peak — show the all-time max so the user can see
      // their worst burst even after motion stops.
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      color: theme.colorScheme.onSurface,
      height: 1.3,
    );
    final headerStyle = mono.copyWith(
      fontSize: 10,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
      letterSpacing: 1.2,
    );
    return IgnorePointer(
      child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.88),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('DIAG · LIVE', style: headerStyle),
            ),
            Text('PE/s:    $_peLastSec', style: mono),
            if (_peDroppedLastSec > 0)
              Text('drop:    $_peDroppedLastSec', style: mono),
            if (_scrollLastSec > 0)
              Text('scrl:    $_scrollLastSec', style: mono),
            if (_midBtnLastSec > 0)
              Text('midB:    $_midBtnLastSec', style: mono),
            Text('F/s:     $_frLastSec', style: mono),
            Text('peak:    $_peakPePerFrame /f', style: mono),
            Text('build:   ${(_buildUsLastSec / 1000).toStringAsFixed(1)} ms',
                style: mono),
            Text('rastr:   ${(_rasterUsLastSec / 1000).toStringAsFixed(1)} ms',
                style: mono),
            Text('notif:   $_notifyLastSec /s', style: mono),
            Text('npeak:   $_peakNotifyPerFrame /f', style: mono),
          ],
        ),
      ),
    );
  }
}
