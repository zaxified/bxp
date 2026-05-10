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

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

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

// C ABI for the streaming entrypoint:
//   bridge_run_streaming(req,
//                        on_stdout_batch,
//                        on_stderr_chunk,
//                        on_exit) -> int32_t
// Returns 0 on a successful start, -1 on any pre-spawn failure. The bridge
// hands ownership of every batch / chunk pointer to Dart; Dart MUST call
// bridge_free(ptr, len) once it has copied the bytes.
typedef _StreamCallbackNative = Void Function(Pointer<Uint8>, Uint32);
typedef _ExitCallbackNative = Void Function(Int32);
typedef _BridgeRunStreamingNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<NativeFunction<_StreamCallbackNative>>,
  Pointer<NativeFunction<_StreamCallbackNative>>,
  Pointer<NativeFunction<_ExitCallbackNative>>,
);
typedef _BridgeRunStreamingDart = int Function(
  Pointer<Utf8>,
  Pointer<NativeFunction<_StreamCallbackNative>>,
  Pointer<NativeFunction<_StreamCallbackNative>>,
  Pointer<NativeFunction<_ExitCallbackNative>>,
);

// bridge_free(ptr, len) — releases a buffer the bridge previously handed
// to Dart through a streaming callback.
typedef _BridgeFreeNative = Void Function(Pointer<Uint8>, Uint32);
typedef _BridgeFreeDart = void Function(Pointer<Uint8>, int);

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
  /// Response-buffer size for typical one-shot calls (bxp-fmt --docs /
  /// --config / --expr*). 4 MB covers --docs (~30 KB), --config
  /// annotations, and worst-case validation output with plenty of
  /// headroom. Used as the [run] default so per-keystroke calls don't
  /// allocate megabytes per validation tick.
  static const int defaultBufSize = 4 * 1024 * 1024;

  /// Response-buffer size for streaming runs (bxp-cli --trace), which
  /// emit NDJSON proportional to row count. 64 MB matches the bridge's
  /// max_output_bytes cap and covers ~300 K rows of trace output.
  /// Allocated only for the duration of the call and freed afterwards,
  /// so steady-state RAM cost is zero.
  static const int largeBufSize = 64 * 1024 * 1024;

  final DynamicLibrary _lib;
  late final _BridgeRunDart _bridgeRun;
  late final _BridgeVersionDart _bridgeVersion;
  late final _BridgeRunStreamingDart _bridgeRunStreaming;
  late final _BridgeFreeDart _bridgeFree;

  BridgeClient(String dllPath) : _lib = DynamicLibrary.open(dllPath) {
    _bridgeRun = _lib
        .lookupFunction<_BridgeRunNative, _BridgeRunDart>('bridge_run');
    _bridgeVersion = _lib
        .lookupFunction<_BridgeVersionNative, _BridgeVersionDart>(
            'bridge_version');
    _bridgeRunStreaming = _lib.lookupFunction<_BridgeRunStreamingNative,
        _BridgeRunStreamingDart>('bridge_run_streaming');
    _bridgeFree =
        _lib.lookupFunction<_BridgeFreeNative, _BridgeFreeDart>('bridge_free');
  }

  /// DLL self-reported version string, e.g. "0.2.1". Read once at load.
  String get bridgeVersion => _bridgeVersion().toDartString();

  /// Run `exe` with `args` via the bridge. Synchronous (blocks the
  /// calling isolate) — that's fine for one-shot startup calls but
  /// per-keystroke callers should wrap this in `Isolate.run`. The
  /// bridge itself has no built-in timeout; if the child hangs the
  /// caller is on its own to abandon the future.
  ///
  /// `cwd` sets the working directory of the child — required for
  /// bxp-cli runs so relative `data_dir` paths in the user's config
  /// resolve against the config file rather than bxp-gui's own CWD.
  /// `bufSize` controls the response-buffer allocation; default is
  /// large enough for `bxp-fmt --docs` / `--config` payloads but
  /// streaming runs should pass [largeBufSize] (~64 MB) so the cap
  /// doesn't truncate big NDJSON dumps.
  BridgeResult run(
    String exe,
    List<String> args, {
    String? cwd,
    int bufSize = defaultBufSize,
  }) {
    final request = jsonEncode({
      'exe': exe,
      'args': args,
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    });
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

  /// Streaming variant of [run]. Spawns the child, returns a Future that
  /// completes with its exit code, and reports stdout / stderr progressively
  /// via [onLine] / [onStderr] callbacks. Designed for the GUI's `--trace`
  /// dry-run path, where the user expects file-list + per-row counters to
  /// update in real time.
  ///
  /// Threading model: the bridge runs the child + drainers on its own native
  /// threads. Each batch / chunk fires through a `NativeCallable.listener`
  /// which dispatches the call onto the calling isolate's event loop, so all
  /// Dart-side work (UTF-8 decode, [onLine] / [onStderr], Completer.complete)
  /// runs on this isolate without crossing isolate boundaries.
  ///
  /// Memory contract: the bridge heap-allocates each batch / chunk on the
  /// C runtime (so does Dart's `package:ffi` malloc, but we still call the
  /// bridge's own `bridge_free` for symmetry and forward-compatibility). Dart
  /// must free promptly inside the callback — the buffer is single-owner
  /// and never reused by the bridge after the callback fires.
  ///
  /// The on_exit native callback is the single signal "all callbacks have
  /// drained, future can complete and NativeCallables can close". The bridge
  /// joins both reader threads before invoking on_exit, so no callback ever
  /// fires after the future resolves.
  Future<int> runStreaming(
    String exe,
    List<String> args, {
    String? cwd,
    required void Function(String line) onLine,
    void Function(String chunk)? onStderr,
  }) async {
    final completer = Completer<int>();

    void handleStdoutBatch(Pointer<Uint8> ptr, int len) {
      try {
        if (len > 0) {
          // Bridge guarantees the buffer is valid until we return; copy the
          // bytes through utf8.decode + LineSplitter immediately, then free.
          final text = utf8.decode(ptr.asTypedList(len), allowMalformed: true);
          for (final line in const LineSplitter().convert(text)) {
            if (line.isEmpty) continue;
            onLine(line);
          }
        }
      } finally {
        _bridgeFree(ptr, len);
      }
    }

    void handleStderrChunk(Pointer<Uint8> ptr, int len) {
      try {
        if (len > 0 && onStderr != null) {
          final chunk =
              utf8.decode(ptr.asTypedList(len), allowMalformed: true);
          onStderr(chunk);
        }
      } finally {
        _bridgeFree(ptr, len);
      }
    }

    void handleExit(int code) {
      if (!completer.isCompleted) completer.complete(code);
    }

    // NativeCallable.listener routes the native invocation through the
    // owning isolate's event loop — so the handlers above run here, not on
    // the bridge's reader thread.
    final stdoutCb = NativeCallable<_StreamCallbackNative>.listener(
      handleStdoutBatch,
    );
    final stderrCb = NativeCallable<_StreamCallbackNative>.listener(
      handleStderrChunk,
    );
    final exitCb =
        NativeCallable<_ExitCallbackNative>.listener(handleExit);

    final request = jsonEncode({
      'exe': exe,
      'args': args,
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    });
    final requestPtr = request.toNativeUtf8();

    int rc;
    try {
      rc = _bridgeRunStreaming(
        requestPtr,
        stdoutCb.nativeFunction,
        stderrCb.nativeFunction,
        exitCb.nativeFunction,
      );
    } finally {
      malloc.free(requestPtr);
    }

    if (rc != 0) {
      // Pre-spawn failure: bridge never armed any threads, so no exit
      // callback will fire. Resolve immediately and tear down callables.
      stdoutCb.close();
      stderrCb.close();
      exitCb.close();
      return -1;
    }

    try {
      return await completer.future;
    } finally {
      stdoutCb.close();
      stderrCb.close();
      exitCb.close();
    }
  }
}

/// Resolves the bxp-gui-bridge shared library path. Search order:
///
///   1. **Sibling next to the GUI binary** — production / release build.
///      The release packager copies the DLL/SO/DYLIB into the bundle
///      alongside `bxp-gui(.exe)`, so this hits first on installed apps.
///   2. **Dev-tree walk-up** — `flutter run` from the monorepo. Walks
///      upward from `Platform.resolvedExecutable` looking for the
///      `bxp-gui/` directory; its parent (the monorepo root) holds the
///      sibling `bxp-gui-bridge/zig-out/{bin,lib}/<name>` produced by
///      `zig build`. Mirrors the same pattern `findBin` uses for
///      bxp-cli/bxp-fmt so the dev workflow doesn't need a CMake
///      install step to make the bridge discoverable.
///
/// Returns null when probing fails. Windows: bridge is mandatory —
/// callers must surface a synthetic error rather than fall back to
/// Process.start (dart-lang/sdk#1727 truncates --docs/--config over
/// the ~8 KB Win pipe limit). Linux/macOS: bridge is dormant; this
/// returns null and callers go through Process.start directly.
String? findBridgeLibrary() {
  final name = Platform.isWindows
      ? 'bxp-gui-bridge.dll'
      : Platform.isMacOS
          ? 'libbxp-gui-bridge.dylib'
          : 'libbxp-gui-bridge.so';

  // (1) sibling next to the GUI binary — production layout.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final sibling = '$exeDir${Platform.pathSeparator}$name';
  if (File(sibling).existsSync()) return sibling;

  // (2) dev-tree walk-up. Zig places shared libraries under `zig-out/bin`
  // on Windows (DLL convention) and `zig-out/lib` on POSIX (.so/.dylib
  // convention). Probe both so the same code path works whatever
  // platform the developer is on.
  final subdirs = Platform.isWindows
      ? const ['bin']
      : const ['lib', 'bin'];
  Directory dir = Directory(exeDir);
  for (int i = 0; i < 10; i++) {
    final parent = dir.parent;
    if (parent.path == dir.path) break; // reached filesystem root
    if (p.basename(dir.path) == 'bxp-gui') {
      for (final sub in subdirs) {
        final candidate =
            p.join(parent.path, 'bxp-gui-bridge', 'zig-out', sub, name);
        if (File(candidate).existsSync()) return candidate;
      }
      break;
    }
    dir = parent;
  }

  return null;
}
