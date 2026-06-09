// Dart FFI client for bxp-gui-bridge — a small Zig shared library that is
// the GUI's single backend on every platform. It serves the stateless ops
// in-process (`bridge_inspect` / `bridge_eval_*`, linked against
// bxp-core/inspect — no bxp-fmt) and proxies `bxp-cli` runs through
// `bridge_run` / `bridge_run_streaming`, draining pipes from native code so
// dart:io's Process.start can't truncate stdout (the original Windows driver,
// dart-lang/sdk#1727 + #51273, that the cross-platform flip generalised).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

// C ABI signature:
//   bridge_run(const char* req,
//              const uint8_t* stdin_ptr, uint32_t stdin_len,
//              char* resp_buf, int32_t resp_size) -> int32_t.
// Returns # of bytes written, or -1 on bridge-level failure.
//
// `stdin_ptr` + `stdin_len` carry an optional input body written to the
// child's stdin pipe (e.g. the JSON request for `bxp-fmt --expr-batch`).
// When `stdin_len == 0` the child's stdin is closed immediately — the
// legacy `bxp-fmt --docs` shape. The bridge runs the stdin writer on its
// own thread so a body larger than the OS pipe buffer can't deadlock
// against the stdout/stderr drainers.
typedef _BridgeRunNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Int32,
);
typedef _BridgeRunDart = int Function(
  Pointer<Utf8>,
  Pointer<Uint8>,
  int,
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
//                        on_exit) -> int64_t
// Returns a positive opaque handle on success (use with bridge_cancel to
// abort), -1 on any pre-spawn failure. The bridge hands ownership of every
// batch / chunk pointer to Dart; Dart MUST call bridge_free(ptr, len) once
// it has copied the bytes.
typedef _StreamCallbackNative = Void Function(Pointer<Uint8>, Uint32);
typedef _ExitCallbackNative = Void Function(Int32);
typedef _BridgeRunStreamingNative = Int64 Function(
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

// bridge_cancel(handle) -> int32_t. Sends SIGTERM / TerminateProcess to a
// running stream's child. Returns 0 on signal sent, -1 if the handle is
// unknown (already exited, or never valid). Idempotent.
typedef _BridgeCancelNative = Int32 Function(Int64);
typedef _BridgeCancelDart = int Function(int);

// bridge_ack(handle) -> int32_t. Releases one permit on the stream's
// backpressure semaphore. Dart calls this after processing each stdout
// batch (decode + onLine + free) so the bridge can dispatch the next.
// Without acks, the reader thread blocks after `default_queue_permits`
// in-flight batches, bounding worst-case in-flight memory.
typedef _BridgeAckNative = Int32 Function(Int64);
typedef _BridgeAckDart = int Function(int);

// bridge_free(ptr, len) — releases a buffer the bridge previously handed
// to Dart through a streaming callback.
typedef _BridgeFreeNative = Void Function(Pointer<Uint8>, Uint32);
typedef _BridgeFreeDart = void Function(Pointer<Uint8>, int);

// C ABI for the in-process expression evaluator family
// (see "Adding a new bridge FFI export" in docs/devel.md). Stateless,
// caller-owned buffers, no Dart-side bridge_free required.
//
//   bridge_eval_expr(text_ptr, text_len, out_buf, out_size) -> int32_t
//     0 = valid expression
//     >0 = bytes_written of JSON error in out_buf
//          (shape mirrors `bxp-fmt --expr` stderr — `{"error","detail","off","len"}`)
//     -1 OOM, -2 BUF_TOO_SMALL, -3 INVALID_INPUT
typedef _BridgeEvalExprNative = Int32 Function(
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
);
typedef _BridgeEvalExprDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

//   bridge_eval_expr_trace(text_ptr, text_len,
//                          headers_json_ptr, headers_json_len,
//                          fields_json_ptr, fields_json_len,
//                          out_buf, out_size) -> int32_t
//     0 = empty input (no payload)
//     >0 = bytes_written of NDJSON in out_buf
//          (per-call lines + {"t":"final"|"error",...} sentinel)
//     -1 OOM, -2 BUF_TOO_SMALL, -3 INVALID_INPUT
typedef _BridgeEvalExprTraceNative = Int32 Function(
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
);
typedef _BridgeEvalExprTraceDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

// bridge_inspect(request_ptr, request_len, out_buf, out_size) -> int32_t
//   In-process dispatcher for the stateless bxp-fmt ops the GUI used to spawn
//   (docs / config / list_templates / fetch_template / eval_batch). The result
//   JSON (same bytes the matching bxp-fmt stdout produced) is written to out_buf.
//     >0 = bytes_written of result JSON in out_buf
//     -1 OOM, -2 BUF_TOO_SMALL, -3 INVALID_INPUT
typedef _BridgeInspectNative = Int32 Function(
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
);
typedef _BridgeInspectDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

/// Result of a bridge-mediated subprocess invocation. Mirrors dart:io
/// `ProcessResult` conceptually; `err` is non-null only when the bridge
/// itself couldn't run the child (e.g. malformed request, spawn failed).
/// `truncated` is set when stdout or stderr exceeded the bridge's
/// per-stream cap (64 MB) — the captured prefix is still in stdout /
/// stderr so callers can render whatever fits.
class BridgeResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final String? err;
  final bool truncated;

  const BridgeResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.err,
    this.truncated = false,
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
  /// emit BXTB frames proportional to row count. 64 MB matches the
  /// bridge's max_output_bytes cap and covers ~5 M output_row frames
  /// (assuming ~12-byte average frame size). Allocated only for the
  /// duration of the call and freed afterwards, so steady-state RAM
  /// cost is zero.
  static const int largeBufSize = 64 * 1024 * 1024;

  final DynamicLibrary _lib;
  late final _BridgeRunDart _bridgeRun;
  late final _BridgeVersionDart _bridgeVersion;
  late final _BridgeRunStreamingDart _bridgeRunStreaming;
  late final _BridgeCancelDart _bridgeCancel;
  late final _BridgeAckDart _bridgeAck;
  late final _BridgeFreeDart _bridgeFree;
  late final _BridgeEvalExprDart _bridgeEvalExpr;
  late final _BridgeEvalExprTraceDart _bridgeEvalExprTrace;
  late final _BridgeInspectDart _bridgeInspect;

  BridgeClient(String dllPath) : _lib = DynamicLibrary.open(dllPath) {
    _bridgeRun = _lib
        .lookupFunction<_BridgeRunNative, _BridgeRunDart>('bridge_run');
    _bridgeVersion = _lib
        .lookupFunction<_BridgeVersionNative, _BridgeVersionDart>(
            'bridge_version');
    _bridgeRunStreaming = _lib.lookupFunction<_BridgeRunStreamingNative,
        _BridgeRunStreamingDart>('bridge_run_streaming');
    _bridgeCancel = _lib
        .lookupFunction<_BridgeCancelNative, _BridgeCancelDart>('bridge_cancel');
    _bridgeAck = _lib
        .lookupFunction<_BridgeAckNative, _BridgeAckDart>('bridge_ack');
    _bridgeFree =
        _lib.lookupFunction<_BridgeFreeNative, _BridgeFreeDart>('bridge_free');
    _bridgeEvalExpr = _lib.lookupFunction<_BridgeEvalExprNative,
        _BridgeEvalExprDart>('bridge_eval_expr');
    _bridgeEvalExprTrace = _lib.lookupFunction<_BridgeEvalExprTraceNative,
        _BridgeEvalExprTraceDart>('bridge_eval_expr_trace');
    _bridgeInspect = _lib
        .lookupFunction<_BridgeInspectNative, _BridgeInspectDart>('bridge_inspect');
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
  /// `stdin` is an optional input body written to the child's stdin
  /// pipe — required by `bxp-fmt --expr-batch`, which reads a JSON
  /// request body from stdin. When omitted the child's stdin is closed
  /// immediately (legacy shape used by `--docs` / `--config`).
  /// `bufSize` controls the response-buffer allocation; default is
  /// large enough for `bxp-fmt --docs` / `--config` payloads but
  /// streaming runs should pass [largeBufSize] (~64 MB) so the cap
  /// doesn't truncate big trace dumps.
  BridgeResult run(
    String exe,
    List<String> args, {
    String? cwd,
    Uint8List? stdin,
    int bufSize = defaultBufSize,
  }) {
    final request = jsonEncode({
      'exe': exe,
      'args': args,
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    });
    final requestPtr = request.toNativeUtf8();
    // Allocate a 1-byte placeholder when no stdin is supplied — the C ABI
    // requires a non-null pointer even when `stdin_len == 0`, and Zig
    // never dereferences the pointer in that case.
    final stdinLen = stdin?.length ?? 0;
    final stdinPtr = malloc.allocate<Uint8>(stdinLen == 0 ? 1 : stdinLen);
    if (stdinLen > 0) {
      stdinPtr.asTypedList(stdinLen).setAll(0, stdin!);
    }
    try {
      final firstAttempt = _runWithBuffer(requestPtr, stdinPtr, stdinLen, bufSize);
      if (firstAttempt != null) return firstAttempt;
      // Buffer too small for the encoded response. The bridge captures up
      // to [largeBufSize] bytes of child output, so a single retry with
      // the larger buffer is guaranteed to fit any non-truncated payload.
      // Skip the retry when the caller already passed [largeBufSize] —
      // that means the bridge truncated and the response really is too
      // big for any fixed-size response shape we care to allocate.
      if (bufSize >= largeBufSize) {
        return const BridgeResult(
          exitCode: -1,
          stdout: '',
          stderr: '',
          err: 'bridge: response exceeds largeBufSize',
        );
      }
      final retried =
          _runWithBuffer(requestPtr, stdinPtr, stdinLen, largeBufSize);
      if (retried != null) return retried;
      return const BridgeResult(
        exitCode: -1,
        stdout: '',
        stderr: '',
        err: 'bridge: response exceeds largeBufSize after retry',
      );
    } finally {
      malloc.free(requestPtr);
      malloc.free(stdinPtr);
    }
  }

  /// Single bridge_run call with a freshly allocated response buffer.
  /// Returns null on overflow (-1 from the bridge) so [run] can decide
  /// whether to retry with a larger buffer; returns a parsed result on
  /// any other outcome (success or bridge-level error).
  BridgeResult? _runWithBuffer(
    Pointer<Utf8> requestPtr,
    Pointer<Uint8> stdinPtr,
    int stdinLen,
    int bufSize,
  ) {
    final responseBuf = malloc.allocate<Uint8>(bufSize);
    try {
      final len = _bridgeRun(requestPtr, stdinPtr, stdinLen, responseBuf, bufSize);
      if (len < 0) return null;
      final bytes = responseBuf.asTypedList(len);
      final responseJson = utf8.decode(bytes);
      final response = jsonDecode(responseJson) as Map<String, dynamic>;
      return BridgeResult(
        exitCode: response['exit_code'] as int,
        stdout: response['stdout'] as String? ?? '',
        stderr: response['stderr'] as String? ?? '',
        err: response['err'] as String?,
        truncated: response['truncated'] as bool? ?? false,
      );
    } finally {
      malloc.free(responseBuf);
    }
  }

  /// Signal cancellation to a streaming run. [handle] is the value
  /// returned by [_bridgeRunStreaming] (positive on success). Returns
  /// `true` if the kill signal was delivered, `false` if the handle is
  /// unknown (already exited, or never valid). Idempotent — calling
  /// after natural exit is a safe no-op.
  bool cancel(int handle) => _bridgeCancel(handle) == 0;

  /// Default out_buf size for the in-process expression family. 4 KB
  /// covers a typical expr error JSON (typically < 1 KB) with headroom.
  /// On overflow we retry once with [_evalLargeBufSize] before giving up.
  static const int _evalDefaultBufSize = 4 * 1024;

  /// Retry buffer size when 4 KB overflows. 64 KB fits even pathological
  /// expr-trace outputs (hundreds of nested function calls).
  static const int _evalLargeBufSize = 64 * 1024;

  /// In-process counterpart to `bxp-fmt --expr <text>` — validates an
  /// expression's syntax + semantic correctness without spawning a
  /// subprocess. Sub-ms latency, safe to call from the main isolate.
  ///
  /// Return shape mirrors [BxpProcessClient.validateExpr]:
  ///   * `error == null` — valid expression
  ///   * `error != null` — invalid; `offset`/`length` populated when the
  ///     parser pinned the offending token span (for inline UI highlight)
  ({String? error, int? offset, int? length}) evalExpr(String text) {
    if (text.isEmpty) {
      return (error: null, offset: null, length: null);
    }
    final firstAttempt = _evalExprWithBuffer(text, _evalDefaultBufSize);
    if (firstAttempt != null) return firstAttempt;
    final retried = _evalExprWithBuffer(text, _evalLargeBufSize);
    if (retried != null) return retried;
    return (error: 'bridge: eval response exceeds 64 KB', offset: null, length: null);
  }

  /// Single bridge_eval_expr call with a freshly allocated buffer.
  /// Returns null on BUF_TOO_SMALL (-2) so [evalExpr] can retry larger;
  /// otherwise returns the parsed result (success or error).
  ({String? error, int? offset, int? length})? _evalExprWithBuffer(
    String text,
    int bufSize,
  ) {
    final textBytes = utf8.encode(text);
    final textPtr = malloc.allocate<Uint8>(textBytes.length);
    final outBuf = malloc.allocate<Uint8>(bufSize);
    try {
      textPtr.asTypedList(textBytes.length).setAll(0, textBytes);
      final n =
          _bridgeEvalExpr(textPtr, textBytes.length, outBuf, bufSize);
      if (n == 0) {
        return (error: null, offset: null, length: null);
      }
      if (n == -2) return null; // BUF_TOO_SMALL → caller retries
      if (n < 0) {
        return (error: 'bridge: eval error code $n', offset: null, length: null);
      }
      final bytes = outBuf.asTypedList(n);
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(bytes));
      } catch (e) {
        // FFI bug: bridge wrote non-JSON bytes. Surface the parse
        // exception so the operator can correlate against bridge logs
        // instead of staring at "malformed eval response".
        return (
          error: 'bridge: eval response parse failed: $e',
          offset: null,
          length: null,
        );
      }
      if (json is! Map) {
        return (error: 'bridge: malformed eval response', offset: null, length: null);
      }
      final err = json['error'];
      final detail = json['detail'];
      final off = json['off'];
      final len = json['len'];
      final offset = off is int ? off : null;
      final length = len is int ? len : null;
      if (err is String && err.isNotEmpty) {
        final msg = (detail is String && detail.isNotEmpty)
            ? '$err: $detail'
            : err;
        return (error: msg, offset: offset, length: length);
      }
      return (error: null, offset: null, length: null);
    } finally {
      malloc.free(textPtr);
      malloc.free(outBuf);
    }
  }

  /// In-process counterpart to `bxp-fmt --expr-trace TEXT --row-headers
  /// HEADERS_JSON --row-fields FIELDS_JSON`. Returns the raw NDJSON payload — per-fn
  /// call lines plus a final `{"t":"final"|"error",...}` sentinel — for
  /// the caller to parse. Sub-ms latency, safe from the main isolate.
  ///
  /// Returns null on bridge-level failure (OOM, INVALID_INPUT,
  /// BUF_TOO_SMALL after retry); caller should fall back to subprocess.
  String? evalExprTrace({
    required String text,
    required List<String> headers,
    required List<String> fields,
  }) {
    if (text.isEmpty) return '';
    final headersJson = jsonEncode(headers);
    final fieldsJson = jsonEncode(fields);
    final firstAttempt =
        _evalExprTraceWithBuffer(text, headersJson, fieldsJson, _evalDefaultBufSize);
    if (firstAttempt != null) return firstAttempt;
    return _evalExprTraceWithBuffer(text, headersJson, fieldsJson, _evalLargeBufSize);
  }

  String? _evalExprTraceWithBuffer(
    String text,
    String headersJson,
    String fieldsJson,
    int bufSize,
  ) {
    final textBytes = utf8.encode(text);
    final headersBytes = utf8.encode(headersJson);
    final fieldsBytes = utf8.encode(fieldsJson);
    final textPtr = malloc.allocate<Uint8>(textBytes.length);
    final headersPtr = malloc.allocate<Uint8>(headersBytes.length);
    final fieldsPtr = malloc.allocate<Uint8>(fieldsBytes.length);
    final outBuf = malloc.allocate<Uint8>(bufSize);
    try {
      textPtr.asTypedList(textBytes.length).setAll(0, textBytes);
      headersPtr.asTypedList(headersBytes.length).setAll(0, headersBytes);
      fieldsPtr.asTypedList(fieldsBytes.length).setAll(0, fieldsBytes);
      final n = _bridgeEvalExprTrace(
        textPtr,
        textBytes.length,
        headersPtr,
        headersBytes.length,
        fieldsPtr,
        fieldsBytes.length,
        outBuf,
        bufSize,
      );
      if (n == 0) return '';
      if (n == -2) return null; // BUF_TOO_SMALL → caller retries
      if (n < 0) return null; // OOM / INVALID_INPUT → caller falls back
      return utf8.decode(outBuf.asTypedList(n));
    } finally {
      malloc.free(textPtr);
      malloc.free(headersPtr);
      malloc.free(fieldsPtr);
      malloc.free(outBuf);
    }
  }

  /// Default out_buf for [inspect]. 128 KB covers `--docs` (~30 KB) and most
  /// annotated `--config` payloads; we retry once at [_inspectLargeBufSize].
  static const int _inspectDefaultBufSize = 128 * 1024;

  /// Retry buffer for [inspect] — fits a large annotated config or a
  /// pathological eval_batch result.
  static const int _inspectLargeBufSize = 4 * 1024 * 1024;

  /// In-process counterpart to the stateless `bxp-fmt` subcommands the GUI used
  /// to spawn — `--docs`, `--config`, `--list-templates`, `--fetch-template`,
  /// `--expr-batch` — served from bxp-core/inspect via `bridge_inspect`.
  /// `requestJson` is the op envelope (see the Zig export). Returns the result
  /// JSON (the same bytes the matching bxp-fmt stdout produced), or null on any
  /// bridge-level failure / overflow so the caller can fall back to the
  /// subprocess. Synchronous FFI; callers run it on a discrete load/save/click
  /// action, not per-keystroke.
  String? inspect(String requestJson) {
    final reqBytes = utf8.encode(requestJson);
    for (final bufSize in const [_inspectDefaultBufSize, _inspectLargeBufSize]) {
      final reqPtr = malloc.allocate<Uint8>(reqBytes.isEmpty ? 1 : reqBytes.length);
      final outBuf = malloc.allocate<Uint8>(bufSize);
      try {
        if (reqBytes.isNotEmpty) {
          reqPtr.asTypedList(reqBytes.length).setAll(0, reqBytes);
        }
        final n = _bridgeInspect(reqPtr, reqBytes.length, outBuf, bufSize);
        if (n == -2) continue; // BUF_TOO_SMALL → retry larger
        if (n < 0) return null; // OOM / INVALID_INPUT → caller falls back
        return utf8.decode(outBuf.asTypedList(n));
      } finally {
        malloc.free(reqPtr);
        malloc.free(outBuf);
      }
    }
    return null; // still too big after the largest buffer
  }

  /// Streaming variant of [run]. Spawns the child, returns a Future that
  /// completes with its exit code, and reports stdout as raw binary chunks
  /// via [onChunk] and stderr via [onStderr]. Designed for the GUI's
  /// `--trace` dry-run path, where the user expects file-list + per-row
  /// counters to update in real time.
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
  /// Spawn a child process and stream its stdout as raw binary chunks via
  /// [onChunk]. The bridge always dispatches raw pipe-read chunks (no
  /// newline batching), designed for the bxp-cli `--trace=bin` (BXTB)
  /// path where stdout is a binary frame stream with no line boundaries.
  Future<int> runStreamingBinary(
    String exe,
    List<String> args, {
    String? cwd,
    required void Function(Uint8List chunk) onChunk,
    void Function(String chunk)? onStderr,
    void Function(int handle)? onSpawn,
  }) async {
    final completer = Completer<int>();
    // Captured by `handleStdoutBatch` so each batch acks the bridge's
    // backpressure semaphore after we've processed + freed it. Stays
    // null until [_bridgeRunStreaming] returns a positive handle —
    // callbacks can't fire before then, so the null-check is purely
    // defensive against the pre-spawn failure path.
    int? streamHandle;

    void handleStdoutBatch(Pointer<Uint8> ptr, int len) {
      try {
        if (len > 0) {
          // Copy the bytes out of the bridge-owned buffer before
          // bridge_free below. Uint8List.fromList copies; callers can
          // hold the chunk past the callback return safely.
          final chunk = Uint8List.fromList(ptr.asTypedList(len));
          onChunk(chunk);
        }
      } finally {
        _bridgeFree(ptr, len);
        // Release one permit on the bridge's per-stream queue semaphore
        // so the reader thread can dispatch the next batch. Without this
        // the reader blocks after `default_queue_permits` (32) in-flight
        // batches and the stream stalls.
        final h = streamHandle;
        if (h != null) _bridgeAck(h);
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

    int handle;
    try {
      handle = _bridgeRunStreaming(
        requestPtr,
        stdoutCb.nativeFunction,
        stderrCb.nativeFunction,
        exitCb.nativeFunction,
      );
    } finally {
      malloc.free(requestPtr);
    }

    if (handle <= 0) {
      // Pre-spawn failure: bridge never armed any threads, so no exit
      // callback will fire. Resolve immediately and tear down callables.
      stdoutCb.close();
      stderrCb.close();
      exitCb.close();
      return -1;
    }
    streamHandle = handle;

    onSpawn?.call(handle);

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
/// Returns null when probing fails. The bridge is mandatory on every
/// platform now — it is the GUI's only backend (stateless inspect/eval
/// in-process + `bxp-cli` runs via the proxy), so a null here means a broken
/// install and the startup gate surfaces a fatal error rather than falling
/// back to anything.
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
