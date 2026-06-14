// Unit test for UpdaterService.checksumOutcome — the pure installer-vs-
// SHA256SUMS integrity check the updater runs after the signature is
// verified. Covers the three outcomes (ok / assetNotListed / mismatch);
// the IO-error path (couldn't read the installer) is handled in
// downloadAndInstall, not in this pure function.

import 'dart:convert';
import 'dart:typed_data';

import 'package:bxp_gui/services/updater_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const asset = 'bxp-desktop-linux-x86_64.AppImage';
  final bytes = Uint8List.fromList(utf8.encode('pretend installer contents'));
  final hash = sha256.convert(bytes).toString();

  test('ok when the asset line hash matches', () {
    final sums = '$hash  $asset\n'
        '0000000000000000000000000000000000000000000000000000000000000000  other\n';
    expect(
      UpdaterService.checksumOutcome(sums, asset, bytes),
      ChecksumOutcome.ok,
    );
  });

  test('assetNotListed when the asset has no line', () {
    final sums = '$hash  some-other-file\n';
    expect(
      UpdaterService.checksumOutcome(sums, asset, bytes),
      ChecksumOutcome.assetNotListed,
    );
  });

  test('mismatch when the listed hash differs', () {
    const wrong =
        '1111111111111111111111111111111111111111111111111111111111111111';
    final sums = '$wrong  $asset\n';
    expect(
      UpdaterService.checksumOutcome(sums, asset, bytes),
      ChecksumOutcome.mismatch,
    );
  });

  test('handles single-space and uppercase-hex SUMS variants', () {
    final sums = '${hash.toUpperCase()} $asset\n'; // one space, uppercase
    expect(
      UpdaterService.checksumOutcome(sums, asset, bytes),
      ChecksumOutcome.ok,
    );
  });
}
