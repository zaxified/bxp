import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'store/trace_store.dart';
import 'ui/main_view.dart';
import 'ui/theme/bxp_theme.dart';
import 'ui/theme/bxp_theme_animator.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => TraceStore(),
      child: const BxpApp(),
    ),
  );
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
  void _bump(double delta) => _store.setZoom(_store.zoom + delta);

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (HardwareKeyboard.instance.isControlPressed) {
        final key = event.logicalKey.keyLabel;
        final physical = event.physicalKey;
        if (key == '+' || key == '=' || physical == PhysicalKeyboardKey.numpadAdd || physical == PhysicalKeyboardKey.equal || physical == PhysicalKeyboardKey.bracketRight) {
          _bump(0.1);
          return true;
        } else if (key == '-' || physical == PhysicalKeyboardKey.numpadSubtract || physical == PhysicalKeyboardKey.minus || physical == PhysicalKeyboardKey.slash) {
          _bump(-0.1);
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
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
          if (event.scrollDelta.dy > 0) {
            _bump(-0.1);
          } else if (event.scrollDelta.dy < 0) {
            _bump(0.1);
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
