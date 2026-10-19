// Audit regressions for lib/services/dart_validator.dart: the per-keystroke
// tokenizer must never throw on half-typed input.

import 'package:bxp_gui/services/dart_validator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:json5_ast/ast.dart';
import 'package:json5_ast/parser.dart';

void main() {
  final v = DartValidator({'functions': <dynamic>[], 'config_schema': <dynamic>[]});
  final root = Parser.parse('{conversion_templates: {t: {input_schema: {}}}}').root!;

  test('validateExpr survives a trailing backslash inside a string literal', () {
    for (final src in [r"'abc\", r"UPPER('a\", r"'\", r"IF($a, 'x\\", "'", "'''"]) {
      expect(() => v.validateExpr(src, root: root, activeTemplateId: 't'), returnsNormally, reason: src);
    }
  });

  test('tree walk survives an unterminated [ in an expression string', () {
    for (final expr in ['[', 'UPPER([', '[abc', r"'a\"]) {
      final doc = Parser.parse(
              '{conversion_templates: {t: {input_schema: {\$x: ${_q(expr)}}}}}')
          .root as JsonAstNode;
      expect(() => v.validate(doc), returnsNormally, reason: expr);
    }
  });
}

String _q(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
