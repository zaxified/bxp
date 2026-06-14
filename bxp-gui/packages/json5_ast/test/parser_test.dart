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
      // ECMAScript ExponentPart requires at least one digit after `e`/`E`.
      // Phase 4E.1: tokenizer rejects the lenient form so other JSON5
      // readers don't choke on json5_ast output.
      'exponent with no digit': '{ a: 1e }',
      'exponent with sign no digit': '{ a: 1E+ }',
      'exponent negative no digit': '{ a: 2.5e- }',
    };
    for (final entry in inputs.entries) {
      test(entry.key, () {
        final r = Parser.parse(entry.value);
        expect(r.diagnostics, isNotEmpty, reason: 'expected diagnostic, got none');
        expect(r.hasErrors, isTrue);
      });
    }
  });

  group('deep nesting surfaces a diagnostic, never a StackOverflowError', () {
    // Pathological bracket nesting (well inside a 1 MB file) must bail with
    // a ParseDiagnostic rather than recursing into a StackOverflowError that
    // would escape Parser.parse's catch clauses and crash the loader.
    test('5000-deep array nest yields an error diagnostic', () {
      final src = '${'[' * 5000}${']' * 5000}';
      final r = Parser.parse(src);
      expect(r.diagnostics, isNotEmpty,
          reason: 'expected a depth diagnostic, got none');
      expect(r.hasErrors, isTrue);
    });

    test('5000-deep object nest yields an error diagnostic', () {
      final src = '${'{a:' * 5000}1${'}' * 5000}';
      final r = Parser.parse(src);
      expect(r.diagnostics, isNotEmpty,
          reason: 'expected a depth diagnostic, got none');
      expect(r.hasErrors, isTrue);
    });

    test('moderately nested config still parses clean', () {
      // 32 levels — below the cap — must remain valid.
      final src = '${'[' * 32}1${']' * 32}';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty,
          reason: 'sane nesting should parse: ${r.diagnostics}');
    });
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

  group('comments at every grammar position', () {
    // The JSON5 spec — https://spec.json5.org/ — says "comments may
    // appear before and after any JSON5Token". Each test here covers
    // one inter-token gap; together they assert the parser is fully
    // spec-compliant for whitespace-and-comment placement.
    //
    // Phase 4D added `_skipNewlinesAndComments` to capture comments at
    // every position; before that, three of these tests were skipped.

    // ── Object positions ────────────────────────────────────────────
    test('object: comment between key and ":"', () {
      const src = '{ a /* between */ : 1 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final root = r.root! as JsonObject;
      final hasComment = root.properties.any((p) =>
          p is CommentLine && p.comment.text.contains('between'));
      expect(hasComment, isTrue);
    });

    test('object: comment between ":" and value', () {
      const src = '{ a: /* between */ 1 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final root = r.root! as JsonObject;
      final hasComment = root.properties.any((p) =>
          p is CommentLine && p.comment.text.contains('between'));
      expect(hasComment, isTrue);
    });

    test('object: comment between value and ","', () {
      const src = '{ a: 1 /* between */ , b: 2 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final root = r.root! as JsonObject;
      final hasComment = root.properties.any((p) =>
          p is CommentLine && p.comment.text.contains('between'));
      expect(hasComment, isTrue);
    });

    test('object: comment between value and "}" (no trailing comma)', () {
      const src = '{ a: 1 /* between */ }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final root = r.root! as JsonObject;
      final hasComment = root.properties.any((p) =>
          p is CommentLine && p.comment.text.contains('between'));
      expect(hasComment, isTrue);
    });

    test('object: comment between "," and next key', () {
      const src = '{ a: 1, /* between */ b: 2 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
    });

    // ── Array positions ─────────────────────────────────────────────
    test('array: comment between value and ","', () {
      const src = '[ 1 /* between */ , 2 ]';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final root = r.root! as JsonArray;
      final hasComment = root.elements.any((e) =>
          e is CommentLine && e.comment.text.contains('between'));
      expect(hasComment, isTrue);
    });

    test('array: comment between value and "]" (no trailing comma)', () {
      const src = '[ 1 /* between */ ]';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final root = r.root! as JsonArray;
      final hasComment = root.elements.any((e) =>
          e is CommentLine && e.comment.text.contains('between'));
      expect(hasComment, isTrue);
    });

    test('array: comment between "[" and first element', () {
      const src = '[ /* between */ 1, 2 ]';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
    });

    // ── Stress: every position at once + idempotent canonicalisation
    test('object: comments in every position simultaneously', () {
      // Pre-grammar `{`, after-key, after-`:`, between value and `,`,
      // before next key, mid-object — all in one source.
      const src =
          '{ /*0*/ a /*1*/ : /*2*/ 1 /*3*/ , /*4*/ b /*5*/ : /*6*/ 2 /*7*/ }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty,
          reason: 'every-position parse failed: ${r.diagnostics}');
      final dump1 = Dumper.dump(r.root!);
      // Idempotent: a second parse + dump must return the same bytes.
      final r2 = Parser.parse(dump1);
      expect(r2.diagnostics, isEmpty);
      final dump2 = Dumper.dump(r2.root!);
      expect(dump2, dump1, reason: 'second dump diverged from first');
      // All eight comments must survive the round-trip.
      for (var i = 0; i < 8; i++) {
        expect(dump2, contains('$i'),
            reason: 'comment /*$i*/ missing after round-trip');
      }
    });

    test('array: comments in every position simultaneously', () {
      const src = '[ /*0*/ 1 /*1*/ , /*2*/ 2 /*3*/ ]';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final dump1 = Dumper.dump(r.root!);
      final r2 = Parser.parse(dump1);
      expect(r2.diagnostics, isEmpty);
      final dump2 = Dumper.dump(r2.root!);
      expect(dump2, dump1);
      for (var i = 0; i < 4; i++) {
        expect(dump2, contains('$i'));
      }
    });
  });

  group('canonicalisation across parser/dumper boundary', () {
    // Phase 4E: small spec-compliance touch-ups so json5_ast output is
    // accepted by other (strict) JSON5 readers and so a key happens to
    // collide with a JSON5 keyword cannot break round-trip.

    test('exponent with digit parses (sanity)', () {
      const src = '{ a: 1e2, b: 1.5E-3, c: 1E+0 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      // Round-trip preserves exponent form verbatim.
      final dump = Dumper.dump(r.root!);
      expect(dump, contains('1e2'));
      expect(dump, contains('1.5E-3'));
      expect(dump, contains('1E+0'));
    });

    test('keyword-shaped key emitted with quotes (round-trip safe)', () {
      const src = '{ "null": 1 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final dump1 = Dumper.dump(r.root!);
      // Must be quoted on emit — bare `null:` would re-parse as nullLit
      // and the parser would reject it as a key.
      expect(dump1, contains('"null":'));
      // Round-trip must succeed without diagnostics.
      final r2 = Parser.parse(dump1);
      expect(r2.diagnostics, isEmpty);
      final dump2 = Dumper.dump(r2.root!);
      expect(dump2, dump1);
    });

    test('multiple keyword keys all force-quoted', () {
      const src =
          '{ "true": 1, "false": 2, "null": 3, "Infinity": 4, "NaN": 5, "undefined": 6 }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final dump = Dumper.dump(r.root!);
      for (final kw in ['true', 'false', 'null', 'Infinity', 'NaN', 'undefined']) {
        expect(dump, contains('"$kw":'),
            reason: 'expected "$kw": in dump, got:\n$dump');
      }
      // And idempotent.
      final r2 = Parser.parse(dump);
      expect(r2.diagnostics, isEmpty);
      expect(Dumper.dump(r2.root!), dump);
    });

    test('non-keyword identifier keys stay bare', () {
      const src = '{ data_dir: ".", null_count: 0, trueOrFalse: false }';
      final r = Parser.parse(src);
      expect(r.diagnostics, isEmpty);
      final dump = Dumper.dump(r.root!);
      // Plain identifiers (even those CONTAINING keyword substrings) are
      // not quoted — the regex match is exact-keyword.
      expect(dump, contains('data_dir:'));
      expect(dump, contains('null_count:'));
      expect(dump, contains('trueOrFalse:'));
    });
  });
}
