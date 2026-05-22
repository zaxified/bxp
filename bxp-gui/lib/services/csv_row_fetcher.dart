/// Random-access fetcher for source CSV / output CSVX rows by byte offset.
///
/// Schema v3 (2026-05-22) dropped per-row `row_start_fields` and `row_output`
/// frames from btrace; the GUI drill-down panel reconstructs that data on
/// demand by reading the original CSV files at the byte offsets carried by
/// `output_row` (`source_locator` for input, `output_idx` for output). This
/// service is the Dart-side companion to that read path.
///
/// Holds one `RandomAccessFile` per opened path. Each `lineAt()` call seeks
/// to the requested offset and reads bytes up to the next LF. Reads are
/// served from a small LRU so a re-click on the same row doesn't re-stat
/// the inode.
///
/// Lifecycle: caller MUST `dispose()` when done — open file handles are not
/// owned by the GC. Reopen via `open(path)` on file changes (a save in the
/// GUI's runner re-emits both CSVs, invalidating prior offsets).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Default LRU cache size — covers a single drill-down click (input row +
/// one or more output rows) plus a few re-clicks on the same row before the
/// user moves on. Sized small because lines are typically a few KB each.
const int _defaultCacheCapacity = 64;

class CsvRowFetcher {
  final String _path;
  RandomAccessFile? _raf;
  final int _cacheCapacity;
  // LinkedHashMap doubles as an LRU: re-inserting a key moves it to the end,
  // and we evict from the front when over capacity.
  final LinkedHashMap<int, String> _cache = LinkedHashMap<int, String>();

  CsvRowFetcher._(this._path, this._raf, this._cacheCapacity);

  /// Open [path] for reading. Returns null if the file does not exist.
  /// Caller is responsible for `dispose()`.
  static Future<CsvRowFetcher?> open(
    String path, {
    int cacheCapacity = _defaultCacheCapacity,
  }) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final raf = await file.open(mode: FileMode.read);
    return CsvRowFetcher._(path, raf, cacheCapacity);
  }

  /// Path of the open file. Useful for diagnostics + cache-invalidation
  /// equality checks ("is this fetcher still pointed at the file we just
  /// re-emitted?").
  String get path => _path;

  /// True iff the underlying file has been closed via [dispose]. Subsequent
  /// reads on a disposed fetcher throw `StateError`.
  bool get isDisposed => _raf == null;

  /// Read the line that starts at byte offset [offset] in the file. The
  /// returned string excludes the trailing LF (and CR for CRLF files); it
  /// is decoded as UTF-8 with malformed sequences replaced by U+FFFD.
  ///
  /// Returns null if [offset] is past EOF. Throws `StateError` if the
  /// fetcher has been disposed.
  ///
  /// The read length is bounded by [maxLineBytes] — protects against
  /// pathological inputs without a terminating LF. Lines longer than the
  /// bound are truncated; the GUI tolerates partial rows in drill-down.
  Future<String?> lineAt(int offset, {int maxLineBytes = 1 << 20}) async {
    final raf = _raf;
    if (raf == null) {
      throw StateError('CsvRowFetcher.lineAt called after dispose() on $_path');
    }
    final cached = _cache.remove(offset);
    if (cached != null) {
      // Re-insert to move-to-end (LRU touch).
      _cache[offset] = cached;
      return cached;
    }
    final length = await raf.length();
    if (offset >= length) return null;
    await raf.setPosition(offset);
    // Read in chunks until we hit LF or maxLineBytes; avoids materialising
    // the whole file even for a malformed terminator-free line.
    const chunkSize = 4096;
    final buf = BytesBuilder(copy: false);
    int read = 0;
    while (read < maxLineBytes) {
      final remaining = maxLineBytes - read;
      final wantBytes = remaining < chunkSize ? remaining : chunkSize;
      final chunk = await raf.read(wantBytes);
      if (chunk.isEmpty) break;
      final lfIdx = chunk.indexOf(0x0A); // LF
      if (lfIdx >= 0) {
        // Include bytes up to but not including LF.
        if (lfIdx > 0) buf.add(chunk.sublist(0, lfIdx));
        read += lfIdx;
        break;
      }
      buf.add(chunk);
      read += chunk.length;
    }
    var bytes = buf.toBytes();
    // Strip trailing CR for CRLF inputs.
    if (bytes.isNotEmpty && bytes.last == 0x0D) {
      bytes = bytes.sublist(0, bytes.length - 1);
    }
    final line = utf8.decode(bytes, allowMalformed: true);
    _cache[offset] = line;
    if (_cache.length > _cacheCapacity) {
      // Evict oldest entry. LinkedHashMap preserves insertion order; first
      // key is the LRU candidate.
      _cache.remove(_cache.keys.first);
    }
    return line;
  }

  /// Convenience: read the file's first line (CSV header). Equivalent to
  /// `lineAt(0)` but with a hint in the call site about intent.
  Future<String?> headerLine({int maxLineBytes = 1 << 20}) =>
      lineAt(0, maxLineBytes: maxLineBytes);

  /// Close the underlying file. Safe to call multiple times; subsequent
  /// reads on the disposed fetcher throw.
  Future<void> dispose() async {
    final raf = _raf;
    _raf = null;
    _cache.clear();
    if (raf != null) {
      try {
        await raf.close();
      } catch (_) {
        // Best-effort close — a failure here doesn't usefully propagate
        // to UI code that only cares that the handle is gone.
      }
    }
  }
}
