import 'package:test/test.dart';

import 'package:json_ast_proto/ast.dart';
import 'package:json_ast_proto/dumper.dart';
import 'package:json_ast_proto/operations.dart';
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
    test('RAW index addresses elements (CommentLine peers count)', () {
      // The path resolver uses RAW indexing so trace_store and the AST
      // patcher agree on which physical entry a path segment selects.
      // A standalone CommentLine before "y" gets raw index 1; "y" then
      // sits at raw index 2.
      final root = parseOk('[ "x",\n  // hi\n  "y", "z" ]');
      expect((resolveNode(root, ['0']) as JsonString).value, 'x');
      expect(resolveNode(root, ['1']) is CommentLine, isTrue);
      expect((resolveNode(root, ['2']) as JsonString).value, 'y');
      expect((resolveNode(root, ['3']) as JsonString).value, 'z');
    });

    test('out of range throws', () {
      final root = parseOk('[1, 2]');
      expect(() => resolveNode(root, ['5']), throwsA(isA<AstPathError>()));
    });

    test('regression: deleteAt with CommentLine peer hits path target', () {
      // Phase 5c bugfix: prior real-only path semantics caused deleteAt
      // (and friends) to silently target the wrong element when a
      // standalone CommentLine sat before the addressed real entry.
      // trace_store records RAW indices; the resolver must agree.
      //
      // Comment-ownership rule (added in the audit follow-up): a
      // standalone CommentLine immediately preceding the deleted entry
      // is treated as that entry's leading comment and removed too —
      // otherwise it visually re-attaches to whatever sibling follows
      // and silently mis-documents it.
      final root = parseOk('[\n  "r0",\n  // doc-for-r1\n  "r1",\n  "r2"\n]');
      // UI path for r1 (raw index 2 in elements/adapter Map list).
      deleteAt(root, ['2']);
      final dumped = Dumper.dump(root);
      expect(dumped.contains('"r1"'), isFalse,
          reason: 'r1 must be deleted, not r2');
      expect(dumped.contains('"r0"'), isTrue);
      expect(dumped.contains('"r2"'), isTrue);
      expect(dumped.contains('// doc-for-r1'), isFalse,
          reason: "r1's leading comment must vanish with it");
    });

    test('deleteAt keeps unrelated leading comments above siblings', () {
      // Only the contiguous run of CommentLines immediately preceding
      // the deleted entry travels with it. A comment owned by an earlier
      // sibling (separated by that sibling's value) must stay put.
      // Raw layout: 0=comment, 1=r0, 2=r1, 3=r2.
      final root = parseOk(
        '[\n  // doc-for-r0\n  "r0",\n  "r1",\n  "r2"\n]',
      );
      deleteAt(root, ['2']); // delete r1 — no leading comment of its own
      final dumped = Dumper.dump(root);
      expect(dumped.contains('"r1"'), isFalse);
      expect(dumped.contains('"r0"'), isTrue);
      expect(dumped.contains('"r2"'), isTrue);
      expect(dumped.contains('// doc-for-r0'), isTrue,
          reason: "r0's leading comment is unrelated and must remain");
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
      // Phase 5e: every comment is a CommentLine peer entry; the location
      // returned points into its container. No more standalone-vs-trailing
      // distinction at this layer.
      final loc = findCommentByGlobalN(root, 1)!;
      expect(loc.isInlineTrailing, isFalse);
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

  group('globalCommentNumbering', () {
    test('round-trips against findCommentByGlobalN source order', () {
      final root = parseOk(
          '{\n  // a\n  x: 1,\n  arr: [\n    // b\n    "v"\n  ],\n  y: 2 // c\n}');
      final numbering = globalCommentNumbering(root);
      expect(numbering.length, 3);
      numbering.forEach((cl, n) {
        final loc = findCommentByGlobalN(root, n);
        expect(loc, isNotNull);
        expect(identical(loc!.comment, cl.comment), isTrue,
            reason: 'numbering N=$n must round-trip via findCommentByGlobalN');
      });
    });
  });
}
