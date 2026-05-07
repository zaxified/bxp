// Dart FFI client for bxp-gui-bridge — a small Zig shared library that
// proxies bxp-fmt / bxp-cli calls. Exists because dart:io's Process.start
// on Windows hits a deterministic ~8 KB cutoff when reading subprocess
// stdout (dart-lang/sdk#1727 + #51273); the bridge drains pipes from
// native code, sidestepping Dart's event loop entirely.
//
// On non-Windows platforms the bridge isn't load-bearing — Linux pipe
// buffers are ~64 KB and macOS unaffected — but we keep the same code
// path so the eventual `--expr` per-keystroke optimisation (no spawn
// overhead per call) lands cross-platform later.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// C ABI signature: bridge_run(const char* req, char* resp_buf, int32_t resp_size) -> int32_t.
// Returns # of bytes written, or -1 on bridge-level failure.
typedef _BridgeRunNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<Uint8>,
  Int32,
);
typedef _BridgeRunDart = int Function(
  Pointer<Utf8>,
  Pointer<Uint8>,
  int,
);

// bridge_version() -> const char* (null-terminated UTF-8). Used for a
// load-time sanity check that the DLL is the expected version, not
// some stale copy left over from an older install.
typedef _BridgeVersionNative = Pointer<Utf8> Function();
typedef _BridgeVersionDart = Pointer<Utf8> Function();

/// Result of a bridge-mediated subprocess invocation. Mirrors dart:io
/// `ProcessResult` conceptually; `err` is non-null only when the bridge
/// itself couldn't run the child (e.g. malformed request, spawn failed,
/// output exceeded the 4 MB cap).
class BridgeResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final String? err;

  const BridgeResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.err,
  });
}

class BridgeClient {
  final DynamicLibrary _lib;
  late final _BridgeRunDart _bridgeRun;
  late final _BridgeVersionDart _bridgeVersion;

  BridgeClient(String dllPath) : _lib = DynamicLibrary.open(dllPath) {
    _bridgeRun = _lib
        .lookupFunction<_BridgeRunNative, _BridgeRunDart>('bridge_run');
    _bridgeVersion = _lib
        .lookupFunction<_BridgeVersionNative, _BridgeVersionDart>(
            'bridge_version');
  }

  /// DLL self-reported version string, e.g. "0.2.1". Read once at load.
  String get bridgeVersion => _bridgeVersion().toDartString();

  /// Run `exe` with `args` via the bridge. Synchronous (blocks the
  /// calling isolate) — that's fine for one-shot startup calls but
  /// per-keystroke callers should wrap this in `Isolate.run`. The
  /// bridge itself has no built-in timeout; if the child hangs the
  /// caller is on its own to abandon the future.
  BridgeResult run(String exe, List<String> args) {
    // 4 MB matches the bridge's `max_output_bytes` cap. --docs is ~30 KB
    // today; this leaves ~100× headroom for future commands.
    const bufSize = 4 * 1024 * 1024;

    final request = jsonEncode({'exe': exe, 'args': args});
    final requestPtr = request.toNativeUtf8();
    final responseBuf = malloc.allocate<Uint8>(bufSize);

    try {
      final len = _bridgeRun(requestPtr, responseBuf, bufSize);
      if (len < 0) {
        return const BridgeResult(
          exitCode: -1,
          stdout: '',
          stderr: '',
          err: 'bridge: buffer overflow or fixed-writer failed',
        );
      }
      final bytes = responseBuf.asTypedList(len);
      final responseJson = utf8.decode(bytes);
      final response = jsonDecode(responseJson) as Map<String, dynamic>;
      return BridgeResult(
        exitCode: response['exit_code'] as int,
        stdout: response['stdout'] as String? ?? '',
        stderr: response['stderr'] as String? ?? '',
        err: response['err'] as String?,
      );
    } finally {
      malloc.free(requestPtr);
      malloc.free(responseBuf);
    }
  }
}

/// Resolves the bxp-gui-bridge shared library path next to
/// `bxp-gui.exe` / `bxp_gui` binary. Returns null if the file is
/// missing — callers should fall back to direct Process.start in
/// that case (and surface a diagnostic).
String? findBridgeLibrary() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final name = Platform.isWindows
      ? 'bxp-gui-bridge.dll'
      : Platform.isMacOS
          ? 'libbxp-gui-bridge.dylib'
          : 'libbxp-gui-bridge.so';
  final path = '$exeDir${Platform.pathSeparator}$name';
  return File(path).existsSync() ? path : null;
}
