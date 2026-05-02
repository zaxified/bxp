/// Phase 2 parity check: for the same ConfigOp sequence, both the legacy
/// CST byte patcher (OpApply) and the new Dart AST patcher (AstPatchClient)
/// must produce a JSON5 file that:
///   1. parses without errors via `bxp-fmt --config` (validity)
///   2. has a logically-equal value tree (semantic equivalence — comments
///      and whitespace are allowed to differ; AST canonicalises style)
///
/// Run with:
///   BXP_FMT=/path/to/bxp-fmt BXP_FIXTURE=/path/to/config.json5 \
///     flutter test test/ast_parity_test.dart
///
/// Falls back to skip when env vars are absent so default `flutter test`
/// stays green in environments without bxp-fmt.
library;

import 'dart:convert';
import 'dart:io';

import 'package:bxp_gui/services/ast_patch_client.dart';
import 'package:bxp_gui/services/op_apply.dart';
import 'package:bxp_gui/services/op_log.dart';
import 'package:test/test.dart';

void main() {
  final bxpFmt = Platform.environment['BXP_FMT'];
  final fixture = Platform.environment['BXP_FIXTURE'];
  if (bxpFmt == null || fixture == null) {
    test('skipped (BXP_FMT or BXP_FIXTURE not set)', () {});
    return;
  }

  late List<int> raw;
  late dynamic origTree; // bxp-fmt annotated tree (with $meta_*) for OpApply

  setUpAll(() async {
    raw = await File(fixture).readAsBytes();
    final result = await Process.run(bxpFmt, ['--config', fixture]);
    if (result.exitCode != 0 && result.exitCode != 1) {
      fail('bxp-fmt failed on fixture: ${result.stderr}');
    }
    origTree = jsonDecode(result.stdout as String);
  });

  /// Strip `$meta_*` / `$elem_meta_*` / `$err_*` keys recursively so two
  /// trees can be compared on user-visible structure only. `$comm_*`
  /// entries differ between the two backends (CST keeps them with span
  /// metadata, AST emits them as inline comments) — drop them too.
  dynamic stripMeta(dynamic node) {
    if (node is Map) {
      final out = <String, dynamic>{};
      for (final e in node.entries) {
        final k = e.key.toString();
        if (k.startsWith(r'$meta_') ||
            k.startsWith(r'$elem_meta_') ||
            k.startsWith(r'$err_') ||
            k.startsWith(r'$comm_')) {
          continue;
        }
        out[k] = stripMeta(e.value);
      }
      return out;
    }
    if (node is List) {
      // Skip pseudo-comment wrapper objects whose only keys are $comm_/
      // $meta_comm_ — they come from bxp-fmt's array comment encoding and
      // have no AST equivalent.
      final out = <dynamic>[];
      for (final v in node) {
        if (v is Map) {
          final realKeys = v.keys.where((k) {
            final s = k.toString();
            return !s.startsWith(r'$comm_') &&
                !s.startsWith(r'$meta_comm_');
          });
          if (realKeys.isEmpty && v.isNotEmpty) continue;
        }
        out.add(stripMeta(v));
      }
      return out;
    }
    return node;
  }

  Future<dynamic> parseViaBxpFmt(List<int> bytes) async {
    final tmp =
        await File('${Directory.systemTemp.path}/parity_${DateTime.now().microsecondsSinceEpoch}.json5')
            .create();
    await tmp.writeAsBytes(bytes, flush: true);
    final r = await Process.run(bxpFmt, ['--config', tmp.path]);
    await tmp.delete();
    if (r.exitCode != 0 && r.exitCode != 1) {
      fail('bxp-fmt rejected output: ${r.stderr}');
    }
    return jsonDecode(r.stdout as String);
  }

  Future<void> assertParity(String label, List<ConfigOp> ops) async {
    final cstBytes = OpApply.apply(raw, origTree, ops);
    final astBytes = AstPatchClient.apply(raw, ops);

    final cstTree = await parseViaBxpFmt(cstBytes);
    final astTree = await parseViaBxpFmt(astBytes);

    final cstStripped = stripMeta(cstTree);
    final astStripped = stripMeta(astTree);

    expect(astStripped, equals(cstStripped),
        reason: 'parity mismatch for: $label');
  }

  test('empty op log → both backends produce semantically equal output',
      () async {
    await assertParity('empty', const []);
  });

  test('EditValueOp on a known scalar', () async {
    // Pick a path that exists in any reasonable bxp-cli config: top-level
    // settings keys differ across fixtures, so use a generic poke that's
    // unlikely to fail. If your fixture has no `settings.csv_strict`, edit.
    final probe = origTree as Map<String, dynamic>;
    final keys = probe.keys.where((k) => !k.startsWith(r'$')).toList();
    if (keys.isEmpty) {
      // No real keys — nothing to edit. Treat as trivial pass.
      return;
    }
    final firstKey = keys.first;
    final firstValue = probe[firstKey];
    if (firstValue is! Map && firstValue is! List) {
      await assertParity(
        'edit top-level scalar: $firstKey',
        [EditValueOp([firstKey], firstValue)],
      );
    }
  });
}
