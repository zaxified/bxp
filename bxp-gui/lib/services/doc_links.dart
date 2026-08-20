/// The documentation destinations the app offers, and the platform call that
/// opens one in the user's browser.
///
/// Mirrors the block `bxp-cli --help` prints, and for the same reason: the
/// archives ship no readme, so the product itself has to hand both audiences
/// the real manual. The two URLs are different surfaces of one source — the
/// rendered site for a person (search, navigation, the clickable expression
/// playground), the Markdown sources for an assistant, pinned to the release
/// so an agent reads the schema the installed binaries actually implement.
library;

import 'dart:io';

import 'dev_trace.dart';

/// The published manual. Unversioned — it always renders the current master.
const String kDocsSiteUrl = 'https://zaxified.github.io/bxp/';

/// The same manual as Markdown, pinned to [version] (the tag the release was
/// cut from). Falls back to `master` when the version could not be probed,
/// which is the honest answer: an unpinned link is still better than none, and
/// the caller says which one it is showing.
String docsSourceUrl(String? version) {
  final ref = (version == null || version.isEmpty) ? 'master' : 'v$version';
  return 'https://github.com/zaxified/bxp/tree/$ref/docs/';
}

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
