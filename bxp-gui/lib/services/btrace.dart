/// Dart-side parser for the bxp-cli `--trace` binary BXTB stream.
///
/// Mirrors `bxp-core/src/btrace.zig`. Reads the BXTB-magic-prefixed header,
/// then a sequence of length-prefixed frames. Unknown frame types are
/// silently skipped via the `pay_len` field (forward compatible). UTF-8 is
/// the wire encoding for all variable-length strings (`lp` = u32 length +
/// bytes).
///
/// Live source for `TraceStore`'s streaming Runner pipeline — every
/// `--trace` invocation flows through this parser frame-by-frame.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Magic at the start of every binary trace stream — little-endian u32
/// reading as ASCII "BXTB". Sanity check only; producer (bxp-cli) and
/// consumer (this file) ship together in every release, so there is no
/// schema version on the wire.
const int frameMagic = 0x42545842;

/// Per-frame header is 7 bytes: type (u8) + chunk_id (u16 LE) + pay_len (u32 LE).
const int frameHeaderSize = 7;

/// Frame type enum mirroring `btrace.zig FrameType`.
enum FrameType {
  fileStart(0x01),
  fileEnd(0x02),
  outputRow(0x03),
  filteredRow(0x04),
  errorRow(0x05),
  prepassEntry(0x06),
  done(0x07);

  final int value;
  const FrameType(this.value);

  static FrameType? fromByte(int b) {
    for (final t in FrameType.values) {
      if (t.value == b) return t;
    }
    return null;
  }
}

/// Input format hint inside file_start payload.
enum InputFormat {
  csv(0),
  json(1),
  xlsxIntermediateCsv(2);

  final int value;
  const InputFormat(this.value);

  static InputFormat fromByte(int b) {
    for (final f in InputFormat.values) {
      if (f.value == b) return f;
    }
    throw FormatException('btrace: unknown InputFormat tag $b');
  }
}

/// Base type for all decoded frames. `chunkId` is reserved for future
/// multicore chunk dispatch (always 0 today; readers MUST tolerate any value).
sealed class Frame {
  final int chunkId;
  const Frame(this.chunkId);
}

class FileStart extends Frame {
  final InputFormat inputFormat;
  final String template;
  final String path;
  final List<String> headers;

  const FileStart(super.chunkId, this.inputFormat, this.template, this.path,
      this.headers);
}

class FileEnd extends Frame {
  final int sourceRows;
  final int writtenRows;
  final int errors;
  final int warnings;
  const FileEnd(
      super.chunkId, this.sourceRows, this.writtenRows, this.errors, this.warnings);
}

class OutputRow extends Frame {
  /// File byte offset of the source record (CSV / JSON / xlsx-intermediate-CSV).
  /// Use with `the bridge --row-offset=N` for drill-down.
  final int sourceLocator;

  /// Running output-row counter inside the file (0-based, includes earlier
  /// output rows produced by the same source record when the matched rule
  /// emits more than one row).
  final int outputIdx;

  /// Index of the matched row_rule, or -1 when no rule matched (unreachable
  /// today because non-matching rows take the filtered_row path; future
  /// modes may emit -1 for "no rules block").
  final int ruleIdx;

  /// `$action` value after rule overrides applied (e.g. "BUY", "SELL").
  final String action;

  const OutputRow(super.chunkId, this.sourceLocator, this.outputIdx,
      this.ruleIdx, this.action);
}

class FilteredRow extends Frame {
  final int sourceLocator;
  final String reason;
  const FilteredRow(super.chunkId, this.sourceLocator, this.reason);
}

class ErrorRow extends Frame {
  final int sourceLocator;
  final String varName;
  final String errorKind;
  final String detail;

  /// "input_schema" or "row_rules". Use as a discriminator when rendering.
  final String origin;

  const ErrorRow(super.chunkId, this.sourceLocator, this.varName,
      this.errorKind, this.detail, this.origin);
}

class PrepassEntry extends Frame {
  final String name;
  final String key;
  final String field;
  final String value;
  const PrepassEntry(super.chunkId, this.name, this.key, this.field, this.value);
}

class Done extends Frame {
  final int exitCode;
  const Done(super.chunkId, this.exitCode);
}

/// Reader over a `Uint8List` byte buffer that supports both bulk and
/// streaming modes.
///
/// **Bulk mode** ([fromBytes]): the caller hands over a fully-loaded
/// buffer (e.g. read from disk). Constructor verifies the magic
/// eagerly. `nextFrame()` returns one frame at a time and throws
/// `FormatException` on truncated headers/payloads.
///
/// **Streaming mode** ([streaming]): constructor starts with an empty
/// buffer and an unverified header. The caller pumps bytes via
/// [appendBytes] as they arrive on a Process stdout pipe, then drains
/// frames via [nextFrame] which returns `null` when there aren't enough
/// bytes for the next full frame (caller waits for more chunks before
/// retrying). The magic is validated lazily once the first 4 bytes have
/// been buffered (there is no schema version on the wire).
class BtraceReader {
  Uint8List _data;
  ByteData _bd;
  int _pos = 0;
  bool _headerVerified;
  final bool _streaming;

  BtraceReader._(this._data, this._bd, this._pos, this._headerVerified, this._streaming);

  /// Validates magic, returns a reader positioned past the header.
  factory BtraceReader.fromBytes(Uint8List data) {
    if (data.length < 4) {
      throw FormatException(
          'btrace stream too short: ${data.length} bytes (need ≥ 4 for magic)');
    }
    final bd = ByteData.sublistView(data);
    final magic = bd.getUint32(0, Endian.little);
    if (magic != frameMagic) {
      throw FormatException(
          'btrace: bad magic 0x${magic.toRadixString(16).padLeft(8, '0')} '
          '(expected 0x${frameMagic.toRadixString(16).padLeft(8, '0')} = "BXTB")');
    }
    return BtraceReader._(data, bd, 4, true, false);
  }

  /// Empty reader for streaming mode. Caller pumps bytes via [appendBytes]
  /// and drains frames via [nextFrame] (returns null when starved). The
  /// magic is verified lazily once the first 4 bytes have been fed;
  /// the first nextFrame call on an unverified stream may throw
  /// `FormatException` if the magic check fails.
  factory BtraceReader.streaming() {
    final empty = Uint8List(0);
    return BtraceReader._(
        empty, ByteData.sublistView(empty), 0, false, true);
  }

  /// Streaming mode: append [chunk] to the internal buffer so the next
  /// nextFrame() drain has fresh bytes to parse. Throws `StateError` if
  /// called on a bulk-mode reader.
  void appendBytes(List<int> chunk) {
    if (!_streaming) {
      throw StateError('appendBytes called on bulk-mode BtraceReader');
    }
    if (chunk.isEmpty) return;
    final out = Uint8List(_data.length + chunk.length);
    out.setRange(0, _data.length, _data);
    out.setRange(_data.length, out.length, chunk);
    _data = out;
    _bd = ByteData.sublistView(_data);
  }

  /// True iff there are more bytes available (not necessarily a full frame).
  bool get hasMore => _pos < _data.length;

  /// Current byte position (after header). Useful for diagnostics.
  int get position => _pos;

  /// Returns next frame, or `null` when there are no more frames available.
  ///
  /// In bulk mode `null` means EOF (the reader's buffer has been fully
  /// consumed); a truncated header/payload throws `FormatException`.
  ///
  /// In streaming mode `null` means "need more bytes" — the caller should
  /// pump more chunks via [appendBytes] and retry. The header/payload
  /// checks below treat short buffers as starvation, not as a format error.
  ///
  /// Unknown frame types are silently skipped via the `pay_len` prefix
  /// (forward compat).
  Frame? nextFrame() {
    // Lazy header verification on streaming-mode first call.
    if (!_headerVerified) {
      if (_data.length < 4) return null;
      final magic = _bd.getUint32(0, Endian.little);
      if (magic != frameMagic) {
        throw FormatException(
            'btrace: bad magic 0x${magic.toRadixString(16).padLeft(8, '0')} '
            '(expected 0x${frameMagic.toRadixString(16).padLeft(8, '0')} = "BXTB")');
      }
      _headerVerified = true;
      _pos = 4;
    }
    while (_pos < _data.length) {
      if (_pos + frameHeaderSize > _data.length) {
        if (_streaming) return null;
        throw FormatException(
            'btrace: truncated frame header at offset $_pos '
            '(have ${_data.length - _pos} bytes, need $frameHeaderSize)');
      }
      final typeByte = _data[_pos];
      final chunkId = _bd.getUint16(_pos + 1, Endian.little);
      final payLen = _bd.getUint32(_pos + 3, Endian.little);
      if (_pos + frameHeaderSize + payLen > _data.length) {
        // Streaming mode: payload not fully buffered yet, wait for more.
        // Bulk mode: truncated file → format error.
        if (_streaming) return null;
        throw FormatException(
            'btrace: truncated payload at offset ${_pos + frameHeaderSize} '
            '(need $payLen, have ${_data.length - _pos - frameHeaderSize})');
      }
      // Commit position past header only once we know the full frame is in.
      _pos += frameHeaderSize;
      final payloadEnd = _pos + payLen;
      final frameType = FrameType.fromByte(typeByte);
      if (frameType == null) {
        // Forward compat: skip unknown frame via pay_len.
        _pos = payloadEnd;
        continue;
      }
      final result = switch (frameType) {
        FrameType.fileStart => _readFileStart(chunkId),
        FrameType.fileEnd => _readFileEnd(chunkId),
        FrameType.outputRow => _readOutputRow(chunkId),
        FrameType.filteredRow => _readFilteredRow(chunkId),
        FrameType.errorRow => _readErrorRow(chunkId),
        FrameType.prepassEntry => _readPrepassEntry(chunkId),
        FrameType.done => _readDone(chunkId),
      };
      assert(_pos == payloadEnd,
          'btrace: payload over/underrun for ${frameType.name} '
          '(read to $_pos, payload ended at $payloadEnd)');
      // Defensive: if asserts are off and a parser drifted, re-anchor to the
      // declared payload end so subsequent frames stay aligned.
      _pos = payloadEnd;
      return result;
    }
    return null;
  }

  // ── per-type readers ──────────────────────────────────────────────────────

  FileStart _readFileStart(int chunkId) {
    final fmt = InputFormat.fromByte(_data[_pos]);
    _pos += 1;
    final template = _readLp();
    final path = _readLp();
    final headersCount = _bd.getUint16(_pos, Endian.little);
    _pos += 2;
    final headers = <String>[
      for (int i = 0; i < headersCount; i++) _readLp(),
    ];
    return FileStart(chunkId, fmt, template, path, headers);
  }

  FileEnd _readFileEnd(int chunkId) {
    final sourceRows = _bd.getUint64(_pos, Endian.little);
    final writtenRows = _bd.getUint64(_pos + 8, Endian.little);
    final errors = _bd.getUint32(_pos + 16, Endian.little);
    final warnings = _bd.getUint32(_pos + 20, Endian.little);
    _pos += 24;
    return FileEnd(chunkId, sourceRows, writtenRows, errors, warnings);
  }

  OutputRow _readOutputRow(int chunkId) {
    final sourceLocator = _bd.getUint64(_pos, Endian.little);
    final outputIdx = _bd.getUint64(_pos + 8, Endian.little);
    final ruleIdx = _bd.getInt32(_pos + 16, Endian.little);
    _pos += 20;
    final action = _readLp();
    return OutputRow(chunkId, sourceLocator, outputIdx, ruleIdx, action);
  }

  FilteredRow _readFilteredRow(int chunkId) {
    final sourceLocator = _bd.getUint64(_pos, Endian.little);
    _pos += 8;
    final reason = _readLp();
    return FilteredRow(chunkId, sourceLocator, reason);
  }

  ErrorRow _readErrorRow(int chunkId) {
    final sourceLocator = _bd.getUint64(_pos, Endian.little);
    _pos += 8;
    final varName = _readLp();
    final errorKind = _readLp();
    final detail = _readLp();
    final origin = _readLp();
    return ErrorRow(chunkId, sourceLocator, varName, errorKind, detail, origin);
  }

  PrepassEntry _readPrepassEntry(int chunkId) {
    final name = _readLp();
    final key = _readLp();
    final field = _readLp();
    final value = _readLp();
    return PrepassEntry(chunkId, name, key, field, value);
  }

  Done _readDone(int chunkId) {
    final exitCode = _bd.getInt32(_pos, Endian.little);
    _pos += 4;
    return Done(chunkId, exitCode);
  }

  String _readLp() {
    final len = _bd.getUint32(_pos, Endian.little);
    _pos += 4;
    final bytes = _data.sublist(_pos, _pos + len);
    _pos += len;
    return utf8.decode(bytes);
  }
}
