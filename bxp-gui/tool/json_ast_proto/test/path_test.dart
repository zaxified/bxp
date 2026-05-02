import 'package:test/test.dart';

import 'package:json_ast_proto/ast.dart';
import 'package:json_ast_proto/parser.dart';
import 'package:json_ast_proto/path.dart';

JsonAstNode parseOk(String src) {
  final r = Parser.parse(src);
  expect(r.diagnostics, isEmpty, reason: 'parse errors: ${r.diagnostics}');
  return r.root!;
}

void main() {
  group('resolveNode / resolveParent — Map', () {
    test('top-level key', () {
      final root = parseOk('{ a: 1, b: 2 }');
      final n = resolveNode(root, ['a']);
      expect(n, isA<JsonNumber>());
      expect((n as JsonNumber).rawText, '1');
    });

    test('nested key', () {
      final root = parseOk('{ a: { b: { c: "x" } } }');
      final n = resolveNode(root, ['a', 'b', 'c']);
      expect((n as JsonString).value, 'x');
    });

    test('missing key throws AstPathError', () {
      final root = parseOk('{ a: 1 }');
      expect(() => resolveNode(root, ['missing']),
          throwsA(isA<AstPathError>()));
    });

    test('parent ref points at the JsonProperty in raw children', () {
      final root = parseOk('{ a: 1, b: 2 }');
      final ref = resolveParent(root, ['b']);
      expect(ref.isObject, isTrue);
      final prop = ref.children[ref.index] as JsonProperty;
      expect(prop.key, 'b');
    });
  });

  group('resolveNode — Array', () {
    test('real index skips standalone comments', () {
      // CommentLine before element 1 should not shift its real index.
      final root = parseOk('[ "x",\n  // hi\n  "y", "z" ]');
      // (the inline-array form parses fine; comment before "y" makes it
      // multi-line)
      final n = resolveNode(root, ['1']);
      expect((n as JsonString).value, 'y');
    });

    test('out of range throws', () {
      final root = parseOk('[1, 2]');
      expect(() => resolveNode(root, ['5']), throwsA(isA<AstPathError>()));
    });

    test('non-numeric segment throws', () {
      final root = parseOk('[1, 2]');
      expect(() => resolveNode(root, ['oops']),
          throwsA(isA<AstPathError>()));
    });
  });

  group('realElementCount', () {
    test('counts non-comment children', () {
      final root = parseOk('[\n  1,\n  // c\n  2,\n  3\n]');
      final arr = root as JsonArray;
      expect(realElementCount(arr.elements), 3);
    });
  });

  group('findCommentByGlobalN — source order', () {
    test('finds standalone, leading and trailing in order', () {
      final src = '''
// first leading on root
{
  // before-a
  a: 1, // trailing-a
  b: 2,
  // standalone-between
  c: 3
}
''';
      final root = parseOk(src);
      // Walk order: root.leadingComments[0]="first leading on root" → N=1
      // then a's leading "before-a" → N=2
      // then a's trailing "trailing-a" → N=3
      // then standalone-between → N=4
      expect(findCommentByGlobalN(root, 1)!.comment.text,
          contains('first leading'));
      expect(findCommentByGlobalN(root, 2)!.comment.text,
          contains('before-a'));
      expect(findCommentByGlobalN(root, 3)!.comment.text,
          contains('trailing-a'));
      expect(findCommentByGlobalN(root, 4)!.comment.text,
          contains('standalone-between'));
      expect(findCommentByGlobalN(root, 99), isNull);
    });

    test('CommentLocation.delete removes from container', () {
      final root = parseOk('{\n  // c1\n  a: 1\n}');
      // N=1 = leading on `a`
      final loc = findCommentByGlobalN(root, 1)!;
      expect(loc.kind, CommentLocationKind.leading);
      loc.delete();
      // After delete, no comments at all.
      expect(findCommentByGlobalN(root, 1), isNull);
    });
  });

  group('resolveNode — \$comm_N last segment', () {
    test('returns CommentLine wrapper', () {
      final root = parseOk('{\n  // c1\n  a: 1\n}');
      final n = resolveNode(root, [r'$comm_1']);
      expect(n, isA<CommentLine>());
      expect((n as CommentLine).comment.text, contains('c1'));
    });

    test('invalid N throws', () {
      final root = parseOk('{ a: 1 }');
      expect(() => resolveNode(root, [r'$comm_3']),
          throwsA(isA<AstPathError>()));
    });

    test('resolveParent rejects \$comm_N', () {
      final root = parseOk('{\n  // c1\n  a: 1\n}');
      expect(() => resolveParent(root, [r'$comm_1']),
          throwsA(isA<AstPathError>()));
    });
  });
}
