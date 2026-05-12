import 'package:test/test.dart';

import 'package:json5_ast/ast.dart';
import 'package:json5_ast/parser.dart';
import 'package:json5_ast/dumper.dart';
import 'package:json5_ast/operations.dart';
import 'package:json5_ast/path.dart';
import 'package:json5_ast/value_builder.dart';

JsonAstNode parseOk(String src) {
  final r = Parser.parse(src);
  expect(r.diagnostics, isEmpty, reason: 'parse errors: ${r.diagnostics}');
  return r.root!;
}

/// Round-trip helper: dump → parse again → assert no diagnostics.
JsonAstNode roundTrip(JsonAstNode root) {
  final out = Dumper.dump(root);
  final r = Parser.parse(out);
  expect(r.diagnostics, isEmpty,
      reason: 'reparse failed:\n----\n$out\n----\nerrors: ${r.diagnostics}');
  return r.root!;
}

/// Compare two ASTs for logical (value) equality, ignoring comments and
/// formatting. Used to assert mutations produce expected logical state.
bool deepEqualValue(JsonAstNode a, JsonAstNode b) {
  if (a.runtimeType != b.runtimeType) return false;
  if (a is JsonNull) return true;
  if (a is JsonBool) return a.value == (b as JsonBool).value;
  if (a is JsonNumber) return a.rawText == (b as JsonNumber).rawText;
  if (a is JsonString) return a.value == (b as JsonString).value;
  if (a is JsonObject) {
    final aProps = a.properties.whereType<JsonProperty>().toList();
    final bProps = (b as JsonObject)
        .properties
        .whereType<JsonProperty>()
        .toList();
    if (aProps.length != bProps.length) return false;
    for (var i = 0; i < aProps.length; i++) {
      if (aProps[i].key != bProps[i].key) return false;
      if (!deepEqualValue(aProps[i].value, bProps[i].value)) return false;
    }
    return true;
  }
  if (a is JsonArray) {
    final aEls = a.elements.where((e) => e is! CommentLine).toList();
    final bEls = (b as JsonArray)
        .elements
        .where((e) => e is! CommentLine)
        .toList();
    if (aEls.length != bEls.length) return false;
    for (var i = 0; i < aEls.length; i++) {
      if (!deepEqualValue(aEls[i], bEls[i])) return false;
    }
    return true;
  }
  return false;
}

void main() {
  // ============================================================
  // setValue
  // ============================================================
  group('setValue', () {
    test('replaces Map scalar leaf', () {
      final root = parseOk('{ a: 1, b: "old" }');
      setValue(root, ['b'], JsonString('new'));
      expect((resolveNode(root, ['b']) as JsonString).value, 'new');
      roundTrip(root);
    });

    test('preserves leading + trailing comments on Map property', () {
      final root = parseOk('{\n  // lead\n  a: 1 // trail\n}');
      setValue(root, ['a'], JsonNumber('42'));
      final dumped = Dumper.dump(root);
      expect(dumped, contains('// lead'));
      expect(dumped, contains('// trail'));
      expect(dumped, contains('42'));
    });

    test('replaces List element and inherits its comments', () {
      // RAW indexing — path '0' is the leading CommentLine "// lead",
      // path '1' is the actual JsonNumber(1) we want to replace.
      // (4F.1 added a guard that throws if a setValue path lands on a
      // CommentLine peer; this test now uses the correct real-element
      // index and the leading comment must survive the replacement.)
      final root = parseOk('[\n  // lead\n  1, // trail\n  2\n]');
      setValue(root, ['1'], JsonNumber('99'));
      final dumped = Dumper.dump(root);
      expect(dumped, contains('99'));
      expect(dumped, contains('// lead'));
      expect(dumped, contains('// trail'));
    });

    test('cannot replace root', () {
      final root = parseOk('{ a: 1 }');
      expect(() => setValue(root, [], JsonNumber('1')),
          throwsA(isA<AstOpError>()));
    });

    test('setValueFromPlain converts Dart values', () {
      final root = parseOk('{ a: 1 }');
      setValueFromPlain(root, ['a'], 'hello');
      expect((resolveNode(root, ['a']) as JsonString).value, 'hello');
    });
  });

  // ============================================================
  // renameProperty
  // ============================================================
  group('renameProperty', () {
    test('renames Map key in place, preserving position and value', () {
      final root = parseOk('{ a: 1, b: 2, c: 3 }');
      renameProperty(root, ['b'], 'bb');
      final obj = root as JsonObject;
      final keys = obj.properties.whereType<JsonProperty>().map((p) => p.key).toList();
      expect(keys, ['a', 'bb', 'c']);
      expect((resolveNode(root, ['bb']) as JsonNumber).rawText, '2');
      roundTrip(root);
    });

    test('preserves leading and trailing comments', () {
      final root = parseOk('{\n  // lead\n  a: 1, // trail\n  b: 2\n}');
      renameProperty(root, ['a'], 'aa');
      final dumped = Dumper.dump(root);
      expect(dumped, contains('// lead'));
      expect(dumped, contains('// trail'));
      // Dumper aligns Map leaves so the value column may carry extra
      // spacing (`aa:  1` here because the longer sibling `b` widens the
      // column). Match the key:value pair regardless of padding.
      expect(dumped, matches(RegExp(r'aa:\s+1')));
    });

    test('renaming to same key is a no-op (no error)', () {
      final root = parseOk('{ a: 1 }');
      renameProperty(root, ['a'], 'a');
      expect((resolveNode(root, ['a']) as JsonNumber).rawText, '1');
    });

    test('rejects duplicate sibling key', () {
      final root = parseOk('{ a: 1, b: 2 }');
      expect(() => renameProperty(root, ['a'], 'b'),
          throwsA(isA<AstOpError>()));
    });

    test('rejects empty new key', () {
      final root = parseOk('{ a: 1 }');
      expect(() => renameProperty(root, ['a'], ''),
          throwsA(isA<AstOpError>()));
    });

    test('rejects empty path (cannot rename root)', () {
      final root = parseOk('{ a: 1 }');
      expect(() => renameProperty(root, [], 'x'),
          throwsA(isA<AstOpError>()));
    });

    test('rejects array index path (only Map keys are renamable)', () {
      final root = parseOk('{ xs: [1, 2, 3] }');
      expect(() => renameProperty(root, ['xs', '0'], 'first'),
          throwsA(isA<AstOpError>()));
    });
  });

  // ============================================================
  // deleteAt
  // ============================================================
  group('deleteAt', () {
    test('removes Map property (middle)', () {
      final root = parseOk('{ a: 1, b: 2, c: 3 }');
      deleteAt(root, ['b']);
      expect(() => resolveNode(root, ['b']),
          throwsA(isA<AstPathError>()));
      expect((resolveNode(root, ['c']) as JsonNumber).rawText, '3');
      roundTrip(root);
    });

    test('removes Map property (first)', () {
      final root = parseOk('{ a: 1, b: 2 }');
      deleteAt(root, ['a']);
      roundTrip(root);
      expect((root as JsonObject).properties.whereType<JsonProperty>().length, 1);
    });

    test('removes Map property (last)', () {
      final root = parseOk('{ a: 1, b: 2 }');
      deleteAt(root, ['b']);
      roundTrip(root);
      expect((root as JsonObject).properties.whereType<JsonProperty>().length, 1);
    });

    test('removes Map property (single)', () {
      final root = parseOk('{ only: 1 }');
      deleteAt(root, ['only']);
      roundTrip(root);
      expect((root as JsonObject).properties.whereType<JsonProperty>().length, 0);
    });

    test('removes List element (middle)', () {
      final root = parseOk('[1, 2, 3]');
      deleteAt(root, ['1']);
      expect(realElementCount((root as JsonArray).elements), 2);
      expect((resolveNode(root, ['1']) as JsonNumber).rawText, '3');
      roundTrip(root);
    });

    test('removes List element (first)', () {
      final root = parseOk('[1, 2, 3]');
      deleteAt(root, ['0']);
      expect((resolveNode(root, ['0']) as JsonNumber).rawText, '2');
    });

    test('removes List element (last)', () {
      final root = parseOk('[1, 2, 3]');
      deleteAt(root, ['2']);
      expect(realElementCount((root as JsonArray).elements), 2);
    });

    test('cannot delete root', () {
      final root = parseOk('{ a: 1 }');
      expect(() => deleteAt(root, []), throwsA(isA<AstOpError>()));
    });
  });

  // ============================================================
  // duplicateAt
  // ============================================================
  group('duplicateAt', () {
    test('Map duplicate requires newKey', () {
      final root = parseOk('{ a: 1 }');
      expect(() => duplicateAt(root, ['a']), throwsA(isA<AstOpError>()));
    });

    test('Map duplicate inserts after original with new key', () {
      final root = parseOk('{ a: 1, b: 2 }');
      duplicateAt(root, ['a'], newKey: 'a_copy');
      // Order: a, a_copy, b
      final keys = (root as JsonObject)
          .properties
          .whereType<JsonProperty>()
          .map((p) => p.key)
          .toList();
      expect(keys, ['a', 'a_copy', 'b']);
      expect((resolveNode(root, ['a_copy']) as JsonNumber).rawText, '1');
      roundTrip(root);
    });

    test('Map duplicate rejects existing key', () {
      final root = parseOk('{ a: 1, b: 2 }');
      expect(() => duplicateAt(root, ['a'], newKey: 'b'),
          throwsA(isA<AstOpError>()));
    });

    test('List duplicate (middle)', () {
      final root = parseOk('[10, 20, 30]');
      duplicateAt(root, ['1']);
      // Order: 10, 20, 20, 30
      final raw = (resolveNode(root, ['2']) as JsonNumber).rawText;
      expect(raw, '20');
      expect(realElementCount((root as JsonArray).elements), 4);
      roundTrip(root);
    });

    test('List duplicate (last)', () {
      final root = parseOk('[1, 2]');
      duplicateAt(root, ['1']);
      expect(realElementCount((root as JsonArray).elements), 3);
      expect((resolveNode(root, ['2']) as JsonNumber).rawText, '2');
      roundTrip(root);
    });

    test('Map duplicate deep-clones nested subtree', () {
      final root = parseOk('{ a: { x: 1 } }');
      duplicateAt(root, ['a'], newKey: 'a_copy');
      final orig = resolveNode(root, ['a']) as JsonObject;
      final dup = resolveNode(root, ['a_copy']) as JsonObject;
      expect(identical(orig, dup), isFalse);
      // Mutating duplicate doesn't affect original.
      setValue(root, ['a_copy', 'x'], JsonNumber('99'));
      expect((resolveNode(root, ['a', 'x']) as JsonNumber).rawText, '1');
      expect((resolveNode(root, ['a_copy', 'x']) as JsonNumber).rawText, '99');
    });
  });

  // ============================================================
  // moveAt
  // ============================================================
  group('moveAt', () {
    test('Map move +1 swaps adjacent keys', () {
      final root = parseOk('{ a: 1, b: 2, c: 3 }');
      moveAt(root, ['a'], 1);
      final keys = (root as JsonObject)
          .properties
          .whereType<JsonProperty>()
          .map((p) => p.key)
          .toList();
      expect(keys, ['b', 'a', 'c']);
      roundTrip(root);
    });

    test('Map move -1 swaps adjacent keys', () {
      final root = parseOk('{ a: 1, b: 2, c: 3 }');
      moveAt(root, ['c'], -1);
      final keys = (root as JsonObject)
          .properties
          .whereType<JsonProperty>()
          .map((p) => p.key)
          .toList();
      expect(keys, ['a', 'c', 'b']);
    });

    test('Map move out of bounds throws', () {
      final root = parseOk('{ a: 1, b: 2 }');
      expect(() => moveAt(root, ['a'], -1),
          throwsA(isA<AstOpError>()));
      expect(() => moveAt(root, ['b'], 1),
          throwsA(isA<AstOpError>()));
    });

    test('List move +1 swaps adjacent elements', () {
      final root = parseOk('[1, 2, 3]');
      moveAt(root, ['0'], 1);
      expect((resolveNode(root, ['0']) as JsonNumber).rawText, '2');
      expect((resolveNode(root, ['1']) as JsonNumber).rawText, '1');
      roundTrip(root);
    });

    test('List move -1 swaps adjacent elements', () {
      final root = parseOk('[1, 2, 3]');
      moveAt(root, ['2'], -1);
      expect((resolveNode(root, ['1']) as JsonNumber).rawText, '3');
      expect((resolveNode(root, ['2']) as JsonNumber).rawText, '2');
    });

    test('List move out of bounds throws', () {
      final root = parseOk('[1, 2]');
      expect(() => moveAt(root, ['0'], -1),
          throwsA(isA<AstOpError>()));
      expect(() => moveAt(root, ['1'], 1),
          throwsA(isA<AstOpError>()));
    });

    test('List move swaps with adjacent row (CommentLine peer)', () {
      // Phase 4: move = swap with adjacent CONTAINER entry (real or
      // comment). No group-swap. Path indices are RAW positions in
      // `elements`, matching trace_store's convention. Source parses to:
      // [CL(first), 1, CL(second), 2, 3] — value 2 sits at raw 3. Move
      // it -1 to swap with the preceding CommentLine(second).
      final root = parseOk('[\n  // first\n  1,\n  // second\n  2,\n  3\n]');
      moveAt(root, ['3'], -1);
      // Expected order: // first, 1, 2, // second, 3.
      final dumped = Dumper.dump(root);
      final firstPos = dumped.indexOf('// first');
      final onePos = dumped.indexOf('  1');
      final twoPos = dumped.indexOf('  2');
      final secondPos = dumped.indexOf('// second');
      expect(firstPos, lessThan(onePos));
      expect(onePos, lessThan(twoPos));
      expect(twoPos, lessThan(secondPos));
      roundTrip(root);
    });

    test('moveCommentAt swaps comment with adjacent row', () {
      // Map: real keys interleaved with standalone CommentLines.
      // {"a": 1, // c, "b": 2}  parses as [JsonProperty(a), CommentLine(c),
      // JsonProperty(b)] — Phase 4 unification.
      final root = parseOk('{\n  a: 1,\n  // c\n  b: 2\n}');
      // The comment is global N=1. Move it up: swap with JsonProperty(a).
      moveAt(root, ['\$comm_1'], -1);
      final dumped = Dumper.dump(root);
      final cPos = dumped.indexOf('// c');
      final aPos = dumped.indexOf('a:');
      expect(cPos, lessThan(aPos));
      roundTrip(root);
    });

    test('moveCommentAt down past last sibling throws out-of-bounds', () {
      final root = parseOk('{\n  a: 1,\n  // c\n}');
      expect(() => moveAt(root, ['\$comm_1'], 1),
          throwsA(isA<AstOpError>()));
    });

    test('illegal delta throws', () {
      final root = parseOk('[1, 2]');
      expect(() => moveAt(root, ['0'], 0), throwsA(isA<AstOpError>()));
      expect(() => moveAt(root, ['0'], 2), throwsA(isA<AstOpError>()));
    });
  });

  // ============================================================
  // insertProperty / insertElement
  // ============================================================
  group('insertProperty', () {
    test('appends after last existing property', () {
      final root = parseOk('{ a: 1, b: 2 }');
      insertProperty(root, [], 'c', JsonNumber('3'));
      final keys = (root as JsonObject)
          .properties
          .whereType<JsonProperty>()
          .map((p) => p.key)
          .toList();
      expect(keys, ['a', 'b', 'c']);
      roundTrip(root);
    });

    test('inserts at explicit index', () {
      final root = parseOk('{ a: 1, c: 3 }');
      insertProperty(root, [], 'b', JsonNumber('2'), atIndex: 1);
      final keys = (root as JsonObject)
          .properties
          .whereType<JsonProperty>()
          .map((p) => p.key)
          .toList();
      expect(keys, ['a', 'b', 'c']);
    });

    test('rejects existing key', () {
      final root = parseOk('{ a: 1 }');
      expect(() => insertProperty(root, [], 'a', JsonNumber('2')),
          throwsA(isA<AstOpError>()));
    });

    test('inserts into nested map', () {
      final root = parseOk('{ outer: { x: 1 } }');
      insertProperty(root, ['outer'], 'y', JsonNumber('2'));
      expect((resolveNode(root, ['outer', 'y']) as JsonNumber).rawText, '2');
      roundTrip(root);
    });

    test('throws if parent is not an object', () {
      final root = parseOk('{ a: [1, 2] }');
      expect(() => insertProperty(root, ['a'], 'x', JsonNumber('1')),
          throwsA(isA<AstOpError>()));
    });

    test('inserts into empty map', () {
      final root = parseOk('{}');
      insertProperty(root, [], 'first', JsonString('hello'));
      expect((resolveNode(root, ['first']) as JsonString).value, 'hello');
      roundTrip(root);
    });
  });

  group('insertElement', () {
    test('appends at end (index == realCount)', () {
      final root = parseOk('[1, 2]');
      insertElement(root, [], 2, JsonNumber('3'));
      expect((resolveNode(root, ['2']) as JsonNumber).rawText, '3');
      roundTrip(root);
    });

    test('inserts at front (index 0)', () {
      final root = parseOk('[2, 3]');
      insertElement(root, [], 0, JsonNumber('1'));
      expect((resolveNode(root, ['0']) as JsonNumber).rawText, '1');
      expect((resolveNode(root, ['1']) as JsonNumber).rawText, '2');
    });

    test('inserts in middle', () {
      final root = parseOk('[1, 3]');
      insertElement(root, [], 1, JsonNumber('2'));
      expect((resolveNode(root, ['1']) as JsonNumber).rawText, '2');
      expect((resolveNode(root, ['2']) as JsonNumber).rawText, '3');
    });

    test('clamps oversized index to end', () {
      final root = parseOk('[1, 2]');
      insertElement(root, [], 99, JsonNumber('3'));
      expect((resolveNode(root, ['2']) as JsonNumber).rawText, '3');
    });

    test('inserts into empty array', () {
      final root = parseOk('[]');
      insertElement(root, [], 0, JsonNumber('1'));
      expect((resolveNode(root, ['0']) as JsonNumber).rawText, '1');
      roundTrip(root);
    });

    test('throws if parent is not an array', () {
      final root = parseOk('{ a: { x: 1 } }');
      expect(() => insertElement(root, ['a'], 0, JsonNumber('1')),
          throwsA(isA<AstOpError>()));
    });
  });

  // ============================================================
  // Comment ops
  // ============================================================
  group('editComment', () {
    test('changes comment text', () {
      final root = parseOk('{\n  // old text\n  a: 1\n}');
      editComment(root, [r'$comm_1'], ' new text');
      final dumped = Dumper.dump(root);
      expect(dumped, contains('// new text'));
      expect(dumped, isNot(contains('// old text')));
      roundTrip(root);
    });

    test('throws on missing comment', () {
      final root = parseOk('{ a: 1 }');
      expect(() => editComment(root, [r'$comm_5'], 'x'),
          throwsA(isA<AstOpError>()));
    });
  });

  group('deleteComment', () {
    test('removes leading comment from Map property', () {
      final root = parseOk('{\n  // hi\n  a: 1\n}');
      deleteComment(root, [r'$comm_1']);
      final dumped = Dumper.dump(root);
      expect(dumped, isNot(contains('// hi')));
      roundTrip(root);
    });

    test('removes standalone CommentLine from List', () {
      final root = parseOk('[\n  1,\n  // mid\n  2\n]');
      // N=1 here is the standalone CommentLine "// mid"
      deleteComment(root, [r'$comm_1']);
      final dumped = Dumper.dump(root);
      expect(dumped, isNot(contains('// mid')));
      roundTrip(root);
    });

    test('removes trailing inline comment', () {
      final root = parseOk('{ a: 1 // trail\n}');
      deleteComment(root, [r'$comm_1']);
      final dumped = Dumper.dump(root);
      expect(dumped, isNot(contains('// trail')));
    });
  });

  group('insertLeadingComment', () {
    test('adds leading comment to Map property', () {
      final root = parseOk('{ a: 1 }');
      insertLeadingComment(root, ['a'], CommentStyle.line, ' added');
      final dumped = Dumper.dump(root);
      expect(dumped, contains('// added'));
      // Comment should be on the line above `a:`.
      final addedLine = dumped.split('\n').indexWhere((l) => l.contains('// added'));
      final aLine = dumped.split('\n').indexWhere((l) => l.contains('a:'));
      expect(addedLine, lessThan(aLine));
      roundTrip(root);
    });

    test('adds leading CommentLine before List element', () {
      final root = parseOk('[1, 2, 3]');
      insertLeadingComment(root, ['1'], CommentStyle.line, ' before-2');
      final dumped = Dumper.dump(root);
      final commPos = dumped.indexOf('// before-2');
      final twoPos = dumped.indexOf('2');
      expect(commPos, isPositive);
      expect(commPos, lessThan(twoPos));
      roundTrip(root);
    });

    test('rejects empty anchor path', () {
      final root = parseOk('{ a: 1 }');
      expect(
          () => insertLeadingComment(root, [], CommentStyle.line, 'x'),
          throwsA(isA<AstOpError>()));
    });

    test('block comment style', () {
      final root = parseOk('{ a: 1 }');
      insertLeadingComment(root, ['a'], CommentStyle.block, ' block ');
      final dumped = Dumper.dump(root);
      expect(dumped, contains('/* block */'));
    });
  });

  // ============================================================
  // Round-trip parity: parse → mutate → dump → parse → deepEqualValue
  // ============================================================
  group('parity round-trip on realistic snippets', () {
    test('chain of edits preserves logical state', () {
      final src = '''
{
  // header
  templates: {
    A: { fee: 0.5 },
    B: { fee: 1.0 }
  },
  rules: [
    { name: "first", enabled: true },
    { name: "second", enabled: false }
  ]
}
''';
      final root = parseOk(src);
      // Edit fee of A.
      setValue(root, ['templates', 'A', 'fee'], JsonNumber('0.75'));
      // Duplicate A as A_copy.
      duplicateAt(root, ['templates', 'A'], newKey: 'A_copy');
      // Insert new rule.
      insertElement(root, ['rules'], 2,
          astFromValue({'name': 'third', 'enabled': true}));
      // Move first rule down.
      moveAt(root, ['rules', '0'], 1);
      // Delete A_copy.
      deleteAt(root, ['templates', 'A_copy']);

      final reparsed = roundTrip(root);
      // Logical state check.
      expect((resolveNode(reparsed, ['templates', 'A', 'fee']) as JsonNumber)
              .rawText, '0.75');
      expect(realElementCount((reparsed as JsonObject)
          .properties.whereType<JsonProperty>()
          .firstWhere((p) => p.key == 'rules').value
          .let((v) => (v as JsonArray).elements)), 3);
      // First rule is now "second" (because we moved "first" down).
      expect(
          (resolveNode(reparsed, ['rules', '0', 'name']) as JsonString).value,
          'second');
      expect(
          (resolveNode(reparsed, ['rules', '2', 'name']) as JsonString).value,
          'third');
    });
  });

  // ============================================================
  // Comment ownership across delete / duplicate
  // ============================================================
  group('deleteAt with adjacent comments', () {
    test('removes leading standalone comment together with property', () {
      final root = parseOk('{\n  // about a\n  a: 1,\n  b: 2\n}\n');
      deleteAt(root, ['a']);
      final dumped = Dumper.dump(root);
      // Leading comment must vanish with `a`, not re-attach to `b`.
      expect(dumped, isNot(contains('about a')));
      expect(dumped, matches(RegExp(r'b:\s+2')));
    });

    test('removes trailing inline comment together with property', () {
      final root = parseOk('{\n  a: 1, // trail-a\n  b: 2\n}\n');
      deleteAt(root, ['a']);
      final dumped = Dumper.dump(root);
      // Trailing inline comment is owned by the deleted entry.
      expect(dumped, isNot(contains('trail-a')));
      expect(dumped, matches(RegExp(r'b:\s+2')));
    });

    test('preserves comments on neighbouring property', () {
      final root = parseOk(
          '{\n  // about a\n  a: 1,\n  // about b\n  b: 2\n}\n');
      deleteAt(root, ['a']);
      final dumped = Dumper.dump(root);
      expect(dumped, isNot(contains('about a')));
      expect(dumped, contains('about b'));
      expect(dumped, matches(RegExp(r'b:\s+2')));
    });
  });

  group('duplicateAt with adjacent comments', () {
    test('Map duplicate does NOT clone leading comments', () {
      // Phase 1 pinned this — leading is a peer entry NOT structurally
      // tied to the property, so the duplicate appears without it.
      final root = parseOk('{\n  // about a\n  a: 1\n}\n');
      duplicateAt(root, ['a'], newKey: 'a_copy');
      final dumped = Dumper.dump(root);
      // Original comment still belongs to `a`; not cloned for `a_copy`.
      expect('about a'.allMatches(dumped).length, 1);
      expect(dumped, contains('a_copy'));
    });

    test('List duplicate does NOT clone leading comments', () {
      final root = parseOk('[\n  // about 0\n  10,\n  20\n]\n');
      duplicateAt(root, ['1']);
      final dumped = Dumper.dump(root);
      expect('about 0'.allMatches(dumped).length, 1);
    });

    test('Map duplicate clones trailing-inline comment to both rows', () {
      // Phase 4F.4: without the fix the dumper attaches the trailing-
      // inline to the duplicate (closer preceding row) and the original
      // loses it (steal). With the clone in place both rows render
      // their own copy.
      final root = parseOk('{\n  a: 1, // trail of a\n  z: 99\n}\n');
      duplicateAt(root, ['a'], newKey: 'a_copy');
      final dumped = Dumper.dump(root);
      expect('trail of a'.allMatches(dumped).length, 2,
          reason: 'expected trail comment on both rows; got:\n$dumped');
      expect(dumped, contains('a_copy'));
    });

    test('List duplicate clones trailing-inline comment to both rows', () {
      final root = parseOk('[\n  10, // trail of 10\n  20\n]\n');
      duplicateAt(root, ['0']);
      final dumped = Dumper.dump(root);
      expect('trail of 10'.allMatches(dumped).length, 2);
    });
  });

  // ============================================================
  // Path ops on a CommentLine peer (raw array indexing)
  // ============================================================
  //
  // path.dart uses RAW indexing — list path '1' refers to elements[1],
  // which can be a CommentLine peer. Phase 4F.1 added guards that throw
  // AstOpError so a numeric path can no longer silently corrupt a
  // comment.
  group('CommentLine peer guards', () {
    test('setValue on a CommentLine peer throws AstOpError', () {
      // Source: `[ // c\n 1, 2 ]` — elements[0] is the CommentLine,
      // elements[1] is the number 1, elements[2] is the number 2.
      final root = parseOk('[\n  // c\n  1,\n  2\n]\n');
      expect(
        () => setValue(root, ['0'], JsonNumber('99')),
        throwsA(isA<AstOpError>()),
      );
    });

    test('deleteAt on a CommentLine peer throws AstOpError', () {
      final root = parseOk('[\n  // c\n  1,\n  2\n]\n');
      expect(
        () => deleteAt(root, ['0']),
        throwsA(isA<AstOpError>()),
      );
    });

    test('duplicateAt on a CommentLine peer throws AstOpError', () {
      final root = parseOk('[\n  // c\n  1,\n  2\n]\n');
      expect(
        () => duplicateAt(root, ['0']),
        throwsA(isA<AstOpError>()),
      );
    });
  });
}

extension _Let<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
}
