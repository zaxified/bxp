import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'dev_trace.dart';

/// User-prefs persistence backed by a visible JSON file at a canonical OS
/// path. Replaces the hidden, plugin-managed `shared_preferences` store.
///
/// Path resolution is deliberately manual (HOME / APPDATA env vars) rather
/// than `path_provider.getApplicationSupportDirectory()` — the latter
/// appends the bundle-id and produces nested paths like
/// `~/Library/Application Support/io.github.bxp.gui/`, which are bundle-id
/// dependent and would shift if the identifier ever changes.
///
///   Linux:   ~/.local/share/bxp-gui/bxp-gui.json
///   macOS:   ~/Library/Application Support/bxp-gui/bxp-gui.json
///   Windows: %APPDATA%\bxp-gui\bxp-gui.json
///
/// On first launch after upgrade from a shared_preferences-based build, the
/// 5 known keys are migrated one-shot into the new file and the legacy
/// store is cleared. Migration code lives here and is removed in v0.3.0.
class PrefsService {
  Map<String, dynamic> _data = {};
  late File _file;

  /// Keys copied from the legacy `shared_preferences` store during the v0.2
  /// one-shot migration. Ordering matches historical preference of first-
  /// written keys, not read frequency — stable between migration runs.
  static const _migrationKeys = <String>[
    'bxp-ui.theme',
    'bxp-ui.textScheme',
    'bxp-gui.zoom',
    'bxp-ui.recent',
    'bxp-gui.customPlaces',
  ];

  /// Resolve the OS-specific storage directory for bxp-gui preferences.
  /// Throws [UnsupportedError] on unsupported platforms (web, Fuchsia).
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

  /// Load preferences from the canonical JSON file.
  ///
  /// Must be called once at startup (before any get/set). Creates the
  /// parent directory if it does not yet exist. If the file is absent
  /// (first launch after install), attempts a one-shot migration from the
  /// legacy `shared_preferences` store; a missing or empty legacy store
  /// is silently skipped, leaving `_data` empty and starting fresh.
  ///
  /// A corrupt/partial JSON file is treated as empty (parse exception is
  /// swallowed) so a bad byte in the prefs file never prevents app launch.
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
    // File doesn't exist yet — try to migrate from the old shared_preferences
    // plugin store. Creates the new file on success; no-ops when the old
    // store is empty (fresh install).
    await _maybeMigrateFromSharedPreferences();
  }

  /// Returns the stored string for [key], or null when absent or not a string.
  /// Type mismatch (e.g. a num was stored under this key by an older version)
  /// returns null rather than throwing — callers use the default value instead.
  String? getString(String key) {
    final v = _data[key];
    return v is String ? v : null;
  }

  /// Returns the stored number for [key] as a double, or null when absent.
  /// Accepts both int and double since `jsonDecode` may decode integer literals
  /// as `int` rather than `double`.
  double? getDouble(String key) {
    final v = _data[key];
    if (v is num) return v.toDouble();
    return null;
  }

  /// Returns the stored list for [key] as a `List<String>`, or null when absent.
  /// The JSON store may hold a heterogeneous list from a future version; `cast()`
  /// will throw if the list contains non-String values — callers should guard
  /// with `try/catch` on the outer `_prefs.getStringList` call site.
  List<String>? getStringList(String key) {
    final v = _data[key];
    if (v is List) return v.cast<String>();
    return null;
  }

  /// Persist a string value and flush to disk atomically via a tmp rename.
  Future<void> setString(String key, String value) async {
    _data[key] = value;
    await _flush();
  }

  /// Persist a double value and flush to disk atomically via a tmp rename.
  Future<void> setDouble(String key, double value) async {
    _data[key] = value;
    await _flush();
  }

  /// Persist an integer and flush. Written to JSON as a bare integer
  /// ("80"), not "80.0" — used by the zoom field where keeping the
  /// on-disk value in clean integer percent units is the whole point
  /// of storing it as `int` in memory.
  Future<void> setInt(String key, int value) async {
    _data[key] = value;
    await _flush();
  }

  /// Persist a string list and flush to disk atomically via a tmp rename.
  Future<void> setStringList(String key, List<String> value) async {
    _data[key] = value;
    await _flush();
  }

  /// One-shot migration from the legacy `shared_preferences` plugin store.
  ///
  /// Copies all recognised keys into `_data`, writes the new JSON file, then
  /// clears the old store so subsequent launches skip this code path entirely.
  /// The clear happens only when at least one key was found so fresh installs
  /// (empty legacy store) don't trigger a spurious clear.
  ///
  /// Swallows all exceptions — the migration is best-effort, and a failure
  /// here must never block the app from starting. If migration fails silently,
  /// the user just loses their old preferences (theme/recent etc.) and starts
  /// fresh; that's better than a crash.
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
        // Clear the old store so subsequent launches don't re-migrate.
        await p.clear();
        devTrace('prefs.migrated', {'keys': migrated});
      }
    } catch (e) {
      devTrace('prefs.migrate.error', {'error': '$e'});
    }
  }

  /// Write the in-memory `_data` map to disk atomically.
  ///
  /// Writes to `<file>.tmp` first, then renames — the rename is the
  /// single syscall that switches the visible file pointer, so the
  /// real prefs file is never left half-written even if the app crashes
  /// between the write and the rename. The `.tmp` file is collected by
  /// the next successful flush if a previous flush was interrupted.
  ///
  /// Defensive merge: before writing, fold any keys that exist on disk
  /// but are missing from the in-memory `_data` back into the map. The
  /// constructor of `TraceStore` calls `_init()` without awaiting, so
  /// `_prefs.load()` may still be running when an early
  /// `setZoom(...)` / `setThemePreset(...)` fires from a postFrame
  /// auto-clamp on a high-DPI screen — in that window, `_data` is
  /// still empty (initial value), and a naïve flush would truncate
  /// the existing on-disk file down to whatever single key the early
  /// setter wrote. Reading the disk state here and unioning with
  /// in-memory keys (in-memory wins on conflicts) makes the flush
  /// safe regardless of init order. Cost is one extra read per
  /// flush; flushes happen on user actions (theme cycle, zoom
  /// change, recent files mutation) and are not hot-path.
  Future<void> _flush() async {
    if (await _file.exists()) {
      try {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            _data.putIfAbsent(entry.key, () => entry.value);
          }
        }
      } catch (_) {
        // disk is unparseable — fall back to writing in-memory only.
      }
    }
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_data), flush: true);
    await tmp.rename(_file.path);
  }
}
