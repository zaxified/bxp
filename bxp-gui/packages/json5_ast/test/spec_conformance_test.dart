/// JSON5 conformance + dump-safety regressions found by the S7 audit:
/// number/whitespace/key lexing, missing-comma rejection, comment text that
/// would corrupt the dump, and inline-comment ownership on insert.
library;

import 'package:test/test.dart';

import 'package:json5_ast/ast.dart';
import 'package:json5_ast/dumper.dart';
import 'package:json5_ast/operations.dart';
import 'package:json5_ast/parser.dart';

void main() {
  group('numbers', () {
    for (final src in ['{ a: . }', '{ a: -. }', '{ a: +.e5 }']) {
      test('digitless mantissa rejected: $src', () {
        final r = Parser.parse(src);
        expect(r.hasErrors, isTrue);
        expect(r.root, isNull);
      });
    }
    for (final v in ['.5', '5.', '-.5', '+1', '0xFF', '-Infinity', '1e-7']) {
      test('valid number kept verbatim: $v', () {
        final r = Parser.parse('{ a: $v }');
        expect(r.hasErrors, isFalse, reason: '${r.diagnostics.map((d) => d.message)}');
        expect(Dumper.dump(r.root!), contains(v));
      });
    }
  });

  group('whitespace and identifiers', () {
    test('leading BOM, NBSP, form feed are whitespace', () {
      final r = Parser.parse('\uFEFF{\u00A0a:\f1 }');
      expect(r.hasErrors, isFalse);
    });
    test('non-ASCII bare key parses and dumps quoted', () {
      final r = Parser.parse('{ klíč: 1, 名前: 2 }');
      expect(r.hasErrors, isFalse);
      final out = Dumper.dump(r.root!);
      expect(out, contains('"klíč"'));
      expect(Parser.parse(out).hasErrors, isFalse);
    });
    test('reserved words are valid bare keys', () {
      final r = Parser.parse('{ null: 1, true: 2, Infinity: 3 }');
      expect(r.hasErrors, isFalse, reason: '${r.diagnostics.map((d) => d.message)}');
      final out = Dumper.dump(r.root!);
      final again = Parser.parse(out);
      expect(again.hasErrors, isFalse);
      expect(Dumper.dump(again.root!), out);
    });
  });

  group('structure', () {
    for (final src in ['{ a: 1 b: 2 }', '[1 2]', '{ a: 1\n b: 2 }', '[1, 2 3]']) {
      test('missing comma is an error: ${src.replaceAll('\n', '\\n')}', () {
        final r = Parser.parse(src);
        expect(r.hasErrors, isTrue);
        expect(r.diagnostics.first.message, contains("expected ','"));
      });
    }
    test('unterminated containers report end of input', () {
      for (final src in ['{ a: 1', '[1,', '{ a:', '[']) {
        final r = Parser.parse(src);
        expect(r.hasErrors, isTrue, reason: src);
      }
    });
    test('surrogate pair escape round-trips', () {
      final r = Parser.parse(r'{ a: "\uD83D\uDE00" }');
      final v = ((r.root as JsonObject).properties.first as JsonProperty).value
          as JsonString;
      expect(v.value, '\u{1F600}');
    });
  });

  group('dump never emits a comment that breaks the next parse', () {
    test('line comment with newline stays one comment', () {
      final r = Parser.parse('{ a: 1 }');
      insertLeadingComment(r.root!, ['a'], CommentStyle.line, ' x\nb: 2');
      final out = Dumper.dump(r.root!);
      final again = Parser.parse(out);
      expect(again.hasErrors, isFalse, reason: out);
      expect(((again.root as JsonObject).properties.whereType<JsonProperty>())
          .length, 1);
    });
    test('block comment containing */ stays one comment', () {
      final r = Parser.parse('{ a: 1 }');
      insertLeadingComment(r.root!, ['a'], CommentStyle.block, ' x */ b: 2 /* ');
      final out = Dumper.dump(r.root!);
      final again = Parser.parse(out);
      expect(again.hasErrors, isFalse, reason: out);
      expect(((again.root as JsonObject).properties.whereType<JsonProperty>())
          .length, 1);
    });
    test('CRLF line comment keeps its CR', () {
      final r = Parser.parse('{\r\n  // c\r\n  a: 1\r\n}\r\n');
      final out = Dumper.dump(r.root!);
      expect(out, contains('// c\r\n'));
    });
  });

  group('inline comment ownership on insert', () {
    test('insertProperty append does not steal the last row\'s inline note', () {
      final r = Parser.parse('{\n  a: 1, // note on a\n}\n');
      insertProperty(r.root!, [], 'b', JsonNumber('2'));
      final out = Dumper.dump(r.root!);
      final lines = out.split('\n');
      expect(lines.firstWhere((l) => l.contains('a:')), contains('note on a'));
      expect(lines.firstWhere((l) => l.contains('b:')), isNot(contains('note')));
    });
    test('insertProperty atIndex before an inline note keeps it with its row', () {
      final r = Parser.parse('{\n  a: 1, // note on a\n  c: 3\n}\n');
      insertProperty(r.root!, [], 'b', JsonNumber('2'), atIndex: 1);
      final out = Dumper.dump(r.root!);
      final lines = out.split('\n');
      expect(lines.firstWhere((l) => l.contains('a:')), contains('note on a'));
      expect(lines.firstWhere((l) => l.contains('b:')), isNot(contains('note')));
    });
    test('insertElement before an inline note keeps it with its row', () {
      final r = Parser.parse('[\n  1, // one\n  3\n]\n');
      insertElement(r.root!, [], 1, JsonNumber('2'));
      final lines = Dumper.dump(r.root!).split('\n');
      expect(lines.firstWhere((l) => l.contains('1,')), contains('one'));
      expect(lines.firstWhere((l) => l.contains('2,')), isNot(contains('one')));
    });
  });

  group('inline-object dump option', () {
    test('comment inside an array element object is not dropped', () {
      final r = Parser.parse('{ a: [ 1, // keep\n 2 ] }');
      const opt = DumperOptions(inlineObjectMax: 200);
      expect(Dumper.dump(r.root!, opt), contains('keep'));
    });
  });
}
