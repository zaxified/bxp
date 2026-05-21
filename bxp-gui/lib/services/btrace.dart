/// Dart-side parser for the bxp-cli `--trace=bin` binary stream.
///
/// Mirrors `bxp-core/src/btrace.zig`. Reads the BXTB-magic-prefixed header,
/// then a sequence of length-prefixed frames. Unknown frame types are
/// silently skipped via the `pay_len` field (forward compatible). UTF-8 is
/// the wire encoding for all variable-length strings (`lp` = u32 length +
/// bytes).
///
/// PR-A status: pure parser with no UI consumer yet. `BxpProcessClient`
/// continues to spawn bxp-cli with `--trace=json` (NDJSON) by default; this
/// file just makes the binary format readable from Dart so subsequent PRs
/// can swap consumers panel by panel.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Magic at the start of every binary trace stream — little-endian u32
/// reading as ASCII "BXTB".
const int frameMagic = 0x42545842;

/// Schema version. Bump on any frame layout change; readers reject mismatch.
///
/// v2 (2026-05-21): `file_start` carries `expr_pool` / `var_name_pool` /
/// `rule_when_pool`; per-row frames (not yet parsed in this PR-A reader)
/// reference pool entries by u16 index instead of inline strings.
const int schemaVersion = 2;

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
  final List<String> outHeaders;

  /// Bintrace v2 symbol pools — emitted once per file_start, referenced by
  /// per-row frames via u16 index. Saves repeating the same expression /
  /// variable name / rule.when text on every row.
  final List<String> exprPool;
  final List<String> varNamePool;
  final List<String> ruleWhenPool;

  const FileStart(super.chunkId, this.inputFormat, this.template, this.path,
      this.headers, this.outHeaders,
      this.exprPool, this.varNamePool, this.ruleWhenPool);
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
  /// Use with `bxp-fmt --row-offset=N` for drill-down.
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

/// Reader over a fully-loaded `Uint8List` byte buffer. Constructor verifies
/// magic + schema version; `nextFrame()` returns one frame at a time until
/// the buffer is exhausted (`null` at EOF).
///
/// Streaming reader (over `Stream<List<int>>` from a Process stdout) lives in
/// `BtraceStreamReader` in a future PR.
class BtraceReader {
  final Uint8List _data;
  final ByteData _bd;
  int _pos = 0;

  BtraceReader._(this._data, this._bd, this._pos);

  /// Validates magic + version, returns a reader positioned past the header.
  factory BtraceReader.fromBytes(Uint8List data) {
    if (data.length < 8) {
      throw FormatException(
          'btrace stream too short: ${data.length} bytes (need ≥ 8 for magic + version)');
    }
    final bd = ByteData.sublistView(data);
    final magic = bd.getUint32(0, Endian.little);
    if (magic != frameMagic) {
      throw FormatException(
          'btrace: bad magic 0x${magic.toRadixString(16).padLeft(8, '0')} '
          '(expected 0x${frameMagic.toRadixString(16).padLeft(8, '0')} = "BXTB")');
    }
    final version = bd.getUint32(4, Endian.little);
    if (version != schemaVersion) {
      throw FormatException(
          'btrace: unsupported schema version $version (this reader handles $schemaVersion)');
    }
    return BtraceReader._(data, bd, 8);
  }

  /// True iff there are more bytes available (not necessarily a full frame).
  bool get hasMore => _pos < _data.length;

  /// Current byte position (after header). Useful for diagnostics.
  int get position => _pos;

  /// Returns next frame, or `null` at EOF. Unknown frame types are silently
  /// skipped via the `pay_len` prefix — forward compatibility lets readers
  /// from older clients tolerate streams that contain frames they don't yet
  /// understand. Throws `FormatException` on truncated header / payload.
  Frame? nextFrame() {
    while (_pos < _data.length) {
      if (_pos + frameHeaderSize > _data.length) {
        throw FormatException(
            'btrace: truncated frame header at offset $_pos '
            '(have ${_data.length - _pos} bytes, need $frameHeaderSize)');
      }
      final typeByte = _data[_pos];
      final chunkId = _bd.getUint16(_pos + 1, Endian.little);
      final payLen = _bd.getUint32(_pos + 3, Endian.little);
      _pos += frameHeaderSize;
      if (_pos + payLen > _data.length) {
        throw FormatException(
            'btrace: truncated payload at offset $_pos '
            '(need $payLen, have ${_data.length - _pos})');
      }
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
    final outCount = _bd.getUint16(_pos, Endian.little);
    _pos += 2;
    final outHeaders = <String>[
      for (int i = 0; i < outCount; i++) _readLp(),
    ];
    final exprPoolCount = _bd.getUint16(_pos, Endian.little);
    _pos += 2;
    final exprPool = <String>[
      for (int i = 0; i < exprPoolCount; i++) _readLp(),
    ];
    final varNamePoolCount = _bd.getUint16(_pos, Endian.little);
    _pos += 2;
    final varNamePool = <String>[
      for (int i = 0; i < varNamePoolCount; i++) _readLp(),
    ];
    final ruleWhenPoolCount = _bd.getUint16(_pos, Endian.little);
    _pos += 2;
    final ruleWhenPool = <String>[
      for (int i = 0; i < ruleWhenPoolCount; i++) _readLp(),
    ];
    return FileStart(chunkId, fmt, template, path, headers, outHeaders,
        exprPool, varNamePool, ruleWhenPool);
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
