import 'dart:io';

import 'package:bxp_gui/services/prefs_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrefsService.ensureExists', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('bxp_prefs_test_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('creates an empty prefs file when one does not exist', () async {
      final prefs = PrefsService(dirOverride: tmp.path);
      await prefs.load();
      expect(prefs.prefsFileExists(), isFalse);

      await prefs.ensureExists();

      final file = File('${tmp.path}/bxp-gui.json');
      expect(file.existsSync(), isTrue);
      expect(await file.readAsString(), '{}');
      expect(prefs.prefsFileExists(), isTrue);
    });

    test('is a no-op when the prefs file already has content', () async {
      final prefs = PrefsService(dirOverride: tmp.path);
      await prefs.load();
      await prefs.setString('bxp-ui.theme', 'dark');
      final before = await File('${tmp.path}/bxp-gui.json').readAsString();

      await prefs.ensureExists();

      final after = await File('${tmp.path}/bxp-gui.json').readAsString();
      expect(after, equals(before));
      expect(prefs.getString('bxp-ui.theme'), equals('dark'));
    });

    test('configFilePath returns the canonical on-disk location', () async {
      final prefs = PrefsService(dirOverride: tmp.path);
      await prefs.load();
      expect(prefs.configFilePath,
          equals('${tmp.path}${Platform.pathSeparator}bxp-gui.json'));
    });
  });
}
