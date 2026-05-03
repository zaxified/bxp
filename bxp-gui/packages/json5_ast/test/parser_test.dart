/// Parser-level tests: error surfacing, comment placement corpus, line
/// endings, and idempotent canonicalisation.
library;

import 'package:test/test.dart';

import 'package:json5_ast/ast.dart';
import 'package:json5_ast/parser.dart';
import 'package:json5_ast/dumper.dart';

void main() {
  group('tokenizer errors surface as diagnostics', () {
    // Each input would throw a TokenizerError if not caught — Parser.parse
    // wraps tokenization in a try/catch so consumers always get a
    // ParseResult instead of an uncaught exception.
    final inputs = <String, String>{
      'unterminated string': '{ a: "no end',
      'unterminated block comment': '{ a: 1 /* still going',
      'EOF inside string escape': r'{ a: "\',
      'sign with no digit': '{ a: + }',
      'bad hex literal': '{ a: 0xZZ }',
    };
    for (final entry in inputs.entries) {
      test(entry.key, () {
        final r = Parser.parse(entry.value);
        expect(r.diagnostics, isNotEmpty, reason: 'expected diagnostic, got none');
        expect(r.hasErrors, isTrue);
      });
    }
  });

  group('CRLF input round-trips through the dumper', () {
    test('object with CRLF separators parses and dumps identically twice',
        () {
      const crlf = '{\r\n  a: 1,\r\n  b: 2\r\n}\r\n';
      final r1 = Parser.parse(crlf);
      expect(r1.diagnostics, isEmpty,
          reason: 'CRLF should parse: ${r1.diagnostics}');
      final dumped1 = Dumper.dump(r1.root!);
      // Dumper emits LF (deliberate canonicalisation) — second dump must
      // be byte-identical to the first.
      final r2 = Parser.parse(dumped1);
      expect(r2.diagnostics, isEmpty);
      final dumped2 = Dumper.dump(r2.root!);
      expect(dumped2, dumped1);
    });

    test('CRLF inside line-comment terminator', () {
      const src = '{ a: 1, // trail\r\n  b: 2 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty,
          reason: 'CRLF after // should parse: ${r.diagnostics}');
    });
  });

  group('idempotent canonicalisation', () {
    // dump(parse(src)) == dump(parse(dump(parse(src)))) — the first dump
    // canonicalises whitespace; subsequent cycles are byte-stable.
    final corpus = <String, String>{
      'simple map': '{ a: 1, b: "x" }',
      'leading + trailing comments': '''
{
  // lead
  a: 1, // trail
  b: 2
}
''',
      'block comment': '{ /* before */ a: 1 }',
      'nested': '{ outer: { inner: [1, 2, 3] } }',
      'string escapes': r'{ s: "tab\there\nthen done" }',
      'unquoted + single-quoted': "{ key: 'value' }",
      'numbers': '{ a: 0, b: 1.5, c: -3, d: 1e2 }',
      'top-of-file comment': '// banner\n{ a: 1 }',
    };
    for (final entry in corpus.entries) {
      test(entry.key, () {
        final r1 = Parser.parse(entry.value);
        expect(r1.diagnostics, isEmpty);
        final dump1 = Dumper.dump(r1.root!);
        final r2 = Parser.parse(dump1);
        expect(r2.diagnostics, isEmpty);
        final dump2 = Dumper.dump(r2.root!);
        expect(dump2, dump1, reason: 'second dump diverged from first');
        // One more cycle for paranoia.
        final r3 = Parser.parse(dump2);
        final dump3 = Dumper.dump(r3.root!);
        expect(dump3, dump2);
      });
    }
  });

  group('comments at every grammar position (Phase 4 corpus)', () {
    // The JSON5 spec allows whitespace (including comments) at every
    // grammar position. Today's parser (parser.dart:192-208) rejects
    // comments between key/`:`, `:`/value, and value/`,`. Each test here
    // documents the expected end-state (parses successfully, captures
    // comment as peer) but is skipped until Phase 4 fixes the parser.
    //
    // To track progress on the Phase 4 fix, drop the `skip:` argument and
    // re-run.
    test('comment between key and ":"', () {
      const src = '{ a /* between */ : 1 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final root = r.root! as JsonObject;
      final hasComment = root.properties.any((p) =>
          p is CommentLine && p.comment.text.contains('between'));
      expect(hasComment, isTrue);
    }, skip: 'pending Phase 4 parser comment-position fix');

    test('comment between ":" and value', () {
      const src = '{ a: /* between */ 1 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
    }, skip: 'pending Phase 4 parser comment-position fix');

    test('comment between value and ","', () {
      const src = '{ a: 1 /* between */ , b: 2 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
    }, skip: 'pending Phase 4 parser comment-position fix');

    test('comment between "," and next key', () {
      // This already works today (handled by _collectStandaloneComments)
      // — included in the corpus to make the difference explicit.
      const src = '{ a: 1, /* between */ b: 2 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
    });
  });
}
