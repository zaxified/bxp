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
      // Most platforms exit immediately to let the installer take over;
      // give Linux non-AppImage (release-page launch) a beat then close.
      Navigator.of(context).pop();
      // Best-effort exit so the running .exe / .app can be replaced.
      if (Platform.isWindows || Platform.isMacOS) {
        Future.delayed(const Duration(milliseconds: 500), () => exit(0));
      }
    } else {
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
          onPressed: _installing ? null : _onUpdate,
          child: Text(widget.info.assetUrl == null ? 'Open page' : 'Update'),
        ),
      ],
    );
  }
}
