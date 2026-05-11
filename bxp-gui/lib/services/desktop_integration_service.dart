import 'dart:io';
import 'app_runtime.dart';
import 'dev_trace.dart';

/// Snapshot of the on-disk paths the integration writes / would write.
/// Exposed to the dialog so it can disclose them to the user verbatim
/// before they accept.
class IntegrationPaths {
  final String desktopFile;
  final List<String> iconFiles;
  final String prefsFile;

  const IntegrationPaths({
    required this.desktopFile,
    required this.iconFiles,
    required this.prefsFile,
  });
}

/// Linux-only AppImage desktop integration.
///
/// When the user accepts the first-run dialog, writes a `.desktop`
/// launcher under `~/.local/share/applications/`, copies the bundled
/// hicolor icon tree from inside the AppImage to
/// `~/.local/share/icons/hicolor/<size>/apps/`, and ensures the prefs
/// file exists. No `sudo`: all destinations are user-owned.
///
/// No-op on Windows / macOS — those installers handle menu / Start
/// integration as part of their native install flow.
class DesktopIntegrationService {
  /// 8 icon sizes shipped inside the AppImage at
  /// `$APPDIR/usr/share/icons/hicolor/<size>x<size>/apps/bxp-gui.png`,
  /// matching what the build script bakes into the .AppImage payload.
  static const List<int> _iconSizes = [16, 32, 48, 64, 128, 256, 512, 1024];

  /// Optional overrides for unit testing. When null, runtime values are
  /// resolved from `HOME` / `$APPIMAGE` / `$APPDIR` environment vars
  /// (the AppImage runtime sets the latter two automatically).
  final String? _homeOverride;
  final String? _appImageOverride;
  final String? _appDirOverride;

  DesktopIntegrationService({
    String? homeOverride,
    String? appImageOverride,
    String? appDirOverride,
  })  : _homeOverride = homeOverride,
        _appImageOverride = appImageOverride,
        _appDirOverride = appDirOverride;

  /// True iff the host platform supports desktop integration and the
  /// app is running in the deployment shape that needs it (AppImage on
  /// Linux). False on Windows / macOS / `flutter run` / plain tarball.
  bool isAvailable() {
    if (!Platform.isLinux) return false;
    if (_appImageOverride != null) return true;
    return isRunningAsAppImage();
  }

  /// True iff the `.desktop` entry already exists AND its `Exec=` line
  /// points at the current `$APPIMAGE`. A stale Exec (user moved the
  /// AppImage) reports false so the caller can decide whether to
  /// reconcile silently or re-prompt.
  bool isIntegrated() {
    if (!isAvailable()) return false;
    final file = File(_desktopFilePath());
    if (!file.existsSync()) return false;
    final currentAppImage = _appImage();
    if (currentAppImage == null) return false;
    final content = file.readAsStringSync();
    return content.contains('Exec=$currentAppImage');
  }

  /// Snapshot of the absolute paths the integration will touch.
  IntegrationPaths describePaths() {
    return IntegrationPaths(
      desktopFile: _desktopFilePath(),
      iconFiles: [
        for (final size in _iconSizes) _iconFilePath(size),
      ],
      prefsFile: _prefsFilePath(),
    );
  }

  /// Write the `.desktop` entry, copy all 8 hicolor icon sizes, and
  /// refresh the desktop / icon caches. Best-effort: any failure in
  /// the cache-refresh subprocesses is swallowed since the entries
  /// become visible after the next DE refresh anyway.
  Future<void> integrate() async {
    if (!isAvailable()) return;
    final appImage = _appImage();
    final appDir = _appDir();
    if (appImage == null || appDir == null) {
      devTrace('integration.skip', {
        'reason': 'missing APPIMAGE or APPDIR env var',
      });
      return;
    }

    // Icons — copy each bundled size into the user's hicolor tree.
    for (final size in _iconSizes) {
      final src = File('$appDir/usr/share/icons/hicolor/${size}x$size/apps/bxp-gui.png');
      if (!await src.exists()) continue;
      final dst = File(_iconFilePath(size));
      await dst.parent.create(recursive: true);
      await src.copy(dst.path);
    }

    // .desktop entry — Exec points at the actual AppImage so menu
    // launches go through the same binary the user just ran.
    final desktopFile = File(_desktopFilePath());
    await desktopFile.parent.create(recursive: true);
    await desktopFile.writeAsString(_desktopFileContent(appImage));

    // Cache refreshes — both can legitimately be absent; ignore exit
    // codes and any exceptions raised by Process.run itself.
    await _bestEffort(
      'update-desktop-database',
      [_applicationsDir()],
    );
    await _bestEffort(
      'gtk-update-icon-cache',
      ['-f', '-t', _hicolorDir()],
    );
  }

  /// Remove the `.desktop` entry and the 8 icon files. Leaves the
  /// hicolor directory structure in place (shared with other apps) and
  /// never touches the prefs file.
  Future<void> uninstall() async {
    if (!Platform.isLinux) return;
    final desktopFile = File(_desktopFilePath());
    if (await desktopFile.exists()) await desktopFile.delete();
    for (final size in _iconSizes) {
      final icon = File(_iconFilePath(size));
      if (await icon.exists()) await icon.delete();
    }
    await _bestEffort('update-desktop-database', [_applicationsDir()]);
    await _bestEffort('gtk-update-icon-cache', ['-f', '-t', _hicolorDir()]);
  }

  /// When `.desktop` exists but its `Exec=` line points at a stale
  /// AppImage path (user moved or renamed the file), silently rewrite
  /// it to the current `$APPIMAGE`. No-op otherwise.
  Future<void> reconcileExecPath() async {
    if (!isAvailable()) return;
    final appImage = _appImage();
    if (appImage == null) return;
    final desktopFile = File(_desktopFilePath());
    if (!await desktopFile.exists()) return;
    final current = await desktopFile.readAsString();
    if (current.contains('Exec=$appImage')) return;
    await desktopFile.writeAsString(_desktopFileContent(appImage));
  }

  String _home() => _homeOverride ?? Platform.environment['HOME'] ?? '.';
  String? _appImage() => _appImageOverride ?? appImagePath();
  String? _appDir() => _appDirOverride ?? appDirPath();
  String _applicationsDir() => '${_home()}/.local/share/applications';
  String _hicolorDir() => '${_home()}/.local/share/icons/hicolor';
  String _desktopFilePath() => '${_applicationsDir()}/bxp-gui.desktop';
  String _iconFilePath(int size) =>
      '${_hicolorDir()}/${size}x$size/apps/bxp-gui.png';
  String _prefsFilePath() => '${_home()}/.local/share/bxp-gui/bxp-gui.json';

  String _desktopFileContent(String execPath) => '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=BXP\n'
      'Comment=Broker eXchange Parser - convert broker exports to portfolio trackers\n'
      'Exec=$execPath %F\n'
      'Icon=bxp-gui\n'
      'Terminal=false\n'
      'Categories=Office;Finance;Utility;\n'
      'MimeType=application/json;\n';

  Future<void> _bestEffort(String executable, List<String> args) async {
    try {
      await Process.run(executable, args);
    } catch (_) {
      // Cache-refresh tools are optional — ignore failures.
    }
  }
}
