// Smoke test for Json5Emitter: read annotated JSON from bxp-fmt, emit it
// back as JSON5, re-validate the emitted text through bxp-fmt, report the
// diff-looking stats. Run from project root:
//   dart run tool/roundtrip_test.dart /path/to/bxp-cli.json

import 'dart:convert';
import 'dart:io';
import 'package:bxp_gui/services/json5_emitter.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/roundtrip_test.dart <config.json>');
    exit(2);
  }
  final configPath = args[0];
  final fmtBin = '${Directory.current.path}/../bxp-fmt/zig-out/bin/bxp-fmt';

  // Step 1 — annotate through bxp-fmt.
  final r1 = await Process.run(fmtBin, ['--config', configPath]);
  if (r1.exitCode != 0) {
    stderr.writeln('bxp-fmt --config failed:\n${r1.stderr}');
    exit(1);
  }
  final annotated = jsonDecode(r1.stdout as String);

  // Step 2 — emit JSON5.
  final text = Json5Emitter.emit(annotated);
  print('--- emitted (${text.length} bytes, first 800) ---');
  print(text.substring(0, text.length < 800 ? text.length : 800));
  print('--- …');

  // Step 3 — round-trip: save and re-validate.
  final tmpDir = await Directory.systemTemp.createTemp('bxp-roundtrip');
  try {
    final tmpPath = '${tmpDir.path}/roundtrip.json5';
    await File(tmpPath).writeAsString(text);

    final r2 = await Process.run(fmtBin, ['--config', tmpPath]);
    if (r2.exitCode != 0) {
      stderr.writeln('\nround-trip failed: bxp-fmt rejected the emitted '
          'text. stderr:\n${r2.stderr}');
      stderr.writeln('\nfull emitted text:\n$text');
      exit(1);
    }

    final r2Annotated = jsonDecode(r2.stdout as String);
    final origKeys = _countKeys(annotated);
    final rtKeys = _countKeys(r2Annotated);
    final origComments = _countAnnot(annotated, r'$comm_');
    final rtComments = _countAnnot(r2Annotated, r'$comm_');

    print('\nroundtrip OK');
    print('  real-key count:  orig=$origKeys  rt=$rtKeys');
    print('  comment count:   orig=$origComments  rt=$rtComments');
    if (origKeys != rtKeys) {
      stderr.writeln('WARN: key counts differ');
      exit(1);
    }
    if (origComments != rtComments) {
      stderr.writeln('WARN: comment counts differ — some were lost');
      exit(1);
    }
  } finally {
    await tmpDir.delete(recursive: true);
  }
}

int _countKeys(dynamic node) {
  if (node is Map) {
    int n = 0;
    for (final e in node.entries) {
      final k = e.key.toString();
      if (k.startsWith(r'$comm_') || k.startsWith(r'$err_')) continue;
      n += 1 + _countKeys(e.value);
    }
    return n;
  }
  if (node is List) return node.fold(0, (a, v) => a + _countKeys(v));
  return 0;
}

int _countAnnot(dynamic node, String prefix) {
  if (node is Map) {
    int n = 0;
    for (final e in node.entries) {
      final k = e.key.toString();
      if (k.startsWith(prefix)) n++;
      n += _countAnnot(e.value, prefix);
    }
    return n;
  }
  if (node is List) return node.fold(0, (a, v) => a + _countAnnot(v, prefix));
  return 0;
}
