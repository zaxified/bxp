import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/bxp_process_client.dart';
import '../../services/doc_links.dart';
import '../../store/trace_store.dart';

/// The desktop archive's rendezvous with the documentation.
///
/// The console archive gets this from `bxp-cli --help`; a user who launches
/// the app from a menu entry never sees a terminal, so the same three things
/// live here: the manual for a person, the release-pinned Markdown sources for
/// an assistant, and how to reach the bundled `bxp-mcp`.
///
/// The MCP section is the part only the GUI can serve. `bxp-mcp` ships beside
/// every binary, but inside an AppImage that is a fresh `/tmp/.mount_*` on
/// every launch, so a path printed anywhere else would be stale by the next
/// start — this dialog resolves it live, through the same lookup the app uses
/// to find its own engine.
class BxpAboutDialog extends StatefulWidget {
  const BxpAboutDialog({super.key});

  @override
  State<BxpAboutDialog> createState() => _BxpAboutDialogState();
}

class _BxpAboutDialogState extends State<BxpAboutDialog> {
  @override
  void initState() {
    super.initState();
    // Versions are probed lazily elsewhere (the settings inspector triggers
    // the same call), so the dialog can open before anything has asked.
    // notifyListeners on completion repaints us through the watch below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TraceStore>().ensureVersionsProbed();
    });
  }

  /// The `mcpServers` entry an agent host needs, ready to paste. Built with a
  /// real encoder so a Windows path's backslashes are escaped rather than
  /// pasted into a broken JSON file.
  String _mcpSnippet(String path) => const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          'bxp': {'command': path, 'args': <String>[]},
        },
      });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final bold = const TextStyle(fontWeight: FontWeight.w600);

    final mcpPath = BxpProcessClient.findBin('bxp-mcp');
    final sourceUrl = docsSourceUrl(store.bxpGuiVersion);

    return AlertDialog(
      title: const Text('About BXP'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _version('bxp-gui', store.bxpGuiVersion, mono),
              _version('bxp-cli', store.bxpCliVersion, mono),
              _version('bxp-mcp', store.bxpMcpVersion, mono),
              const SizedBox(height: 16),
              Text('Documentation', style: bold),
              const SizedBox(height: 6),
              _link(
                context,
                kDocsSiteUrl,
                'Searchable manual — for a human reader.',
                mono,
              ),
              const SizedBox(height: 8),
              _link(
                context,
                sourceUrl,
                store.bxpGuiVersion == null
                    ? 'The same manual as Markdown — for AI authoring. '
                        'Unpinned: this build reports no version.'
                    : 'The same manual as Markdown, pinned to this release — '
                        'for AI authoring.',
                mono,
              ),
              const SizedBox(height: 16),
              Text('Agent access (bxp-mcp)', style: bold),
              const SizedBox(height: 6),
              if (mcpPath == null)
                const Text(
                  'The bundled MCP server was not found next to the app. A '
                  'complete install ships it alongside bxp-cli.',
                )
              else ...[
                const Text(
                  'Register this with your agent host to let it validate '
                  'configs, evaluate expressions and dry-run a conversion:',
                ),
                const SizedBox(height: 6),
                SelectableText(_mcpSnippet(mcpPath), style: mono),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: _mcpSnippet(mcpPath)));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('MCP server entry copied.'),
                          duration: Duration(seconds: 3),
                        ),
                      );
                    },
                    child: const Text('Copy'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _version(String name, String? value, TextStyle? mono) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: SelectableText('$name  ${value ?? '(unknown)'}', style: mono),
      );

  /// A URL row: the link itself, then what it is for. The URL is selectable so
  /// a user on a host without a working opener can still copy it out.
  Widget _link(
    BuildContext context,
    String url,
    String description,
    TextStyle? mono,
  ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => openExternalUrl(url),
            child: Text(
              url,
              style: mono?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 2),
            child: Text(description),
          ),
        ],
      );
}
