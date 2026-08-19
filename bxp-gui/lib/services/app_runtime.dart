import 'dart:io';

/// Returns true when the current process is running from inside an
/// AppImage. Probes the `APPIMAGE` env var (set by the AppImage runtime
/// to the absolute path of the .AppImage file) and falls back to
/// inspecting `Platform.resolvedExecutable` for the `.mount_` suffix
/// the FUSE mount uses when `APPIMAGE` is not propagated to the child
/// (e.g. when the user re-execs the binary directly).
bool isRunningAsAppImage() {
  if (Platform.environment['APPIMAGE'] != null) return true;
  return Platform.resolvedExecutable.contains('.mount_');
}

/// Absolute path of the AppImage file the current process was launched
/// from, or null when the process is not running as an AppImage. This
/// is the value the `.desktop` entry's `Exec=` line should point at so
/// menu launches go through the same binary the user just ran.
String? appImagePath() => Platform.environment['APPIMAGE'];

/// Mount root of the AppImage's FUSE-mounted squashfs, or null when the
/// process is not running as an AppImage. Read-only; the bundled icon
/// tree lives at `$APPDIR/usr/share/icons/hicolor/<size>/apps/`.
String? appDirPath() => Platform.environment['APPDIR'];

/// Architecture of the Dart VM this process runs on, as the ABI suffix Dart
/// reports — `arm64`, `x64`, `ia32`, `riscv64`, … or null when the string
/// cannot be read.
///
/// `dart:io` exposes no architecture directly, so this parses the ABI tag out
/// of the trailing quoted token of [Platform.version], which reads e.g.
/// `3.13.0 (stable) (Wed Aug 5 …) on "macos_arm64"`. Split from
/// [hostArchitecture] so the parse can be tested without faking a platform.
String? architectureFromVersion(String version) {
  final start = version.lastIndexOf('"');
  if (start < 1) return null;
  final open = version.lastIndexOf('"', start - 1);
  if (open < 0) return null;
  final abi = version.substring(open + 1, start); // e.g. "macos_arm64"
  final sep = abi.indexOf('_');
  if (sep < 0 || sep + 1 >= abi.length) return null;
  return abi.substring(sep + 1);
}

/// Architecture of the running process — see [architectureFromVersion].
///
/// This is the architecture of the *binary*, not necessarily of the machine:
/// an x64 build under Rosetta 2 on Apple Silicon reports `x64`. That is the
/// conservative answer for "which release asset can this process be replaced
/// with" — it routes to the manual-update path instead of swapping in a build
/// the running install may not be able to launch.
String? hostArchitecture() => architectureFromVersion(Platform.version);
