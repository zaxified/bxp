import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'debug_binding.dart';

/// Opt-in NDJSON diagnostic log for the Windows freeze investigation.
///
/// Activated by setting `BXP_DIAGNOSTIC=1` in the environment before
/// launch. When inactive, every `log()` call is a single env-var-already-
/// resolved null check and returns immediately, so adding hooks across
/// the codebase costs nothing in default builds.
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

  /// Initialize the log if `BXP_DIAGNOSTIC=1` is set. Returns `true`
  /// when activation succeeded, `false` otherwise (env var unset, dir
  /// creation failed, ...). Safe to call repeatedly.
  ///
  /// Must run AFTER any Flutter binding is initialized but BEFORE
  /// [wireFrameTimings] — the latter pokes [SchedulerBinding] which
  /// requires a binding to exist.
  static Future<bool> tryInit() async {
    if (_sink != null) return true;

    final dirPath = _resolveDir();
    final envValue = Platform.environment['BXP_DIAGNOSTIC'];
    final markerPath =
        '$dirPath${Platform.pathSeparator}.bxp-diagnostic';

    // Always write a probe file so we can diagnose silent failures of
    // env-var propagation. Append-only so multiple launches accumulate.
    try {
      await Directory(dirPath).create(recursive: true);
      await File('$dirPath${Platform.pathSeparator}diagnostic-probe.txt')
          .writeAsString(
        'time=${DateTime.now().toIso8601String()}\n'
        'BXP_DIAGNOSTIC=${envValue ?? '<unset>'}\n'
        'marker_exists=${File(markerPath).existsSync()}\n'
        'platform=${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
        '---\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // probe is best-effort; don't block init on probe failure.
    }

    // Activation: env var = '1' OR marker file exists. Marker is a
    // fallback for environments where env-var propagation is awkward
    // (some launchers, double-click via shortcut, etc.).
    final markerExists = File(markerPath).existsSync();
    if (envValue != '1' && !markerExists) return false;

    final ts = _timestamp();
    _path = '$dirPath${Platform.pathSeparator}diagnostic-$ts.ndjson';
    try {
      _sink = File(_path!).openWrite(mode: FileMode.append);
    } catch (_) {
      _path = null;
      return false;
    }
    _bytesWritten = 0;
    return true;
  }

  /// Subscribe to [SchedulerBinding] frame timings and start the 1 s
  /// heartbeat that emits `frame` events combining build/raster
  /// durations with [DebugBinding] pointer counters.
  static void wireFrameTimings() {
    if (_sink == null) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _heartbeatTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _heartbeat(),
    );
    // Best-effort GPU enumeration. Async, fire-and-forget; result
    // appears in the log a couple of seconds after startup.
    unawaited(_captureGpuInfo());
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
