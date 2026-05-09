import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../store/trace_store.dart';
import 'bxp_process_client.dart';
import 'debug_binding.dart';
import 'debug_settings.dart';

/// Opt-in NDJSON diagnostic log for the Windows freeze investigation.
///
/// Activated at launch by any of:
///   1. `BXP_DIAGNOSTIC=1` environment variable.
///   2. Existence of marker file `<prefs-dir>/.bxp-diagnostic`.
///   3. Equivalent — the SettingsInspector master switch writes (and
///      deletes) the marker, then auto-restarts the binary.
///
/// All three paths flip the same gate, so the behaviour is identical
/// regardless of how the user (or developer) activates it. The native
/// `DiagInit` in `windows/runner/win32_window.cpp` honours the same
/// (1) + (2) — it must, otherwise toggling the switch would only
/// produce the NDJSON and miss the native + engine stderr logs that
/// require boot-time hooking.
///
/// When inactive, every `log()` call is a single null-check and
/// returns immediately, so adding hooks across the codebase costs
/// nothing in default builds.
///
/// Output:   `<prefs-dir>/diagnostic-YYYYMMDD-HHMMSS.ndjson`
///   - Linux:   `~/.local/share/bxp-gui/`
///   - macOS:   `~/Library/Application Support/bxp-gui/`
///   - Windows: `%APPDATA%\bxp-gui\`
///
/// One JSON object per line, fields:
///   t     — ISO-8601 UTC timestamp
///   kind  — event type (`startup`, `gpu`, `frame`, `action`, `error`, ...)
///   ...   — kind-specific payload
///
/// Capped at 5 MB per session to prevent runaway disk use; further
/// writes silently drop once the cap is reached. A new file is created
/// for every launch — no in-place rotation. Heartbeat runs every 1 s
/// and flushes the IOSink, so on a hard kill at most ~1 s of frame
/// telemetry is lost.
class DiagnosticLog {
  static IOSink? _sink;
  static String? _path;
  static int _bytesWritten = 0;
  static const int _maxBytes = 5 * 1024 * 1024;

  static Timer? _heartbeatTimer;

  // 1-second rolling window for frame stats.
  static int _buildUs = 0;
  static int _rasterUs = 0;
  static int _frames = 0;

  // Pointer-event delta tracking (DebugBinding counters are monotonic).
  static int _prevPe = 0;
  static int _prevPeFwd = 0;
  static int _prevScroll = 0;
  static int _prevMid = 0;

  static bool get isEnabled => _sink != null;
  static String? get path => _path;

  /// Path to the marker file whose existence activates diagnostic mode
  /// at the next launch. The SettingsInspector master switch writes
  /// (and deletes) this file so end-users don't have to know about
  /// `BXP_DIAGNOSTIC=1` to capture a freeze report.
  static String get markerPath =>
      '${_resolveDir()}${Platform.pathSeparator}.bxp-diagnostic';

  static Future<bool> markerExists() => File(markerPath).exists();

  /// Create or remove the marker file. The file is empty — only its
  /// existence matters. Creates the prefs dir if missing. Best-effort:
  /// callers should surface failure via UI if user feedback matters.
  static Future<void> setMarker(bool enabled) async {
    final dir = _resolveDir();
    try {
      if (enabled) {
        await Directory(dir).create(recursive: true);
        await File(markerPath).writeAsString('');
      } else {
        final f = File(markerPath);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {
      // ignored — callers can detect via subsequent markerExists().
    }
  }

  /// Initialize the log if `BXP_DIAGNOSTIC=1` is set or the marker
  /// file `$prefs-dir/.bxp-diagnostic` exists. Returns `true` when
  /// activation succeeded, `false` otherwise. Safe to call repeatedly.
  ///
  /// Must run AFTER any Flutter binding is initialized — the activation
  /// path goes through [start] which pokes [SchedulerBinding].
  static Future<bool> tryInit() async {
    if (_sink != null) return true;

    final dirPath = _resolveDir();
    final envValue = Platform.environment['BXP_DIAGNOSTIC'];
    final markerPath =
        '$dirPath${Platform.pathSeparator}.bxp-diagnostic';

    // Activation: env var = '1' OR marker file exists. Marker is a
    // fallback for environments where env-var propagation is awkward
    // (some launchers, double-click via shortcut, etc.).
    final markerExists = File(markerPath).existsSync();
    if (envValue != '1' && !markerExists) return false;

    return await start();
  }

  /// Open a fresh diagnostic log file and wire frame timings + the
  /// 1-second heartbeat. Skips the env-var / marker check that
  /// [tryInit] performs — used by SettingsInspector when the user
  /// flips the master "Diagnostic mode" switch mid-session. Returns
  /// `true` on success, `false` if the directory or file could not be
  /// created. Idempotent (calling twice is a no-op when already
  /// running).
  static Future<bool> start() async {
    if (_sink != null) return true;

    final dirPath = _resolveDir();
    try {
      await Directory(dirPath).create(recursive: true);
    } catch (_) {
      return false;
    }
    final ts = _timestamp();
    _path = '$dirPath${Platform.pathSeparator}diagnostic-$ts.ndjson';
    try {
      _sink = File(_path!).openWrite(mode: FileMode.append);
    } catch (_) {
      _path = null;
      return false;
    }
    _bytesWritten = 0;

    // One-line "this is a fresh session" header so log parsers can
    // tell back-to-back trace files apart even when filenames clash
    // on filesystems that round timestamps.
    log('startup', {
      'platform': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'dart_version': Platform.version,
      'executable': Platform.resolvedExecutable,
      'locale': Platform.localeName,
      'cwd': Directory.current.path,
    });

    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _heartbeatTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _heartbeat(),
    );
    // Best-effort GPU enumeration. Async, fire-and-forget; result
    // appears in the log a couple of seconds after startup.
    unawaited(_captureGpuInfo());

    DebugSettings.instance
        .setDiagnosticTraceState(active: true, path: _path);
    return true;
  }

  /// Stop the live trace: flush + close the file, remove the timings
  /// callback, cancel the heartbeat. The next [start] call will open a
  /// fresh file. Idempotent.
  static Future<void> stop() async {
    final s = _sink;
    if (s == null) return;
    log('shutdown', {});
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    try {
      await s.flush();
      await s.close();
    } catch (_) {
      // best effort
    }
    _sink = null;
    _path = null;
    _bytesWritten = 0;
    _frames = 0;
    _buildUs = 0;
    _rasterUs = 0;
    _prevPe = 0;
    _prevPeFwd = 0;
    _prevScroll = 0;
    _prevMid = 0;

    DebugSettings.instance
        .setDiagnosticTraceState(active: false, path: null);
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final ft in timings) {
      _buildUs += ft.buildDuration.inMicroseconds;
      _rasterUs += ft.rasterDuration.inMicroseconds;
      _frames++;
    }
  }

  static void _heartbeat() {
    int pe = 0, peFwd = 0, scrl = 0, mid = 0;
    try {
      final binding = WidgetsBinding.instance;
      if (binding is DebugBinding) {
        pe = binding.eventsTotal;
        peFwd = binding.eventsForwarded;
        scrl = binding.scrollEventsTotal;
        mid = binding.middleButtonEventsTotal;
      }
    } catch (_) {
      // Binding not ready yet — counters stay 0.
    }

    log('frame', {
      'fps': _frames,
      'build_ms': double.parse((_buildUs / 1000.0).toStringAsFixed(2)),
      'raster_ms': double.parse((_rasterUs / 1000.0).toStringAsFixed(2)),
      'pe': pe - _prevPe,
      'pe_fwd': peFwd - _prevPeFwd,
      'scroll': scrl - _prevScroll,
      'mid_btn': mid - _prevMid,
    });

    _prevPe = pe;
    _prevPeFwd = peFwd;
    _prevScroll = scrl;
    _prevMid = mid;
    _frames = 0;
    _buildUs = 0;
    _rasterUs = 0;

    _sink?.flush();
  }

  /// Best-effort enumeration of installed video adapters via
  /// PowerShell + WMI. The driver name immediately distinguishes
  /// VMware SVGA / VBoxSVGA / VMSVGA / real GPU — the most useful
  /// single signal for the freeze investigation.
  static Future<void> _captureGpuInfo() async {
    if (!Platform.isWindows) return;
    try {
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Get-CimInstance Win32_VideoController | '
              'Select-Object Name, DriverVersion, DriverDate, '
              'AdapterCompatibility, VideoProcessor, AdapterRAM, '
              'CurrentRefreshRate, CurrentHorizontalResolution, '
              'CurrentVerticalResolution | ConvertTo-Json -Compress',
        ],
        runInShell: false,
      ).timeout(const Duration(seconds: 10));
      if (result.exitCode == 0) {
        final out = (result.stdout as String).trim();
        if (out.isNotEmpty) {
          dynamic parsed;
          try {
            parsed = jsonDecode(out);
          } catch (_) {
            parsed = out;
          }
          log('gpu', {'controllers': parsed});
        }
      } else {
        log('gpu_error', {
          'exitCode': result.exitCode,
          'stderr': '${result.stderr}'.trim(),
        });
      }
    } catch (e) {
      log('gpu_error', {'error': '$e'});
    }
  }

  /// Append one NDJSON record. No-op when not enabled.
  static void log(String kind, [Map<String, dynamic>? data]) {
    final sink = _sink;
    if (sink == null) return;
    if (_bytesWritten > _maxBytes) return;
    final entry = <String, dynamic>{
      't': DateTime.now().toUtc().toIso8601String(),
      'kind': kind,
    };
    if (data != null) entry.addAll(data);
    final line = '${jsonEncode(entry)}\n';
    try {
      sink.write(line);
    } catch (_) {
      return;
    }
    _bytesWritten += line.length;
  }

  /// Convenience for action-style hooks. Logs `action.start` and
  /// returns a closure that logs `action.end` with the elapsed
  /// milliseconds when invoked.
  static void Function([Map<String, dynamic>? extra]) action(
    String name, [
    Map<String, dynamic>? args,
  ]) {
    if (_sink == null) return ([_]) {};
    final sw = Stopwatch()..start();
    log('action.start', {
      'name': name,
      'args': ?args,
    });
    return ([Map<String, dynamic>? extra]) {
      sw.stop();
      log('action.end', {
        'name': name,
        'ms': sw.elapsedMilliseconds,
        if (extra != null) ...extra,
      });
    };
  }

  /// Force the OS-level flush (used right before close / on errors).
  static Future<void> flush() async {
    final s = _sink;
    if (s == null) return;
    try {
      await s.flush();
    } catch (_) {
      // ignore — best effort
    }
  }

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
    return '.';
  }

  static String _timestamp() {
    final n = DateTime.now();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${n.year}${p(n.month)}${p(n.day)}-${p(n.hour)}${p(n.minute)}${p(n.second)}';
  }
}

/// Emit a one-shot snapshot of the current DebugSettings + TraceStore
/// state right after the trace activates. Gives consumers a complete
/// picture of how the GUI was configured at trace start without having
/// to correlate with an external SettingsInspector dump. No-op when
/// the trace is inactive. Reads the [TraceStore] from `context`'s
/// Provider scope.
void emitDiagnosticContextSnapshot(BuildContext context) {
  if (!DiagnosticLog.isEnabled) return;
  final s = DebugSettings.instance;
  final store = Provider.of<TraceStore>(context, listen: false);

  DiagnosticLog.log('settings', {
    'overlayVisible': s.overlayVisible,
    'tooltipsInTree': s.tooltipsInTree,
    'hoverBackground': s.hoverBackground,
    'hoverActionButtons': s.hoverActionButtons,
    'useInkWell': s.useInkWell,
    'blockMiddleButton': s.blockMiddleButton,
    'blockRightButton': s.blockRightButton,
    'pointerThrottleHz': s.pointerThrottleHz,
    'bypassZoom': s.bypassZoom,
  });

  DiagnosticLog.log('runtime', {
    'bxp_gui_version': store.bxpGuiVersion,
    'bxp_fmt_version': store.bxpFmtVersion,
    'bxp_cli_version': store.bxpCliVersion,
    'bxp_fmt_path': BxpProcessClient.findBin('bxp-fmt'),
    'bxp_cli_path': BxpProcessClient.findBin('bxp-cli'),
    'env_BXP_FMT_PATH': Platform.environment['BXP_FMT_PATH'],
    'env_BXP_CLI_PATH': Platform.environment['BXP_CLI_PATH'],
    'config_path': store.configPath,
    'config_dirty': store.isDirty,
    'config_has_errors': store.configHasErrors,
    'config_load_had_errors': store.configLoadHadErrors,
    'fs_check_slow': store.fsCheckSlow,
    'status': store.status.name,
    'last_exit_code': store.lastExitCode,
    'theme_preset': store.themePresetName,
    'zoom': store.zoom,
  });
}
