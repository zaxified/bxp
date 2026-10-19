// Regression tests for the expression components (expr_highlight,
// expr_editor): surrogate-pair tokenizing and the stale autocomplete range.
//
// No bridge is needed — the store's docs catalog is injected directly.

import 'package:bxp_gui/store/trace_store.dart';
import 'package:bxp_gui/ui/components/expr_editor.dart';
import 'package:bxp_gui/ui/components/expr_highlight.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

Future<TraceStore> _makeStore(WidgetTester tester) async {
  late TraceStore store;
  await tester.runAsync(() async {
    store = TraceStore();
    for (var i = 0; i < 200 && !store.initialized; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  });
  addTearDown(store.dispose);
  store.docs = {
    'functions': [
      {
        'name': 'SUM',
        'signature': 'SUM(x)',
        'description': 'adds',
        'args': <Map<String, dynamic>>[],
      },
    ],
    'keywords': <Map<String, dynamic>>[],
    'operators': <Map<String, dynamic>>[],
  };
  return store;
}

Widget _host(TraceStore store, Widget child) => ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('ExprHighlight survives an emoji outside any string/bracket',
      (tester) async {
    final store = await _makeStore(tester);
    for (final hover in [false, true]) {
      await tester.pumpWidget(_host(
          store, ExprHighlight(text: "a \u{1F600} & 'x'", hoverContext: hover)));
      expect(tester.takeException(), isNull,
          reason: 'a surrogate pair split over two spans is ill-formed UTF-16');
    }
  });

  testWidgets('ExprTextEditingController keeps text intact around an emoji',
      (tester) async {
    final store = await _makeStore(tester);
    final ctrl = ExprTextEditingController(text: "IF(1, \u{1F600}, 2)");
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_host(store, TextField(controller: ctrl)));
    expect(tester.takeException(), isNull);
    late TextSpan span;
    await tester.pumpWidget(_host(
      store,
      Builder(builder: (ctx) {
        span = ctrl.buildTextSpan(
            context: ctx, style: null, withComposing: false);
        return const SizedBox();
      }),
    ));
    expect(span.toPlainText(), ctrl.text);
  });

  testWidgets('autocomplete Enter inside the debounce window does not throw',
      (tester) async {
    final store = await _makeStore(tester);
    final ctrl = ExprTextEditingController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_host(store, ExprEditor(controller: ctrl)));
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'SU');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('SUM(x)'), findsOneWidget, reason: 'popup must be open');

    // Shrink the text, then accept before the 500 ms refresh ran: the
    // recorded replace range (0..2) is now outside the text.
    await tester.enterText(find.byType(TextField), '');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(tester.takeException(), isNull);
    expect(ctrl.text, '');
    await tester.pump(const Duration(milliseconds: 600));
  });
}
