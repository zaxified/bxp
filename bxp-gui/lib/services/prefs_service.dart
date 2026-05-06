import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'dev_trace.dart';

// User-prefs persistence backed by a visible JSON file at a canonical OS
// path. Replaces the hidden, plugin-managed `shared_preferences` store.
//
// Path resolution is deliberately manual (HOME / APPDATA env vars) rather
// than `path_provider.getApplicationSupportDirectory()` — the latter
// appends the bundle-id and produces nested paths like
// `~/Library/Application Support/io.github.bxp.gui/`, which are bundle-id
// dependent and would shift if the identifier ever changes.
//
//   Linux:   ~/.local/share/bxp-gui/bxp-gui.json
//   macOS:   ~/Library/Application Support/bxp-gui/bxp-gui.json
//   Windows: %APPDATA%\bxp-gui\bxp-gui.json
//
// On first launch after upgrade from a shared_preferences-based build, the
// 5 known keys are migrated one-shot into the new file and the legacy
// store is cleared. Migration code lives here and is removed in v0.3.0.
class PrefsService {
  Map<String, dynamic> _data = {};
  late File _file;

  static const _migrationKeys = <String>[
    'bxp-ui.theme',
    'bxp-ui.textScheme',
    'bxp-gui.zoom',
    'bxp-ui.recent',
    'bxp-gui.customPlaces',
  ];

  static String _resolveDir() {
    if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '.';
      return '$home/.local/share/bxp-gui';
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      return '$home/Library/Application Support/bxp-gui';
    }
    if (Platform.isWindows) {
      final appdata = Platform.environment['APPDATA'] ?? '.';
      return '$appdata\\bxp-gui';
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  Future<void> load() async {
    final dir = Directory(_resolveDir());
    await dir.create(recursive: true);
    _file = File('${dir.path}${Platform.pathSeparator}bxp-gui.json');
    if (await _file.exists()) {
      try {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) _data = decoded;
      } catch (e) {
        devTrace('prefs.load.error', {'error': '$e'});
        _data = {};
      }
      return;
    }
    await _maybeMigrateFromSharedPreferences();
  }

  String? getString(String key) {
    final v = _data[key];
    return v is String ? v : null;
  }

  double? getDouble(String key) {
    final v = _data[key];
    if (v is num) return v.toDouble();
    return null;
  }

  List<String>? getStringList(String key) {
    final v = _data[key];
    if (v is List) return v.cast<String>();
    return null;
  }

  Future<void> setString(String key, String value) async {
    _data[key] = value;
    await _flush();
  }

  Future<void> setDouble(String key, double value) async {
    _data[key] = value;
    await _flush();
  }

  Future<void> setStringList(String key, List<String> value) async {
    _data[key] = value;
    await _flush();
  }

  Future<void> _maybeMigrateFromSharedPreferences() async {
    try {
      final p = await SharedPreferences.getInstance();
      var migrated = 0;
      for (final k in _migrationKeys) {
        final v = p.get(k);
        if (v != null) {
          _data[k] = v;
          migrated++;
        }
      }
      if (migrated > 0) {
        await _flush();
        await p.clear();
        devTrace('prefs.migrated', {'keys': migrated});
      }
    } catch (e) {
      devTrace('prefs.migrate.error', {'error': '$e'});
    }
  }

  Future<void> _flush() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_data), flush: true);
    await tmp.rename(_file.path);
  }
}
