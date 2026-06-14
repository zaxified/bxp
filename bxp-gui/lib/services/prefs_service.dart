import 'dart:convert';
import 'dart:io';
import 'dev_trace.dart';

/// User-prefs persistence backed by a visible JSON file at a canonical OS
/// path.
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
class PrefsService {
  /// Override for the parent directory of `bxp-gui.json`. Tests pass a
  /// temp dir; production uses the OS-canonical path resolved at
  /// [load] time. Null means "resolve from HOME / APPDATA".
  final String? _dirOverride;

  PrefsService({String? dirOverride}) : _dirOverride = dirOverride;

  Map<String, dynamic> _data = {};
  late File _file;

  /// Resolve the OS-specific storage directory for bxp-gui preferences.
  /// Throws [UnsupportedError] on unsupported platforms (web, Fuchsia).
  String _resolveDir() {
    if (_dirOverride != null) return _dirOverride;
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
  /// (fresh install) `_data` stays empty and the app starts with
  /// default settings.
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
    }
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

  /// Returns the stored bool for [key], or [orElse] (default false) when
  /// absent or not a bool. Type mismatch (a string/num under this key from an
  /// older version) falls back to [orElse] rather than throwing.
  bool getBool(String key, {bool orElse = false}) {
    final v = _data[key];
    return v is bool ? v : orElse;
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

  /// Persist a bool value and flush to disk atomically via a tmp rename.
  Future<void> setBool(String key, bool value) async {
    _data[key] = value;
    await _flush();
  }

  /// Persist a string list and flush to disk atomically via a tmp rename.
  Future<void> setStringList(String key, List<String> value) async {
    _data[key] = value;
    await _flush();
  }

  /// Synchronous probe for whether the prefs file exists on disk.
  ///
  /// Used by the AppImage first-run integration flow to decide whether
  /// to surface the integration dialog — when the prefs file is
  /// missing, the user has not yet been through the dialog at all, so
  /// it appears. After either choice the dialog calls [ensureExists]
  /// which creates the file and silences the prompt on subsequent
  /// launches.
  bool prefsFileExists() => _file.existsSync();

  /// Returns the canonical on-disk location of the prefs file. Used by
  /// the integration dialog to disclose the path to the user before
  /// creating it.
  String get configFilePath => _file.path;

  /// Ensures the prefs file exists on disk, writing the current
  /// in-memory `_data` map (which may be empty for a fresh install).
  /// Idempotent — no-op when the file is already present.
  Future<void> ensureExists() async {
    if (await _file.exists()) return;
    await _flush();
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
