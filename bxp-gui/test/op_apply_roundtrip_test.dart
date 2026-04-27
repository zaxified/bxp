/// CST round-trip identity test.
///
/// With an empty op log, [OpApply.apply] must return the original raw
/// bytes verbatim. Run via `dart test test/op_apply_roundtrip_test.dart
/// <bxp-fmt-binary> <fixture-path>` (called from scripts/test.sh).
import 'dart:convert';
import 'dart:io';

import 'package:bxp_gui/services/op_apply.dart';
import 'package:test/test.dart';

void main() {
  // Read fixture path + bxp-fmt path from environment so the test can be
  // parameterised by scripts/test.sh.
  final bxpFmt = Platform.environment['BXP_FMT'];
  final fixture = Platform.environment['BXP_FIXTURE'];
  if (bxpFmt == null || fixture == null) {
    test('skipped (BXP_FMT or BXP_FIXTURE not set)', () {});
    return;
  }

  test('OpApply.apply with empty op log is byte-identical to source', () async {
    final raw = await File(fixture).readAsBytes();
    final result = await Process.run(bxpFmt, ['--config', fixture]);
    if (result.exitCode != 0 && result.exitCode != 1) {
      fail('bxp-fmt failed: ${result.stderr}');
    }
    final tree = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final out = OpApply.apply(raw, tree, const []);
    expect(utf8.decode(out), equals(utf8.decode(raw)));
  });
}
