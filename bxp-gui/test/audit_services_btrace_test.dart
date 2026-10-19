// Audit regressions for lib/services/btrace.dart: malformed payloads must
// surface as FormatException (the only type the ingest loop catches), the
// stream must stay aligned after a bad frame, and the streaming buffer must
// not keep (or re-copy) consumed bytes.

import 'dart:convert';
import 'dart:typed_data';

import 'package:bxp_gui/services/btrace.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
List<int> _u16(int v) => (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
List<int> _lp(List<int> b) => [..._u32(b.length), ...b];

List<int> _frame(int type, List<int> payload) =>
    [type, ..._u16(0), ..._u32(payload.length), ...payload];

List<int> _done(int code) => _frame(0x07, (ByteData(4)..setInt32(0, code, Endian.little)).buffer.asUint8List());

void main() {
  final magic = _u32(frameMagic);

  test('filtered_row whose string length overruns the payload -> FormatException, stream stays aligned', () {
    // payload: u64 locator + lp(len=1000, but only 2 bytes present) — the
    // declared pay_len covers just those bytes, followed by a good done frame.
    final bad = _frame(0x04, [...List.filled(8, 0), ..._u32(1000), 0x61, 0x62]);
    final r = BtraceReader.streaming()..appendBytes([...magic, ...bad, ..._done(7)]);
    expect(() => r.nextFrame(), throwsA(isA<FormatException>()));
    final next = r.nextFrame();
    expect(next, isA<Done>());
    expect((next as Done).exitCode, 7);
  });

  test('fields reading past pay_len into the next frame are rejected, not mis-parsed', () {
    // file_end needs 24 payload bytes; declare only 4.
    final bad = _frame(0x02, [1, 2, 3, 4]);
    final r = BtraceReader.streaming()..appendBytes([...magic, ...bad, ..._done(0), ..._done(0)]);
    expect(() => r.nextFrame(), throwsA(isA<FormatException>()));
    expect(r.nextFrame(), isA<Done>());
  });

  test('invalid UTF-8 in a string field does not drop the frame', () {
    final payload = [...List.filled(8, 0), ..._lp([0x66, 0xFF, 0x6F])];
    final r = BtraceReader.streaming()..appendBytes([...magic, ..._frame(0x04, payload)]);
    final f = r.nextFrame() as FilteredRow;
    expect(f.reason.length, 3);
    expect(f.reason.codeUnitAt(1), 0xFFFD);
  });

  test('byte-by-byte streaming parses every frame; position stays absolute', () {
    final frames = <int>[];
    for (var i = 0; i < 200; i++) {
      frames.addAll(_done(i));
    }
    final all = [...magic, ...frames];
    final r = BtraceReader.streaming();
    final codes = <int>[];
    for (final b in all) {
      r.appendBytes([b]);
      Frame? f;
      while ((f = r.nextFrame()) != null) {
        codes.add((f as Done).exitCode);
      }
    }
    expect(codes, List.generate(200, (i) => i));
    expect(r.position, all.length);
  });

  test('utf8 roundtrip still strict-equal for valid text', () {
    final s = 'příliš žluťoučký';
    final payload = [...List.filled(8, 0), ..._lp(utf8.encode(s))];
    final r = BtraceReader.fromBytes(Uint8List.fromList([...magic, ..._frame(0x04, payload)]));
    expect((r.nextFrame() as FilteredRow).reason, s);
  });
}
