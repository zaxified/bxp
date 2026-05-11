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
