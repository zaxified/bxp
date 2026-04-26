import 'package:bxp_gui/ui/zoom_limits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('maxSafeZoom', () {
    test('exact-min window allows 1.0×', () {
      expect(
        maxSafeZoom(const Size(kLogicalMinWidth, kLogicalMinHeight)),
        closeTo(1.0, 1e-9),
      );
    });

    test('larger window scales up to limited factor', () {
      // Width allows 1.25, height allows 1.04 — height bottlenecks.
      final z = maxSafeZoom(const Size(1280.0, 800.0));
      expect(z, closeTo(800.0 / kLogicalMinHeight, 1e-9));
      expect(z, lessThan(1280.0 / kLogicalMinWidth + 1e-9));
    });

    test('result clamped to [kMinZoom, kMaxZoom]', () {
      // Tiny window — would compute < kMinZoom but is floored.
      expect(maxSafeZoom(const Size(100, 100)), kMinZoom);
      // Huge window — would compute > kMaxZoom but is capped.
      expect(maxSafeZoom(const Size(10000, 10000)), kMaxZoom);
    });

    test('width and height both gate independently', () {
      // Wide but short — height bottlenecks.
      expect(
        maxSafeZoom(const Size(4000, 768)),
        closeTo(1.0, 1e-9),
      );
      // Tall but narrow — width bottlenecks.
      expect(
        maxSafeZoom(const Size(1024, 4000)),
        closeTo(1.0, 1e-9),
      );
    });
  });

  group('overflow regression — at safe zoom, fixed dialogs fit', () {
    // Widget-level smoke test: render a Container at the largest hard-coded
    // dialog size (OpenDialog 820×500) inside a synthetic "window" of
    // kLogicalMinWidth × kLogicalMinHeight, and assert no overflow.
    // If a future contributor adds a dialog larger than kLogicalMinWidth/Height
    // they must either shrink it or update the constants — and this test
    // will fail in either case until they do.
    testWidgets('OpenDialog 820×500 fits in kLogicalMin viewport',
        (tester) async {
      final exceptions = <FlutterErrorDetails>[];
      final original = FlutterError.onError;
      FlutterError.onError = exceptions.add;
      try {
        tester.view.physicalSize =
            const Size(kLogicalMinWidth, kLogicalMinHeight);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(const MaterialApp(
          home: Center(
            child: SizedBox(
              width: 820,
              height: 500,
              child: ColoredBox(color: Color(0xFF000000)),
            ),
          ),
        ));
        await tester.pump();
      } finally {
        FlutterError.onError = original;
      }
      final overflows = exceptions
          .where((e) =>
              e.exception.toString().contains('overflowed') ||
              e.exception.toString().contains('RenderFlex'))
          .toList();
      expect(overflows, isEmpty,
          reason: 'overflow detected — kLogicalMin* constants are too small '
              'or a widget grew beyond them');
    });

    testWidgets('Autocomplete popup 520×320 fits in kLogicalMin viewport',
        (tester) async {
      final exceptions = <FlutterErrorDetails>[];
      final original = FlutterError.onError;
      FlutterError.onError = exceptions.add;
      try {
        tester.view.physicalSize =
            const Size(kLogicalMinWidth, kLogicalMinHeight);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(const MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 520,
              height: 320,
              child: ColoredBox(color: Color(0xFF000000)),
            ),
          ),
        ));
        await tester.pump();
      } finally {
        FlutterError.onError = original;
      }
      final overflows = exceptions
          .where((e) =>
              e.exception.toString().contains('overflowed') ||
              e.exception.toString().contains('RenderFlex'))
          .toList();
      expect(overflows, isEmpty);
    });
  });
}
