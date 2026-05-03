/// Round-trip identity tests for the JSON5 AST library.
///
/// Replaces the old `bin/round_trip.dart` smoke runner (which read the
/// developer-local `DEV/bxp-cli.json`) and the `AST round-trip identity`
/// phase that scripts/test.sh used to invoke. Both depended on a
/// gitignored file and only worked on one machine.
///
/// The library is intended to be **idempotent-canonical**, not
/// byte-identity preserving — see CLAUDE.md. The first dump may reformat
/// the input, but subsequent parse → dump cycles must produce the same
/// bytes.
library;

import 'package:test/test.dart';

import 'package:json5_ast/parser.dart';
import 'package:json5_ast/dumper.dart';

void main() {
  group('round-trip', () {
    test('idempotent canonicalisation across diverse JSON5 features', () {
      // Covers: top-of-file line comment, unquoted keys, single-quoted
      // strings, trailing commas, nested objects + arrays, leading +
      // trailing inline comments, block comments, $-prefixed identifier
      // keys, numbers (int + float), booleans + null, escape sequences.
      const fixture = r'''
// top of file
{
  // leading for templates
  conversion_templates: {
    sample: {
      data_dir: ".",
      file_pattern_in: ".csv",
      /* block before output_schema */
      output_schema: {
        date: "$date",          // trailing inline
        amount: '$amount',
      },
      input_schema: {
        $date: "[Date]",
        $amount: "[Amount]",
        $note: 'a\nb\tc',
      },
      counts: [1, 2, 3, 4],
      flags: [true, false, null],
      ratios: [0.5, 1.25, -0.75],
      nested_array: [
        // first
        [10, 20],
        [30, 40],
      ],
    },
  },
}
''';

      final r1 = Parser.parse(fixture);
      expect(r1.diagnostics, isEmpty, reason: 'first parse: ${r1.diagnostics}');
      final dump1 = Dumper.dump(r1.root!);

      // Second cycle: parse the dumper's own output.
      final r2 = Parser.parse(dump1);
      expect(r2.diagnostics, isEmpty,
          reason: 'reparse failed:\n----\n$dump1\n----\nerrors: ${r2.diagnostics}');
      final dump2 = Dumper.dump(r2.root!);

      // Idempotent canonicalisation: dump2 must byte-match dump1.
      expect(dump2, equals(dump1),
          reason: 'second dump diverged from first — canonicalisation is not idempotent');

      // Third cycle as belt-and-suspenders: stable forever after.
      final r3 = Parser.parse(dump2);
      expect(r3.diagnostics, isEmpty);
      expect(Dumper.dump(r3.root!), equals(dump2));
    });

    test('idempotent canonicalisation preserves comments verbatim', () {
      // The dumper may normalise spacing around comments but the comment
      // text itself, kind (line vs block), and ownership (leading vs
      // trailing-inline) must round-trip unchanged after the first
      // canonicalisation pass.
      const fixture = '''
{
  // alpha
  a: 1,
  /* beta
     multi-line */
  b: 2,
  c: 3, // trailing on c
}
''';

      final r1 = Parser.parse(fixture);
      expect(r1.diagnostics, isEmpty);
      final dump1 = Dumper.dump(r1.root!);

      // All three comment texts survive the canonicalisation.
      expect(dump1, contains('alpha'));
      expect(dump1, contains('beta'));
      expect(dump1, contains('multi-line'));
      expect(dump1, contains('trailing on c'));

      // And subsequent cycles are stable.
      final r2 = Parser.parse(dump1);
      expect(r2.diagnostics, isEmpty);
      expect(Dumper.dump(r2.root!), equals(dump1));
    });
  });
}
