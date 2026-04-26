import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'store/trace_store.dart';
import 'ui/main_view.dart';
import 'ui/theme/bxp_theme.dart';
import 'ui/theme/bxp_theme_animator.dart';
import 'ui/zoom_limits.dart';

// Global messenger key so the reactive overflow guard (which fires from
// FlutterError.onError, outside the widget tree) can surface a SnackBar.
final GlobalKey<ScaffoldMessengerState> bxpMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() {
  final traceStore = TraceStore();
  _installOverflowGuard(traceStore);
  runApp(
    ChangeNotifierProvider<TraceStore>.value(
      value: traceStore,
      child: const BxpApp(),
    ),
  );
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
          title: 'BXP GUI',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: bxpMessengerKey,
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
          builder: (context, child) =>
              ZoomContainer(child: child ?? const SizedBox.shrink()),
          home: const MainView(),
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
      final size = MediaQuery.of(context).size;
      final maxSafe = maxSafeZoom(size);
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
      if (HardwareKeyboard.instance.isControlPressed) {
        final key = event.logicalKey.keyLabel;
        final physical = event.physicalKey;
        if (key == '+' || key == '=' || physical == PhysicalKeyboardKey.numpadAdd || physical == PhysicalKeyboardKey.equal || physical == PhysicalKeyboardKey.bracketRight) {
          _bump(kZoomStep);
          return true;
        } else if (key == '-' || physical == PhysicalKeyboardKey.numpadSubtract || physical == PhysicalKeyboardKey.minus || physical == PhysicalKeyboardKey.slash) {
          _bump(-kZoomStep);
          return true;
        } else if (key == '0' || physical == PhysicalKeyboardKey.numpad0 || physical == PhysicalKeyboardKey.digit0) {
          _store.setZoom(1.0);
          return true;
        }
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final zoom = context.watch<TraceStore>().zoom;
    final size = MediaQuery.of(context).size;
    // If the window has shrunk (or zoom was loaded from prefs) below the
    // safe maximum, clamp asynchronously after this frame paints. We
    // can't call setZoom() directly during build — it would trigger a
    // notifyListeners loop. The post-frame callback defers the change to
    // after the current frame, and the persisted value updates via the
    // existing logic in TraceStore.setZoom.
    if (size.width > 0 && size.height > 0) {
      final safe = maxSafeZoom(size);
      if (zoom > safe + 1e-6) {
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
        if (event is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
          if (event.scrollDelta.dy > 0) {
            _bump(-kZoomStep);
          } else if (event.scrollDelta.dy < 0) {
            _bump(kZoomStep);
          }
        }
      },
      child: Transform.scale(
        scale: zoom,
        alignment: Alignment.topLeft,
        child: FractionallySizedBox(
          widthFactor: 1 / zoom,
          heightFactor: 1 / zoom,
          alignment: Alignment.topLeft,
          child: widget.child,
        ),
      ),
    );
  }
}
