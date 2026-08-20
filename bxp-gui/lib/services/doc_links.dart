/// The documentation destinations the app offers, and the platform call that
/// opens one in the user's browser.
///
/// The archives ship no readme, so the product itself has to hand the user the
/// manual. `bxp-cli --help` prints the same destination for console users; an
/// agent gets the release-pinned Markdown sources from there too, which is why
/// only the human-facing site URL is needed here.
library;

import 'dart:io';

import 'dev_trace.dart';

/// The published manual. Unversioned — it always renders the current master.
const String kDocsSiteUrl = 'https://zaxified.github.io/bxp/';

/// Open [url] in the platform browser.
///
/// Failures are surfaced via devTrace: a fire-and-forget `Process.run`
/// swallows the missing-binary case (no `xdg-open` on minimal Linux installs,
/// no `open` if the macOS user removed it), and without this a click that does
/// nothing looks like a UI bug.
Future<void> openExternalUrl(String url) async {
  final (cmd, args) = switch (Platform.operatingSystem) {
    'linux' => ('xdg-open', [url]),
    'macos' => ('open', [url]),
    'windows' => ('cmd', ['/c', 'start', url]),
    _ => (null, <String>[]),
  };
  if (cmd == null) {
    devTrace('openExternalUrl.unsupported',
        {'platform': Platform.operatingSystem});
    return;
  }
  try {
    final result = await Process.run(cmd, args);
    if (result.exitCode != 0) {
      devTrace('openExternalUrl.fail', {
        'cmd': cmd,
        'url': url,
        'exitCode': result.exitCode,
        'stderr': result.stderr.toString(),
      });
    }
  } catch (e) {
    devTrace('openExternalUrl.spawnFail',
        {'cmd': cmd, 'url': url, 'error': e.toString()});
  }
}
