/// Opt-in DumperOptions coverage.
///
/// `inlineObjectMax` defaults to 0, which means every object is emitted
/// multi-line — bxp-gui's canonical style. Library consumers (current
/// or future, post-extraction) may pass a positive value to collapse
/// short objects onto one line. This test exercises that path so the
/// default-disabled branch doesn't silently rot.
library;

import 'package:test/test.dart';

import 'package:json5_ast/parser.dart';
import 'package:json5_ast/dumper.dart';

void main() {
  group('DumperOptions.inlineObjectMax', () {
    test('default (0) keeps every object multi-line', () {
      const src = '{ a: { b: 1 } }';
      final root = Parser.parse(src).root!;
      final out = Dumper.dump(root);
      // The inner `{ b: 1 }` cannot fit inline: probe length (~9) > 0.
      expect(RegExp(r'\n\s+b:').hasMatch(out), isTrue,
          reason: 'expected multi-line output, got:\n$out');
    });

    test('positive limit inlines a short object', () {
      const src = '{ a: { b: 1 } }';
      final root = Parser.parse(src).root!;
      final out = Dumper.dump(root, const DumperOptions(inlineObjectMax: 80));
      // The inner object is short enough — should appear on one line.
      expect(out.contains('{ b: 1 }'), isTrue,
          reason: 'expected inline `{ b: 1 }`, got:\n$out');
    });

    test('positive limit does NOT inline an object with comments', () {
      const src = '{ a: { /* keep */ b: 1 } }';
      final root = Parser.parse(src).root!;
      final out = Dumper.dump(root, const DumperOptions(inlineObjectMax: 80));
      // Any comment forces multi-line regardless of the limit.
      expect(out.contains('\n'), isTrue);
      expect(out.contains('keep'), isTrue);
    });
  });
}
