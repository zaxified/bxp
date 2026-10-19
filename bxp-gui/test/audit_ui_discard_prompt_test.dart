// Regression gate for `confirmDiscardUnsaved` (lib/ui/config_view.dart).
//
// Open / Reload (toolbar and Ctrl+O / Ctrl+R) replace the in-memory config
// with the file on disk; with unsaved edits they used to do so silently,
// dropping the edits and the op log. The prompt must appear only when the
// store is dirty, must report the user's choice, and must not stack when a
// held-down shortcut fires it twice.

import 'package:bxp_gui/store/trace_store.dart';
import 'package:bxp_gui/ui/config_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store extends TraceStore {
  _Store(this._dirty);
  final bool _dirty;
  @override
  bool get isDirty => _dirty;
}

Future<void> _settle(WidgetTester tester, TraceStore s) async {
  // TraceStore._init does real file I/O; let it finish before dispose.
  await tester.runAsync(() async {
    for (var i = 0; i < 400 && !s.initialized; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  });
}

void main() {
  testWidgets('clean store: no dialog, proceeds', (tester) async {
    final store = _Store(false);
    addTearDown(store.dispose);
    await _settle(tester, store);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        })));
    final ok = await confirmDiscardUnsaved(ctx, store, 'Reloading');
    expect(ok, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('dirty store: Cancel -> false, Discard -> true, no stacking',
      (tester) async {
    final store = _Store(true);
    addTearDown(store.dispose);
    await _settle(tester, store);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        })));

    final first = confirmDiscardUnsaved(ctx, store, 'Reloading');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // A second request while the prompt is open must not open another one.
    final second = await confirmDiscardUnsaved(ctx, store, 'Reloading');
    expect(second, isFalse);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await first, isFalse);
    expect(find.byType(AlertDialog), findsNothing);

    final third = confirmDiscardUnsaved(ctx, store, 'Reloading');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(await third, isTrue);
  });
}
