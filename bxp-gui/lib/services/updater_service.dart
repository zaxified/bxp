import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app_runtime.dart';
import 'dev_trace.dart';

// Pure-Dart cross-platform auto-updater.
//
// Polls the GitHub Releases API for `zaxified/bxp` on app launch and on a
// 6 h timer; if a newer tag is found, surfaces an `UpdateInfo` via
// [available]. The UI listens via ChangeNotifier and shows a dialog the
// user can accept or dismiss. On accept, the matching native installer is
// downloaded to the system temp dir, verified against `SHA256SUMS` from
// the same release, and dispatched to a platform-native install path:
//
//   Windows: `setup.exe /S` + exit(0); the NSIS post-install relaunches.
//   macOS:   mount DMG → copy `.app` → unmount → `open -n` → exit(0).
//   Linux (AppImage): atomic-replace the running AppImage + exec.
//
// Linux non-AppImage builds and macOS Intel surface a "manual update
// required" message — the only supported Linux distribution channel is
// the AppImage shipped from the GitHub release.
//
// No plugins — uses dart:io HttpClient + Process.run only.
class UpdaterService extends ChangeNotifier {
  static const String repoSlug = 'zaxified/bxp';
  static const Duration _initialDelay = Duration(seconds: 5);
  static const Duration _periodicInterval = Duration(hours: 6);

  String? _currentVersion;
  Timer? _periodicTimer;
  bool _initialized = false;
  bool _checking = false;

  UpdateInfo? _available;
  UpdateInfo? get available => _available;

  bool get isChecking => _checking;

  /// Download progress in [0.0, 1.0]; null when no download is active.
  double? _downloadProgress;
  double? get downloadProgress => _downloadProgress;

  /// Last error from a check or download attempt; surfaced in the dialog
  /// for transparency. Null on success.
  String? _lastError;
  String? get lastError => _lastError;

  /// Schedule the initial check + periodic interval. Idempotent.
  /// In debug mode the auto-check is skipped — manual [checkForUpdates]
  /// still works for testing.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
    } catch (e) {
      devTrace('updater.init.error', {'error': '$e'});
      return;
    }
    if (kDebugMode) {
      devTrace('updater.init.skipped', {'reason': 'kDebugMode'});
      return;
    }
    Timer(_initialDelay, () => checkForUpdates());
    _periodicTimer = Timer.periodic(
      _periodicInterval,
      (_) => checkForUpdates(),
    );
  }

  @override
  void dispose() {
    _periodicTimer?.cancel();
    super.dispose();
  }

  /// Dismiss the current update prompt (user clicked Later). The next
  /// periodic check will resurface it if the release is still newer.
  void dismiss() {
    if (_available == null) return;
    _available = null;
    notifyListeners();
  }

  /// One-shot check — used both by the periodic schedule and any explicit
  /// "check now" UI. Updates [available] / [isChecking] / [lastError].
  Future<void> checkForUpdates() async {
    if (_checking) return;
    if (_currentVersion == null) return;
    _checking = true;
    _lastError = null;
    notifyListeners();
    try {
      final json = await _fetchLatestRelease();
      final tag = (json['tag_name'] as String?) ?? '';
      final latest = _stripVPrefix(tag);
      if (!_isNewer(latest, _currentVersion!)) {
        _available = null;
        return;
      }
      final assets = (json['assets'] as List?) ?? const [];
      final assetUrl = _pickAssetUrl(assets);
      final checksumUrl = _pickChecksumUrl(assets);
      _available = UpdateInfo(
        version: latest,
        tagName: tag,
        body: (json['body'] as String?) ?? '',
        htmlUrl: (json['html_url'] as String?) ?? '',
        assetUrl: assetUrl,
        assetName: assetUrl == null ? null : Uri.parse(assetUrl).pathSegments.last,
        checksumUrl: checksumUrl,
      );
    } catch (e) {
      _lastError = '$e';
      devTrace('updater.check.error', {'error': '$e'});
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// Fetch the latest GitHub release JSON for [repoSlug].
  ///
  /// Uses `dart:io HttpClient` directly (no http package dependency) because
  /// the updater must work in production where pub deps are frozen. The User-
  /// Agent header is required by GitHub's API ToS; without it requests may be
  /// rate-limited at a lower threshold.
  Future<Map<String, dynamic>> _fetchLatestRelease() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$repoSlug/releases/latest',
    );
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'bxp-gui-updater');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw Exception('GitHub API ${res.statusCode}');
      }
      final body = await res.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      // force:true closes the connection immediately even when the response body
      // hasn't been drained — safe here because we awaited `.join()` above.
      client.close(force: true);
    }
  }

  /// Select the release asset URL that matches the current platform.
  /// Returns null when there is no suitable asset (e.g. Linux non-AppImage
  /// or an unrecognised platform); the caller falls back to opening the
  /// browser release page in that case.
  String? _pickAssetUrl(List assets) {
    final pattern = _platformAssetPattern();
    if (pattern == null) return null;
    for (final a in assets) {
      final name = (a as Map)['name']?.toString() ?? '';
      if (pattern.hasMatch(name)) {
        return a['browser_download_url']?.toString();
      }
    }
    return null;
  }

  /// Return the `browser_download_url` of the `SHA256SUMS` asset, or null
  /// when the release doesn't publish one. Callers treat a missing checksum
  /// file as "proceed without verification" (logged, not fatal).
  String? _pickChecksumUrl(List assets) {
    for (final a in assets) {
      final name = (a as Map)['name']?.toString() ?? '';
      if (name == 'SHA256SUMS') return a['browser_download_url']?.toString();
    }
    return null;
  }

  RegExp? _platformAssetPattern() {
    if (Platform.isWindows) {
      return RegExp(r'^bxp-desktop-windows-x86_64\.exe$');
    }
    if (Platform.isMacOS) {
      // Only Apple Silicon (arm64) DMGs are produced by the release
      // workflow; Intel Macs fall through to the manual-update message.
      return RegExp(r'^bxp-desktop-macos-arm64\.dmg$');
    }
    if (Platform.isLinux) {
      // Linux is AppImage-only — the .deb / tarball release channels were
      // retired in v0.3.0. Builds running outside an AppImage surface a
      // "manual update required" message via the null return.
      if (isRunningAsAppImage()) {
        return RegExp(r'^bxp-desktop-linux-x86_64\.AppImage$');
      }
      return null;
    }
    return null;
  }

  /// Download the platform installer, verify SHA-256 against SHA256SUMS,
  /// and dispatch to the platform-native install. Returns true if install
  /// was launched (caller should exit the app); false on error or fallback
  /// to "open release page" (Linux non-AppImage).
  ///
  /// [onProgress] is called with values in [0.0, 1.0] during the download.
  Future<bool> downloadAndInstall({
    void Function(double)? onProgress,
  }) async {
    final info = _available;
    if (info == null) return false;
    _lastError = null;

    // No matching asset for this platform/host combination — e.g. Linux
    // build running outside an AppImage, or macOS Intel. Surface a clear
    // message in the dialog rather than silently dispatching elsewhere.
    if (info.assetUrl == null) {
      _lastError =
          'No installer for this platform — please update manually from '
          'the release page.';
      notifyListeners();
      return false;
    }

    try {
      final tmpDir = await getTemporaryDirectory();
      final assetPath = p.join(
        tmpDir.path,
        info.assetName ?? 'bxp-desktop-update',
      );
      await _downloadFile(info.assetUrl!, assetPath, onProgress);

      // Fail-closed: every verification failure refuses the install and
      // surfaces a specific message. The release page link in the dialog
      // is the user's escape hatch when the release itself is broken.
      if (info.checksumUrl == null) {
        devTrace('updater.checksum.missing', {'asset': info.assetName ?? ''});
        _lastError = 'Release is missing SHA256SUMS — refusing to install. '
            'Please update manually from the release page.';
        notifyListeners();
        return false;
      }
      final result = await _verifyChecksum(assetPath, info);
      if (result != _ChecksumResult.ok) {
        _lastError = switch (result) {
          _ChecksumResult.fetchFailed =>
            'Could not fetch SHA256SUMS — refusing to install.',
          _ChecksumResult.assetNotListed =>
            'Asset is not listed in SHA256SUMS — refusing to install.',
          _ChecksumResult.mismatch =>
            'Checksum mismatch — refusing to install.',
          _ChecksumResult.ok => '',
        };
        notifyListeners();
        return false;
      }

      // Dispatch.
      if (Platform.isWindows) {
        return await _installWindows(assetPath);
      }
      if (Platform.isMacOS) {
        return await _installMacOS(assetPath);
      }
      if (Platform.isLinux) {
        return await _installLinuxAppImage(assetPath);
      }
      _lastError = 'Unsupported platform: ${Platform.operatingSystem}';
      notifyListeners();
      return false;
    } catch (e) {
      _lastError = '$e';
      devTrace('updater.install.error', {'error': '$e'});
      notifyListeners();
      return false;
    }
  }

  Future<void> _downloadFile(
    String url,
    String dest,
    void Function(double)? onProgress,
  ) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'bxp-gui-updater');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw Exception('Download HTTP ${res.statusCode}');
      }
      final total = res.contentLength;
      final file = File(dest);
      final sink = file.openWrite();
      var received = 0;
      _downloadProgress = 0.0;
      notifyListeners();
      // Inner try/finally guarantees the sink is closed even if the
      // stream loop or notifyListeners throws. Without it, a network
      // hiccup mid-download leaves the file descriptor open until GC
      // and the partial file lingers on disk.
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            _downloadProgress = received / total;
            onProgress?.call(_downloadProgress!);
            notifyListeners();
          }
        }
      } finally {
        await sink.close().catchError((_) {});
      }
    } finally {
      client.close(force: true);
      _downloadProgress = null;
      notifyListeners();
    }
  }

  /// Download the SHA256SUMS file, locate the line for [info.assetName], and
  /// compare its hash against the locally-downloaded file at [filePath].
  ///
  /// Fail-closed: every non-`ok` result refuses the install. The caller maps
  /// each variant to a user-visible message.
  ///
  /// SHA256SUMS format is the standard `sha256sum` output:
  ///   `<64-hex-chars>  <filename>`  (two spaces as separator)
  Future<_ChecksumResult> _verifyChecksum(
    String filePath,
    UpdateInfo info,
  ) async {
    final client = HttpClient();
    String body;
    try {
      final req = await client.getUrl(Uri.parse(info.checksumUrl!));
      req.headers.set(HttpHeaders.userAgentHeader, 'bxp-gui-updater');
      final res = await req.close();
      if (res.statusCode != 200) {
        devTrace('updater.checksum.fetch', {'status': res.statusCode});
        return _ChecksumResult.fetchFailed;
      }
      body = await res.transform(utf8.decoder).join();
    } catch (e) {
      devTrace('updater.checksum.fetch-error', {'error': '$e'});
      return _ChecksumResult.fetchFailed;
    } finally {
      client.close(force: true);
    }
    String? expected;
    for (final line in body.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      // Format: "<hex>  <filename>" (two spaces, sha256sum-style).
      // We split on the first space and trim the rest to handle both the
      // two-space `sha256sum` convention and any single-space variants from
      // hand-crafted SUMS files.
      final idx = t.indexOf(' ');
      if (idx < 0) continue;
      final hex = t.substring(0, idx).trim();
      final name = t.substring(idx).trim();
      if (name == info.assetName) {
        expected = hex.toLowerCase();
        break;
      }
    }
    if (expected == null) {
      devTrace('updater.checksum.no-line', {'asset': info.assetName ?? ''});
      return _ChecksumResult.assetNotListed;
    }
    // Read the local file in full — installers are 50–200 MB but this is
    // a background operation. Streaming SHA-256 would save memory but adds
    // complexity for a one-time operation.
    final bytes = await File(filePath).readAsBytes();
    final actual = sha256.convert(bytes).toString().toLowerCase();
    if (expected != actual) {
      devTrace('updater.checksum.mismatch',
          {'expected': expected, 'actual': actual});
      return _ChecksumResult.mismatch;
    }
    return _ChecksumResult.ok;
  }

  Future<bool> _installWindows(String assetPath) async {
    // NSIS silent install; the post-install hook re-launches the app.
    await Process.start(
      assetPath,
      ['/S'],
      mode: ProcessStartMode.detached,
    );
    return true;
  }

  Future<bool> _installMacOS(String dmgPath) async {
    // Mount the DMG, find the .app inside, copy to ~/Applications/, unmount,
    // open the new copy via `open -n`. Bash is the simplest tool for this
    // chain; we keep it readable rather than re-implementing each step in
    // Dart's Process.run.
    final script = '''
set -e
MNT=\$(hdiutil attach -nobrowse -noautoopen "$dmgPath" | tail -n1 | awk '{print \$3}')
APP=\$(ls -d "\$MNT"/*.app | head -n1)
DEST="\$HOME/Applications"
mkdir -p "\$DEST"
rm -rf "\$DEST/\$(basename "\$APP")"
cp -R "\$APP" "\$DEST/"
hdiutil detach "\$MNT" -quiet
open -n "\$DEST/\$(basename "\$APP")"
''';
    final result = await Process.run('bash', ['-c', script]);
    if (result.exitCode != 0) {
      _lastError = 'macOS install failed: ${result.stderr}';
      return false;
    }
    return true;
  }

  Future<bool> _installLinuxAppImage(String newAppImagePath) async {
    // Atomic-replace the running AppImage. APPIMAGE env var points at the
    // currently mounted AppImage's filesystem path on disk.
    final current = Platform.environment['APPIMAGE'];
    if (current == null) {
      _lastError = 'APPIMAGE env var missing — cannot self-update';
      return false;
    }
    final bytes = await File(newAppImagePath).readAsBytes();
    final tmp = File('$current.new');
    await tmp.writeAsBytes(bytes, flush: true);
    await Process.run('chmod', ['+x', tmp.path]);
    await tmp.rename(current);
    // Re-exec — detached so the old process can exit cleanly.
    await Process.start(current, [], mode: ProcessStartMode.detached);
    return true;
  }

  /// Strip the leading `v` from a tag name (e.g. "v0.2.0" → "0.2.0").
  /// Tags without a prefix are returned unchanged — lets us compare against
  /// `PackageInfo.version` which never carries a `v`.
  static String _stripVPrefix(String tag) =>
      tag.startsWith('v') ? tag.substring(1) : tag;

  /// Strict semver-like compare: split on '.' and '-', compare numeric
  /// segments numerically and string segments lexicographically. Good
  /// enough for our `MAJOR.MINOR.PATCH[-rcN]` tag scheme.
  static bool _isNewer(String a, String b) {
    final aSegs = _segments(a);
    final bSegs = _segments(b);
    final n = aSegs.length > bSegs.length ? aSegs.length : bSegs.length;
    for (var i = 0; i < n; i++) {
      final av = i < aSegs.length ? aSegs[i] : 0;
      final bv = i < bSegs.length ? bSegs[i] : 0;
      final cmp = _compare(av, bv);
      if (cmp != 0) return cmp > 0;
    }
    return false;
  }

  static List<Object> _segments(String v) {
    return v.split(RegExp(r'[.\-]')).map<Object>((s) {
      final n = int.tryParse(s);
      return n ?? s;
    }).toList(growable: false);
  }

  static int _compare(Object a, Object b) {
    if (a is int && b is int) return a.compareTo(b);
    // A pre-release tag (e.g. "rc1") sorts BEFORE its base version, so a
    // numeric segment compared against a string segment ranks higher.
    if (a is int && b is String) return 1;
    if (a is String && b is int) return -1;
    return (a as String).compareTo(b as String);
  }
}

enum _ChecksumResult { ok, fetchFailed, assetNotListed, mismatch }

class UpdateInfo {
  final String version;     // stripped of "v" prefix
  final String tagName;     // raw, e.g. "v0.2.0"
  final String body;        // release notes (markdown)
  final String htmlUrl;     // GitHub release page
  final String? assetUrl;   // platform installer download (null on Linux non-AppImage)
  final String? assetName;  // file name of assetUrl
  final String? checksumUrl;// SHA256SUMS asset URL (null if not published)

  const UpdateInfo({
    required this.version,
    required this.tagName,
    required this.body,
    required this.htmlUrl,
    required this.assetUrl,
    required this.assetName,
    required this.checksumUrl,
  });
}
