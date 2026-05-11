import 'package:flutter/material.dart';
import '../../services/desktop_integration_service.dart';
import '../../services/prefs_service.dart';

/// First-run dialog asking the user whether to register `bxp-gui.desktop`
/// + hicolor icons under `~/.local/share/`. Whatever the user picks,
/// `bxp-gui.json` is created on accept so the dialog only fires once
/// per fresh install — re-trigger by deleting the prefs file.
class IntegrateDialog extends StatefulWidget {
  final DesktopIntegrationService integration;
  final PrefsService prefs;

  const IntegrateDialog({
    super.key,
    required this.integration,
    required this.prefs,
  });

  @override
  State<IntegrateDialog> createState() => _IntegrateDialogState();
}

class _IntegrateDialogState extends State<IntegrateDialog> {
  bool _busy = false;

  Future<void> _onIntegrate() async {
    setState(() => _busy = true);
    await widget.integration.integrate();
    await widget.prefs.ensureExists();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Desktop integration installed.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _onSkip() async {
    setState(() => _busy = true);
    await widget.prefs.ensureExists();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final paths = widget.integration.describePaths();
    final theme = Theme.of(context);
    final monoStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
    );
    return AlertDialog(
      title: const Text('Install desktop integration?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 460),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'BXP can register itself with your desktop environment so it '
                'shows up in the application menu and file managers. The '
                'integration is user-local (no sudo needed) and reversible '
                'from the Settings drawer.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Files that will be created when you click Install:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              SelectableText('• ${paths.desktopFile}', style: monoStyle),
              const SizedBox(height: 2),
              SelectableText(
                '• ${paths.iconFiles.first}\n'
                '  …  (8 icon sizes total: 16, 32, 48, 64, 128, 256, 512, 1024)',
                style: monoStyle,
              ),
              const SizedBox(height: 12),
              const Text(
                'Your settings file is created either way (so this dialog '
                'only appears once on a fresh install):',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              SelectableText('• ${paths.prefsFile}', style: monoStyle),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _onSkip,
          child: const Text('No, skip integration'),
        ),
        FilledButton(
          onPressed: _busy ? null : _onIntegrate,
          child: const Text('Yes, integrate now'),
        ),
      ],
    );
  }
}
