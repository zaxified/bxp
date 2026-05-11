@TestOn('linux')
library;

import 'dart:io';

import 'package:bxp_gui/services/desktop_integration_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopIntegrationService', () {
    late Directory tmp;
    late Directory home;
    late Directory appDir;
    late String appImagePath;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('bxp_integration_test_');
      home = await Directory('${tmp.path}/home').create(recursive: true);

      // Fake AppImage payload — 8 hicolor sizes baked into usr/share/icons
      // mirroring the layout `_build_appimage()` produces in the real
      // release script.
      appDir = await Directory('${tmp.path}/AppDir').create(recursive: true);
      for (final size in [16, 32, 48, 64, 128, 256, 512, 1024]) {
        final iconDir = Directory(
          '${appDir.path}/usr/share/icons/hicolor/${size}x$size/apps',
        );
        await iconDir.create(recursive: true);
        await File('${iconDir.path}/bxp-gui.png').writeAsBytes([size]);
      }
      appImagePath = '${tmp.path}/bxp-desktop-linux-x86_64.AppImage';
      await File(appImagePath).writeAsBytes([1, 2, 3]);
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('integrate writes .desktop + 8 hicolor icons + reports integrated',
        () async {
      final svc = DesktopIntegrationService(
        homeOverride: home.path,
        appImageOverride: appImagePath,
        appDirOverride: appDir.path,
      );

      expect(svc.isAvailable(), isTrue);
      expect(svc.isIntegrated(), isFalse);

      await svc.integrate();

      final desktopFile = File('${home.path}/.local/share/applications/bxp-gui.desktop');
      expect(desktopFile.existsSync(), isTrue);
      final desktopContent = await desktopFile.readAsString();
      expect(desktopContent, contains('Exec=$appImagePath %F'));
      expect(desktopContent, contains('Icon=bxp-gui'));

      for (final size in [16, 32, 48, 64, 128, 256, 512, 1024]) {
        final icon = File(
          '${home.path}/.local/share/icons/hicolor/${size}x$size/apps/bxp-gui.png',
        );
        expect(icon.existsSync(), isTrue, reason: 'icon size $size missing');
      }

      expect(svc.isIntegrated(), isTrue);
    });

    test('reconcileExecPath rewrites stale .desktop Exec= line', () async {
      final svc = DesktopIntegrationService(
        homeOverride: home.path,
        appImageOverride: appImagePath,
        appDirOverride: appDir.path,
      );
      await svc.integrate();

      // Simulate the user moving the AppImage: write a .desktop entry
      // with a stale Exec= path, then point the service at the new path.
      final desktopFile = File('${home.path}/.local/share/applications/bxp-gui.desktop');
      var content = await desktopFile.readAsString();
      content = content.replaceAll(
        'Exec=$appImagePath %F',
        'Exec=/old/path/to/bxp.AppImage %F',
      );
      await desktopFile.writeAsString(content);
      expect(svc.isIntegrated(), isFalse);

      await svc.reconcileExecPath();

      final fixed = await desktopFile.readAsString();
      expect(fixed, contains('Exec=$appImagePath %F'));
      expect(svc.isIntegrated(), isTrue);
    });

    test('uninstall removes .desktop + icons but leaves prefs untouched',
        () async {
      final prefsFile = File('${home.path}/.local/share/bxp-gui/bxp-gui.json');
      await prefsFile.parent.create(recursive: true);
      await prefsFile.writeAsString('{"theme":"dark"}');

      final svc = DesktopIntegrationService(
        homeOverride: home.path,
        appImageOverride: appImagePath,
        appDirOverride: appDir.path,
      );
      await svc.integrate();
      await svc.uninstall();

      expect(
        File('${home.path}/.local/share/applications/bxp-gui.desktop').existsSync(),
        isFalse,
      );
      for (final size in [16, 32, 48, 64, 128, 256, 512, 1024]) {
        final icon = File(
          '${home.path}/.local/share/icons/hicolor/${size}x$size/apps/bxp-gui.png',
        );
        expect(icon.existsSync(), isFalse, reason: 'icon size $size remains');
      }

      // Prefs file is untouched.
      expect(prefsFile.existsSync(), isTrue);
      expect(await prefsFile.readAsString(), '{"theme":"dark"}');
    });
  });
}
