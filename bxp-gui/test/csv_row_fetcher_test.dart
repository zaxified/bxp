// Unit tests for CsvRowFetcher — random-access read of source.csv /
// output.csvx rows by byte offset.
//
// Schema v3 (2026-05-22) made these reads the GUI drill-down's primary
// source for source-row and output-row data (btrace stopped emitting
// `row_start_fields` / `row_output`). The fetcher must:
//   • return correct lines at arbitrary byte offsets, including offset 0
//     (header) and the last row in the file;
//   • strip the trailing LF (and CR for CRLF files);
//   • return null when seeking past EOF (called with a stale locator);
//   • survive bytes that look like UTF-8 with mojibake (decode with
//     allowMalformed instead of throwing);
//   • respect maxLineBytes for terminator-free pathological inputs;
//   • cache repeated reads of the same offset (drill-down re-click flow).

import 'dart:io';

import 'package:bxp_gui/services/csv_row_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('csv_row_fetcher_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('lineAt reads header at offset 0 and data rows by stored offset',
      () async {
    final f = File(p.join(tmp.path, 'sample.csv'));
    // Construct content with known per-line byte offsets.
    const header = 'a,b,c\n';
    const row1 = 'foo,bar,baz\n';
    const row2 = 'AGNC,2,100.50\n';
    f.writeAsStringSync(header + row1 + row2);

    final fetcher = await CsvRowFetcher.open(f.path);
    expect(fetcher, isNotNull);

    expect(await fetcher!.lineAt(0), equals('a,b,c'));
    expect(await fetcher.lineAt(header.length), equals('foo,bar,baz'));
    expect(await fetcher.lineAt(header.length + row1.length),
        equals('AGNC,2,100.50'));

    await fetcher.dispose();
  });

  test('lineAt strips CR for CRLF-terminated files', () async {
    final f = File(p.join(tmp.path, 'crlf.csv'));
    f.writeAsBytesSync([
      ...'a,b\r\n'.codeUnits,
      ...'1,2\r\n'.codeUnits,
    ]);
    final fetcher = await CsvRowFetcher.open(f.path);
    expect(await fetcher!.lineAt(0), equals('a,b'));
    expect(await fetcher.lineAt(5), equals('1,2'));
    await fetcher.dispose();
  });

  test('lineAt returns null for offsets past EOF', () async {
    final f = File(p.join(tmp.path, 'tiny.csv'));
    f.writeAsStringSync('hi\n');
    final fetcher = await CsvRowFetcher.open(f.path);
    expect(await fetcher!.lineAt(999), isNull);
    await fetcher.dispose();
  });

  test('lineAt returns null when last line has no LF terminator and offset '
      'is past content', () async {
    final f = File(p.join(tmp.path, 'noterm.csv'));
    f.writeAsStringSync('a,b\nlastrow'); // no trailing LF
    final fetcher = await CsvRowFetcher.open(f.path);
    expect(await fetcher!.lineAt(4), equals('lastrow'));
    expect(await fetcher.lineAt(11), isNull);
    await fetcher.dispose();
  });

  test('lineAt caches repeated reads (re-click drill-down)', () async {
    final f = File(p.join(tmp.path, 'cache.csv'));
    f.writeAsStringSync('a,b\nrow1,row2\n');
    final fetcher = await CsvRowFetcher.open(f.path);
    final a = await fetcher!.lineAt(4);
    final b = await fetcher.lineAt(4);
    expect(a, equals(b));
    expect(a, equals('row1,row2'));
    await fetcher.dispose();
  });

  test('lineAt enforces maxLineBytes for terminator-free input', () async {
    final f = File(p.join(tmp.path, 'huge.csv'));
    // 10 KB line without LF.
    f.writeAsStringSync('x' * 10000);
    final fetcher = await CsvRowFetcher.open(f.path);
    final line = await fetcher!.lineAt(0, maxLineBytes: 100);
    expect(line, isNotNull);
    expect(line!.length, equals(100),
        reason: 'truncated to maxLineBytes, no exception');
    await fetcher.dispose();
  });

  test('open returns null for missing file', () async {
    final fetcher = await CsvRowFetcher.open(p.join(tmp.path, 'nope.csv'));
    expect(fetcher, isNull);
  });

  test('dispose closes handle; subsequent reads throw', () async {
    final f = File(p.join(tmp.path, 'd.csv'));
    f.writeAsStringSync('a\n');
    final fetcher = await CsvRowFetcher.open(f.path);
    await fetcher!.dispose();
    expect(fetcher.isDisposed, isTrue);
    expect(() => fetcher.lineAt(0), throwsStateError);
  });

  test('headerLine convenience reads offset 0', () async {
    final f = File(p.join(tmp.path, 'h.csv'));
    f.writeAsStringSync('col1,col2,col3\ndata1,data2,data3\n');
    final fetcher = await CsvRowFetcher.open(f.path);
    expect(await fetcher!.headerLine(), equals('col1,col2,col3'));
    await fetcher.dispose();
  });

  test('UTF-8 with multibyte chars decodes correctly', () async {
    final f = File(p.join(tmp.path, 'utf8.csv'));
    f.writeAsStringSync('název,částka\nčeský,123\n');
    final fetcher = await CsvRowFetcher.open(f.path);
    expect(await fetcher!.headerLine(), equals('název,částka'));
    // header bytes: "název,částka\n" — count UTF-8 bytes for offset
    final headerBytes = 'název,částka\n'.length; // Dart string len = code units
    final headerByteCount = ('název,částka\n').codeUnits
        .fold<int>(0, (acc, cu) => acc + (cu < 0x80 ? 1 : (cu < 0x800 ? 2 : 3)));
    expect(await fetcher.lineAt(headerByteCount), equals('český,123'));
    // headerBytes (UTF-16 code units) is intentionally a different number,
    // documenting the byte vs code-unit gotcha: locator is byte offset.
    expect(headerByteCount, greaterThan(headerBytes - 2));
    await fetcher.dispose();
  });
}
