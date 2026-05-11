import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/updater_service.dart';

// Dialog shown when UpdaterService surfaces a new version. Mounted as an
// overlay listener at the top of the widget tree (see UpdaterListener in
// main.dart) so it surfaces regardless of the active route.
class UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const UpdateDialog({super.key, required this.info});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _installing = false;

  Future<void> _onUpdate() async {
    setState(() => _installing = true);
    final svc = context.read<UpdaterService>();
    final ok = await svc.downloadAndInstall();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      // Best-effort exit so the running .exe / .app can be replaced. The
      // delay gives the Navigator.pop frame time to paint before we kill
      // the process; without it some window managers flash the old window.
      if (Platform.isWindows || Platform.isMacOS) {
        Future.delayed(const Duration(milliseconds: 500), () => exit(0));
      }
    } else {
      // Reset so the user can retry — downloadAndInstall already set
      // UpdaterService.lastError with a user-visible message.
      setState(() => _installing = false);
    }
  }

  void _onLater() {
    context.read<UpdaterService>().dismiss();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<UpdaterService>();
    final progress = svc.downloadProgress;
    final err = svc.lastError;
    return AlertDialog(
      title: Text('Update v${widget.info.version} available'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 380),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.info.body.isNotEmpty) ...[
                const Text(
                  'Release notes',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                SelectableText(widget.info.body),
                const SizedBox(height: 12),
              ],
              if (_installing && progress != null) ...[
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 6),
                Text('Downloading… ${(progress * 100).toStringAsFixed(0)}%'),
              ],
              if (_installing && progress == null) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 6),
                const Text('Installing — the app will restart.'),
              ],
              if (widget.info.assetUrl == null) ...[
                const SizedBox(height: 8),
                const Text(
                  'No installer for this platform — please update '
                  'manually from the release page:',
                ),
                const SizedBox(height: 4),
                SelectableText(widget.info.htmlUrl),
              ],
              if (err != null) ...[
                const SizedBox(height: 8),
                Text(err, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _installing ? null : _onLater,
          child: const Text('Later'),
        ),
        FilledButton(
          // Disabled when no native installer is available for this
          // platform — the user must follow the release-page link shown
          // in the dialog body.
          onPressed: (_installing || widget.info.assetUrl == null)
              ? null
              : _onUpdate,
          child: const Text('Update'),
        ),
      ],
    );
  }
}
