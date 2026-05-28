import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'services/debug_binding.dart';
import 'services/debug_settings.dart';
import 'services/desktop_integration_service.dart';
import 'services/diagnostic_log.dart';
import 'services/updater_service.dart';
import 'store/trace_store.dart';
import 'ui/components/integrate_dialog.dart';
import 'ui/components/update_dialog.dart';
import 'ui/debug_overlay.dart';
import 'ui/main_view.dart';
import 'ui/platform_shortcuts.dart';
import 'ui/shader_warmup.dart';
import 'ui/theme/bxp_theme.dart';
import 'ui/theme/bxp_theme_animator.dart';
import 'ui/zoom_limits.dart';

// Global messenger key so the reactive overflow guard (which fires from
// FlutterError.onError, outside the widget tree) can surface a SnackBar.
final GlobalKey<ScaffoldMessengerState> bxpMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Global navigator key so widgets above the navigator (ZoomContainer,
/// CounterOverlay) can push dialogs without juggling Builder contexts.
/// Used for the debug-panel `showDialog` call — without a navigator
/// key we'd need a context from BELOW the navigator, which neither the
/// keyboard handler nor the counter overlay (both wrapped via
/// MaterialApp.builder) has.
final GlobalKey<NavigatorState> bxpNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  // Everything must run in the same zone. Flutter's zone-mismatch
  // assertion fires if the binding is initialized in one zone (root)
  // and `runApp` later runs in a child zone — and `runZonedGuarded`
  // creates such a child zone. Keeping the binding init + runApp
  // together inside the guarded zone avoids the diagnostic and lets
  // async errors fall through to the zone error handler.
  runZonedGuarded(() {
    // Pre-compile the Skia shader programs BXP uses on every screen so
    // the (~100-300 ms) compile cost is paid once at startup instead of
    // as scattered jank during the user's first interactions. Must run
    // BEFORE the binding init below — `PaintingBinding.initInstances`
    // dispatches the warm-up, and that fires from the first
    // `WidgetsBinding.instance` construction in `DebugBinding()`.
    PaintingBinding.shaderWarmUp = const BxpShaderWarmUp();

    // Custom binding that intercepts pointer events for the freeze
    // investigation (live counters + middle/right-button block +
    // hover throttle). Behaves identically to WidgetsFlutterBinding
    // when no toggles are flipped, so a default build is unchanged.
    DebugBinding.ensureInitialized();

    // Opt-in NDJSON diagnostic trace. Activated by `BXP_DIAGNOSTIC=1`
    // or marker file `$prefs-dir/.bxp-diagnostic`. When activated at
    // startup, also flip the floating CounterOverlay on. Mid-session
    // toggling lives in the inspector (Ctrl+Shift+S → DEBUG).
    unawaited(DiagnosticLog.tryInit().then((enabled) {
      if (!enabled) return;
      // ignore: avoid_print
      print('[bxp-gui] diagnostic trace -> ${DiagnosticLog.path}');
      DebugSettings.instance.overlayVisible = true;
      // Defer the settings/runtime snapshot until after the first
      // frame so providers (TraceStore) are reachable from the
      // navigator context. Reading earlier would race runApp.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = bxpNavigatorKey.currentContext;
        if (ctx != null) emitDiagnosticContextSnapshot(ctx);
      });
    }));

    final traceStore = TraceStore();
    final updaterService = UpdaterService();
    _installOverflowGuard(traceStore);
    _installDiagnosticErrorHooks();
    // Fire-and-forget — the periodic check runs even before the user
    // interacts with the UI. Errors are caught inside initialize().
    updaterService.initialize();
    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TraceStore>.value(value: traceStore),
          ChangeNotifierProvider<UpdaterService>.value(value: updaterService),
          ChangeNotifierProvider<DebugSettings>.value(
              value: DebugSettings.instance),
        ],
        child: const BxpApp(),
      ),
    );
  }, (error, stack) {
    DiagnosticLog.log('error.zone', {
      'error': '$error',
      'stack': '$stack',
    });
    // Re-raise into Flutter's standard error pipe so the existing
    // overflow guard / debug console behaviour is unchanged.
    FlutterError.reportError(FlutterErrorDetails(
      exception: error,
      stack: stack,
    ));
  });
}

/// Chains a diagnostic-log forwarder onto whatever [FlutterError.onError]
/// is currently installed. Must run AFTER [_installOverflowGuard] so
/// our forwarder wraps the overflow handler, not the other way round.
void _installDiagnosticErrorHooks() {
  final original = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    DiagnosticLog.log('error.flutter', {
      'exception': '${details.exception}',
      'library': details.library ?? '',
      'context': details.context?.toDescription() ?? '',
      if (details.stack != null) 'stack': '${details.stack}',
    });
    if (original != null) {
      original(details);
    } else {
      FlutterError.presentError(details);
    }
  };
}

// Reactive regression guard: any RenderFlex overflow that occurs while the
// user is zoomed in (zoom > 1.0) auto-decrements zoom by one step and
// re-renders. Catches future widgets that exceed kLogicalMin* without
// requiring the constants to be kept in sync. Non-zoom overflows pass
// through to the original handler unchanged.
void _installOverflowGuard(TraceStore store) {
  final original = FlutterError.onError;
  bool inFlight = false;
  FlutterError.onError = (FlutterErrorDetails details) {
    final msg = details.exception.toString();
    final isOverflow =
        msg.contains('overflowed') || msg.contains('RenderFlex');
    if (isOverflow && store.zoom > 1.0 && !inFlight) {
      inFlight = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        store.setZoom((store.zoom - kZoomStep).clamp(kMinZoom, kMaxZoom));
        bxpMessengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('Zoom reduced to fit window contents'),
            duration: Duration(milliseconds: 1500),
          ));
        inFlight = false;
      });
      return;
    }
    if (original != null) {
      original(details);
    } else {
      FlutterError.presentError(details);
    }
  };
}

class BxpApp extends StatelessWidget {
  const BxpApp({super.key});

  @override
  Widget build(BuildContext context) {
    // BxpThemeAnimator wraps the whole app so theme cycles cross-fade
    // for ~200ms instead of snapping. The inner Builder reads the
    // interpolated theme via `context.bxpTheme` (which now prefers the
    // BxpThemeScope provided by the animator over the raw store) and
    // builds a fresh MaterialApp.theme each tick — that way Material
    // widgets (Tooltip/Snackbar/dialogs) AND custom Containers reading
    // BxpTheme tokens both fade together.
    return BxpThemeAnimator(
      child: Builder(builder: (ctx) {
        final t = ctx.bxpTheme;
        final colorScheme = t.buildColorScheme();
        // Pull the active sans/prose typography scheme so Material
        // widgets that we don't render ourselves (Tooltip, Snackbar,
        // AppBar title, dialog titles) read fontFamily / sizes / weights
        // from the same single source as our own BxpText helpers.
        // Without this, Tooltips fall back to Flutter's hardcoded ~14px
        // sans and ignore everything in BxpTextScheme.
        final ts = ctx.watch<TraceStore>().textScheme;
        return MaterialApp(
          title: 'BXP',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: bxpMessengerKey,
          navigatorKey: bxpNavigatorKey,
          theme: ThemeData(
            useMaterial3: true,
            brightness: t.brightness,
            colorScheme: colorScheme,
            scaffoldBackgroundColor: t.surfaceBg,
            appBarTheme: AppBarTheme(
              backgroundColor: t.panelBg,
              elevation: 0,
              titleTextStyle: TextStyle(
                fontFamily: ts.fontFamily,
                fontFamilyFallback: ts.fontFamilyFallback,
                color: t.textPrimary,
                fontSize: ts.sizeLg,
                fontWeight: ts.weightSemiBold,
                letterSpacing: ts.trackTight,
              ),
            ),
            dividerTheme: DividerThemeData(
              color: t.borderColor,
              space: 1,
            ),
            tooltipTheme: TooltipThemeData(
              textStyle: TextStyle(
                fontFamily: ts.fontFamily,
                fontFamilyFallback: ts.fontFamilyFallback,
                fontSize: ts.sizeSm,
                fontWeight: ts.weightRegular,
                letterSpacing: ts.trackBody,
                color: t.textPrimary,
              ),
              decoration: BoxDecoration(
                color: t.dialogBg,
                border: Border.all(color: t.borderColor),
                borderRadius: BorderRadius.zero,
                boxShadow: [
                  BoxShadow(color: t.dialogShadow, blurRadius: 6),
                ],
              ),
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 6),
              waitDuration: const Duration(milliseconds: 300),
            ),
          ),
          // ZoomContainer must wrap the *entire* Navigator (not just
          // home: MainView), otherwise overlays — Tooltip, OpenDialog,
          // schema tooltips in JsonTree, the autocomplete popup —
          // render outside the scaled subtree and stay at 1×. Using
          // MaterialApp.builder is the standard way to get hold of
          // the navigator+overlay subtree.
          // Text-size DPR compensation. Flutter rasterises glyphs at
          // `fontSize × devicePixelRatio` physical pixels; on a Win 125 %
          // scaled monitor a `fontSize: 10` logical request becomes a
          // 12.5 px tall glyph on screen, while the same request on a
          // Linux 100 % monitor is 10 px. The visible result is "Win
          // text 25 % bigger than Linux" even though the widget tree
          // is the same logical size on both platforms.
          //
          // Overriding `MediaQuery.textScaler` to `1 / devicePixelRatio`
          // inverts that scaling at layout time: the engine now picks
          // a 8-logical-px glyph for `fontSize: 10`, which renders to
          // 10 physical px on the same Win 125 % monitor — matching
          // Linux 100 %. The override sits at MaterialApp.builder so
          // it propagates into every widget below the navigator.
          //
          // Why we don't piggy-back on the existing ZoomContainer
          // Transform.scale: hypothesis from a stuck cross-platform
          // test session — Transform.scale seems to NOT actually shrink
          // glyph rasterisation (Skia caches at the unscaled physical
          // size and the transform is just a layer composition), only
          // the surrounding non-text geometry. textScaler is the
          // correct lever for text. If this turns out double-counted
          // (text suddenly too small), the ZoomContainer's DPR-aware
          // `appliedZoom` math would need to drop its DPR divisor.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            final dpr = mq.devicePixelRatio;
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(dpr > 0 ? 1.0 / dpr : 1.0),
              ),
              child: ZoomContainer(child: child ?? const SizedBox.shrink()),
            );
          },
          home: const _UpdaterListener(
            child: _IntegrationListener(child: _StartupGate()),
          ),
        );
      }),
    );
  }
}

class ZoomContainer extends StatefulWidget {
  final Widget child;
  const ZoomContainer({super.key, required this.child});

  @override
  State<ZoomContainer> createState() => _ZoomContainerState();
}

class _ZoomContainerState extends State<ZoomContainer> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  TraceStore get _store => context.read<TraceStore>();

  void _bump(double delta) {
    final current = _store.zoom;
    final proposed = current + delta;
    if (delta > 0) {
      final mq = MediaQuery.of(context);
      final size = mq.size;
      // textScaler shrinks every text run by 1/devicePixelRatio
      // (see MaterialApp.builder), so the effective content footprint
      // is smaller than the nominal `kLogicalMin*` constants assume.
      // Multiply the safe ceiling by DPR so the user can zoom into
      // the freed-up headroom — without this the clamp on Win 125 %
      // pinned the user to a useless ~4 % range above default.
      final dpr = mq.devicePixelRatio;
      final maxSafe = maxSafeZoom(size) * (dpr > 0 ? dpr : 1.0);
      if (proposed > maxSafe + 1e-6) {
        bxpMessengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text(
                'Zoom limit reached — resize the window to zoom further'),
            duration: Duration(milliseconds: 1200),
          ));
        return;
      }
    }
    _store.setZoom(proposed);
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final physical = event.physicalKey;
      if (isCommandModifierPressed()) {
        final key = event.logicalKey.keyLabel;
        if (key == '+' || key == '=' || physical == PhysicalKeyboardKey.numpadAdd || physical == PhysicalKeyboardKey.equal || physical == PhysicalKeyboardKey.bracketRight) {
          _bump(kZoomStep);
          return true;
        } else if (key == '-' || physical == PhysicalKeyboardKey.numpadSubtract || physical == PhysicalKeyboardKey.minus || physical == PhysicalKeyboardKey.slash) {
          _bump(-kZoomStep);
          return true;
        } else if (key == '0' || physical == PhysicalKeyboardKey.numpad0 || physical == PhysicalKeyboardKey.digit0) {
          // Reset to platform default, NOT a literal 1.0. On Windows the
          // default is 0.8 (compensates for the typical 125 % display
          // scaling); resetting to 1.0 there would just trip the
          // ZoomContainer's post-frame `maxSafeZoom` auto-clamp and
          // settle on whatever fits the current window — usually
          // something like 0.99, which then gets persisted to prefs
          // and looks like Ctrl+0 forgot the user's intent.
          _store.setZoom(TraceStore.defaultZoomForPlatform());
          return true;
        }
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final storedZoom = context.watch<TraceStore>().zoom;
    final debug = context.watch<DebugSettings>();
    final bypassZoom = debug.bypassZoom;
    final overlayVisible = debug.overlayVisible;
    final size = MediaQuery.of(context).size;
    // DPR compensation now lives at MaterialApp.builder via a
    // `textScaler: 1 / devicePixelRatio` MediaQuery override — that's
    // the lever that actually shrinks glyph rasterisation, where
    // Transform.scale didn't reach. Here we therefore apply ONLY the
    // user's zoom intent: `appliedZoom = storedZoom`. Doing both would
    // shrink text twice (once via textScaler, once via Transform.scale)
    // and the GUI was visibly under-sized in that combined state.
    final appliedZoom = storedZoom;
    // If the window has shrunk (or zoom was loaded from prefs) below the
    // safe maximum, clamp asynchronously after this frame paints. We
    // can't call setZoom() directly during build — it would trigger a
    // notifyListeners loop. The post-frame callback defers the change to
    // after the current frame, and the persisted value updates via the
    // existing logic in TraceStore.setZoom.
    if (size.width > 0 && size.height > 0) {
      // Same textScaler-aware ceiling as `_bump`. The clamp is a
      // last-resort autoshrink for users who load prefs from a
      // larger window or shrink the OS window below the saved zoom;
      // multiplying by DPR keeps that recovery rare on Win 125 %
      // instead of firing on the first frame after a fresh launch.
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final safe = maxSafeZoom(size) * (dpr > 0 ? dpr : 1.0);
      if (appliedZoom > safe + 1e-6) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_store.zoom > safe + 1e-6) {
            _store.setZoom(safe);
          }
        });
      }
    }
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && isCommandModifierPressed()) {
          if (event.scrollDelta.dy > 0) {
            _bump(-kZoomStep);
          } else if (event.scrollDelta.dy < 0) {
            _bump(kZoomStep);
          }
        }
      },
      // The previous FractionallySizedBox + Transform.scale combo had a
      // subtle hit-test bug at zoom < 1.0: FractionallySizedBox uses
      // widthFactor to size its CHILD but its own RenderBox stays
      // clamped to the parent's maxWidth. RenderBox.hitTest rejects
      // pointer positions outside the box's own size, so when the
      // transform mapped a click to child-space x > parentWidth, the
      // hit was dropped before reaching the child — the rightmost ~few
      // buttons (GITHUB / theme cycle / playground examples) became
      // unclickable until Ctrl+0 forced zoom = 1.0. Replacing with an
      // explicit SizedBox sized to (size / zoom) gives the inner
      // RenderBox a real expanded rect so transformed hit positions
      // land within it.
      //
      // We use MediaQuery.size (already read above for the zoom clamp)
      // instead of LayoutBuilder. LayoutBuilder rebuilds whenever its
      // parent constraints change, which on Windows seemed to amplify
      // a Tooltip/Overlay-related rebuild storm during fast hover
      // streams over the JSON tree — small constraint flickers from
      // overlay insertion would re-run the entire content subtree.
      // MediaQuery.size only changes on actual window-resize events.
      //
      // Layout strategy:
      // - The Transform.scale + SizedBox(size/zoom) pair gives the
      //   transform's child a logical region matching the visible
      //   viewport AFTER scaling. Stack's own constraints would clamp
      //   that SizedBox down to the viewport size, which on zoom < 1
      //   left a black strip along the bottom-right edges (and on a
      //   manually-resized larger window the content stayed pinned to
      //   the original viewport size). OverflowBox releases the upper
      //   bound so the SizedBox can actually be larger than the parent
      //   and Transform.scale shrinks it back to fill the viewport.
      // - We keep the always-on path (no `zoom == 1.0` shortcut) so
      //   the widget subtree identity is preserved across zoom changes
      //   — toggling zoom across 1.0 must not detach widget state
      //   like scroll positions or focused inputs. Transform.scale
      //   with scale 1.0 is effectively free.
      // - When `bypassZoom` is on we mount widget.child directly (no
      //   Transform layer at all), used to isolate whether a suspected
      //   freeze is tied to compositor handling of the scaled subtree.
      child: Stack(
        children: [
          if (bypassZoom)
            widget.child
          else
            OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 0,
              minHeight: 0,
              maxWidth: size.width > 0 ? size.width / appliedZoom : double.infinity,
              maxHeight: size.height > 0 ? size.height / appliedZoom : double.infinity,
              child: Transform.scale(
                scale: appliedZoom,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: size.width > 0 ? size.width / appliedZoom : null,
                  height: size.height > 0 ? size.height / appliedZoom : null,
                  child: widget.child,
                ),
              ),
            ),
          if (overlayVisible)
            const Positioned(
              right: 8,
              bottom: 8,
              child: CounterOverlay(),
            ),
        ],
      ),
    );
  }
}

/// Listens to UpdaterService.available and shows the [UpdateDialog] once
/// per transition. Wraps the home subtree so the dialog can use the
/// nearest Navigator/Overlay regardless of which route is active.
class _UpdaterListener extends StatefulWidget {
  final Widget child;
  const _UpdaterListener({required this.child});

  @override
  State<_UpdaterListener> createState() => _UpdaterListenerState();
}

class _UpdaterListenerState extends State<_UpdaterListener> {
  bool _showing = false;
  UpdaterService? _svc;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<UpdaterService>();
    if (identical(next, _svc)) return;
    _svc?.removeListener(_onChange);
    _svc = next;
    _svc?.addListener(_onChange);
  }

  @override
  void dispose() {
    _svc?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (_showing) return;
    final info = _svc?.available;
    if (info == null) return;
    _showing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _showing = false;
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UpdateDialog(info: info),
      );
      _showing = false;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Listens for TraceStore initialisation completion and, on Linux
/// AppImage builds where `bxp-gui.json` does not yet exist on disk,
/// surfaces the [IntegrateDialog] once. The dialog itself is
/// responsible for creating the prefs file (via [PrefsService.ensureExists])
/// on either choice, so the dialog only fires for a true fresh install.
class _IntegrationListener extends StatefulWidget {
  final Widget child;
  const _IntegrationListener({required this.child});

  @override
  State<_IntegrationListener> createState() => _IntegrationListenerState();
}

class _IntegrationListenerState extends State<_IntegrationListener> {
  final DesktopIntegrationService _integration = DesktopIntegrationService();
  bool _checked = false;
  TraceStore? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<TraceStore>();
    if (identical(next, _store)) return;
    _store?.removeListener(_onStoreChanged);
    _store = next;
    _store?.addListener(_onStoreChanged);
    _onStoreChanged();
  }

  @override
  void dispose() {
    _store?.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (_checked) return;
    final store = _store;
    if (store == null || !store.initialized) return;
    _checked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Windows / macOS / `flutter run` builds — nothing to do.
      if (!_integration.isAvailable()) return;
      // Already integrated — silently reconcile a stale Exec= path
      // (user moved the AppImage) and stop.
      if (_integration.isIntegrated()) {
        await _integration.reconcileExecPath();
        return;
      }
      // Prefs file already on disk → user previously went through the
      // dialog (or this is a re-install over their settings dir).
      // Either way: don't nag.
      if (store.prefs.prefsFileExists()) return;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => IntegrateDialog(
          integration: _integration,
          prefs: store.prefs,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Routes the home tab between three views:
///   * loading splash while [TraceStore._init] runs the bxp-fmt smoke test
///   * full-screen [_FatalErrorView] when bxp-fmt is missing or `--docs`
///     fails — every other interaction is blocked here on purpose, the GUI
///     cannot function without the catalog.
///   * [MainView] otherwise, with `store.docs` guaranteed populated so
///     downstream widgets can drop their fallback constants.
class _StartupGate extends StatelessWidget {
  const _StartupGate();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    if (!store.initialized) {
      final t = context.bxpTheme;
      return Scaffold(
        backgroundColor: t.surfaceBg,
        body: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(t.accentHighlight),
            ),
          ),
        ),
      );
    }
    final fatal = store.fatalStartupError;
    if (fatal != null) return _FatalErrorView(message: fatal);
    return const MainView();
  }
}

class _FatalErrorView extends StatelessWidget {
  final String message;
  const _FatalErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Scaffold(
      backgroundColor: t.surfaceBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.error_outline,
                          color: t.errorText, size: 28),
                      const SizedBox(width: 12),
                      Text('Startup error',
                          style: TextStyle(
                            color: t.errorText,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          )),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: t.dialogBg,
                      border: Border.all(color: t.borderColor),
                    ),
                    child: SelectableText(
                      message,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 13,
                        height: 1.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'The GUI cannot function without bxp-fmt. Fix the issue '
                    'above and relaunch the app.',
                    style: TextStyle(color: t.textMuted, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
