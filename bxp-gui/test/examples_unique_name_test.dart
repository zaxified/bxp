import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:bxp_gui/services/bxp_process_client.dart';

/// Guards the "create examples" open-dialog action's collision handling:
/// the first copy keeps the verbatim name, and each subsequent copy into
/// the same folder gets the next free ` (N)` suffix instead of clobbering.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('bxp_examples_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  const name = BxpProcessClient.examplesFileName; // bxp-cli.examples.json

  test('first target is the verbatim name', () {
    expect(
      BxpProcessClient.uniqueTargetPath(dir.path, name),
      p.join(dir.path, 'bxp-cli.examples.json'),
    );
  });

  test('collisions suffix " (N)" before the extension', () {
    File(p.join(dir.path, 'bxp-cli.examples.json')).writeAsStringSync('a');
    expect(
      BxpProcessClient.uniqueTargetPath(dir.path, name),
      p.join(dir.path, 'bxp-cli.examples (1).json'),
    );

    File(p.join(dir.path, 'bxp-cli.examples (1).json')).writeAsStringSync('b');
    expect(
      BxpProcessClient.uniqueTargetPath(dir.path, name),
      p.join(dir.path, 'bxp-cli.examples (2).json'),
    );
  });
}
