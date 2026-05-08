import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../services/debug_binding.dart';
import '../services/debug_settings.dart';
import '../store/trace_store.dart';

/// Always-visible counter widget pinned to the bottom-right of the app.
/// Polls [DebugBinding] for raw event totals, computes 1-second rates,
/// shows alongside frame paint count from the scheduler.
///
/// Tap anywhere on the overlay to open the [DebugPanelDialog] — gives
/// the user a guaranteed way in even when the keyboard shortcut
/// doesn't fire (Czech layout / Flutter framework intercepting F12 /
/// engine-level remapping). The single tap target adds one MouseRegion
/// to the widget tree, but it's confined to the small (~140×80 px)
/// overlay rect at the screen edge, well outside the path of
/// frantic-mouse-over-tree gestures.
class CounterOverlay extends StatefulWidget {
  /// Called when the user taps the overlay.
  final VoidCallback? onTap;
  const CounterOverlay({super.key, this.onTap});

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

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
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
      // Don't reset peak — show the all-time max so the user can see
      // their worst burst even after motion stops.
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 11,
      color: theme.colorScheme.onSurface,
      height: 1.2,
    );
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.85),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('PE/s:  $_peLastSec', style: mono),
            if (_peDroppedLastSec > 0)
              Text('drop:  $_peDroppedLastSec', style: mono),
            if (_scrollLastSec > 0)
              Text('scrl:  $_scrollLastSec', style: mono),
            if (_midBtnLastSec > 0)
              Text('midB:  $_midBtnLastSec', style: mono),
            Text('F/s:   $_frLastSec', style: mono),
            Text('peak:  $_peakPePerFrame /f', style: mono),
            Text('build: ${(_buildUsLastSec / 1000).toStringAsFixed(1)} ms',
                style: mono),
            Text('rastr: ${(_rasterUsLastSec / 1000).toStringAsFixed(1)} ms',
                style: mono),
            const SizedBox(height: 2),
            Text('tap → debug panel', style: mono.copyWith(fontSize: 9)),
          ],
        ),
      ),
    );
  }
}

/// Modal-style debug panel: opens on Ctrl+Shift+D, the user flips
/// toggles + clicks stress buttons, then closes (Esc / Ctrl+Shift+D
/// again) to test the main GUI. Kept off-tree when closed so the panel
/// itself doesn't influence what we're measuring.
class DebugPanelDialog extends StatefulWidget {
  const DebugPanelDialog({super.key});

  @override
  State<DebugPanelDialog> createState() => _DebugPanelDialogState();
}

class _DebugPanelDialogState extends State<DebugPanelDialog> {
  bool _stressRunning = false;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: DebugSettings.instance,
      child: Consumer<DebugSettings>(
        builder: (context, s, _) => AlertDialog(
          title: const Text('Debug panel — Windows freeze investigation'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionHeader('Tree feature gates'),
                  CheckboxListTile(
                    dense: true,
                    title: const Text('Tooltips on tree keys'),
                    subtitle: const Text(
                        'Material Tooltip wrapping each schema key'),
                    value: s.tooltipsInTree,
                    onChanged: (v) => s.tooltipsInTree = v ?? true,
                  ),
                  CheckboxListTile(
                    dense: true,
                    title: const Text('Hover background highlight'),
                    subtitle:
                        const Text('Per-row setState on mouse enter/exit'),
                    value: s.hoverBackground,
                    onChanged: (v) => s.hoverBackground = v ?? true,
                  ),
                  CheckboxListTile(
                    dense: true,
                    title: const Text('Hover-driven action buttons'),
                    subtitle: const Text(
                        '↑↓× appear when hovered (vs. never mounted)'),
                    value: s.hoverActionButtons,
                    onChanged: (v) => s.hoverActionButtons = v ?? true,
                  ),
                  CheckboxListTile(
                    dense: true,
                    title: const Text('InkWell on expandable rows'),
                    subtitle: const Text(
                        'Material ripple + hover; off uses GestureDetector'),
                    value: s.useInkWell,
                    onChanged: (v) => s.useInkWell = v ?? true,
                  ),
                  const SizedBox(height: 8),
                  const _SectionHeader('Pointer event filters'),
                  CheckboxListTile(
                    dense: true,
                    title: const Text('Block middle mouse button'),
                    subtitle: const Text(
                        'Drop events whose button mask includes middle'),
                    value: s.blockMiddleButton,
                    onChanged: (v) => s.blockMiddleButton = v ?? false,
                  ),
                  CheckboxListTile(
                    dense: true,
                    title: const Text('Block right mouse button'),
                    subtitle: const Text(
                        'Drop events whose button mask includes secondary'),
                    value: s.blockRightButton,
                    onChanged: (v) => s.blockRightButton = v ?? false,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Text('Hover throttle:'),
                        const SizedBox(width: 8),
                        for (final hz in const [0, 60, 30, 15])
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text(hz == 0 ? 'off' : '${hz}Hz'),
                              selected: s.pointerThrottleHz == hz,
                              onSelected: (_) => s.pointerThrottleHz = hz,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const _SectionHeader('Render pipeline'),
                  CheckboxListTile(
                    dense: true,
                    title: const Text('Bypass zoom (skip Transform.scale)'),
                    subtitle: const Text(
                        'Paint app at native resolution; isolates compositor cost'),
                    value: s.bypassZoom,
                    onChanged: (v) => s.bypassZoom = v ?? false,
                  ),
                  const SizedBox(height: 8),
                  const _SectionHeader('Stress tests'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        ElevatedButton(
                          onPressed:
                              _stressRunning ? null : () => _stressRebuild(100),
                          child: Text(_stressRunning
                              ? 'running…'
                              : 'Rebuild tree 100×'),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      'Stress tests run with the panel still open. Watch the '
                      'CounterOverlay (bottom-right) to see whether F/s drops '
                      'while PE/s is zero — that would prove render is '
                      'fragile independent of mouse input.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close (Esc)'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _stressRebuild(int n) async {
    final store = context.read<TraceStore>();
    setState(() => _stressRunning = true);
    // Yield between notifies so the framework actually schedules a
    // frame each iteration; back-to-back notifyListeners collapses
    // into a single dirty-mark before any frame paints.
    for (var i = 0; i < n; i++) {
      store.debugNotify();
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (!mounted) return;
    setState(() => _stressRunning = false);
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge,
      ),
    );
  }
}
