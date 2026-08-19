import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bxp_gui/services/app_runtime.dart';

/// The updater's macOS branch gates on the host architecture, because the
/// release workflow ships an arm64 DMG only and the asset NAME matches on any
/// macOS host — an Intel Mac used to install a build it could not launch.
/// `dart:io` exposes no architecture, so the answer is parsed out of
/// [Platform.version]; these pin that parse against the real strings and the
/// malformed ones.
void main() {
  group('architectureFromVersion', () {
    test('reads the ABI tag of each supported host', () {
      const cases = {
        '3.13.0 (stable) (Wed Aug 5 00:28:05 2026 -0700) on "macos_arm64"':
            'arm64',
        '3.13.0 (stable) (Wed Aug 5 00:28:05 2026 -0700) on "macos_x64"': 'x64',
        '3.13.0 (stable) (Wed Aug 5 00:28:05 2026 -0700) on "linux_x64"': 'x64',
        '3.13.0 (stable) (Wed Aug 5 00:28:05 2026 -0700) on "windows_x64"':
            'x64',
        '3.13.0 (stable) (Wed Aug 5 00:28:05 2026 -0700) on "linux_riscv64"':
            'riscv64',
      };
      cases.forEach((version, want) {
        expect(architectureFromVersion(version), want, reason: version);
      });
    });

    test('returns null rather than guessing on an unexpected shape', () {
      for (final bad in const [
        '',
        '3.13.0 (stable)',
        '3.13.0 on "noseparator"',
        '3.13.0 on "trailing_"',
        '3.13.0 on macos_arm64',
      ]) {
        expect(architectureFromVersion(bad), isNull, reason: '"$bad"');
      }
    });

    test('agrees with the running VM', () {
      // Whatever host runs the suite, the parse must produce a non-empty tag
      // from the real string — the guard against a future Platform.version
      // format change silently turning every macOS host into "not arm64".
      final arch = hostArchitecture();
      expect(arch, isNotNull, reason: Platform.version);
      expect(arch, isNotEmpty);
    });
  });
}
