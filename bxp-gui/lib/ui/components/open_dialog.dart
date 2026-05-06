import 'dart:io';
import 'package:flutter/material.dart';
// ignore: unnecessary_import
import 'package:flutter/services.dart'; // LogicalKeyboardKey for SingleActivator
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';

class OpenDialog extends StatefulWidget {
  final ValueChanged<String> onOpen;

  const OpenDialog({super.key, required this.onOpen});

  static Future<void> show(BuildContext context, ValueChanged<String> onOpen) {
    return showDialog(
      context: context,
      barrierColor: context.bxpThemeRead.dialogBarrier,
      builder: (_) => OpenDialog(onOpen: onOpen),
    );
  }

  @override
  State<OpenDialog> createState() => _OpenDialogState();
}

class _OpenDialogState extends State<OpenDialog> {
  String currentPath = '/';
  List<FileSystemEntity> entries = [];
  bool loading = false;
  String? loadError;

  @override
  void initState() {
    super.initState();
    // Pick a sensible starting directory, in priority order:
    //   1. parent of the currently loaded config
    //   2. parent of the most-recent file in MRU
    //   3. user $HOME
    //   4. filesystem root (last resort)
    // Mirrors bxp-ui's startPath logic in OpenDialog.tsx.
    final store = context.read<TraceStore>();
    if (store.configPath.isNotEmpty) {
      final f = File(store.configPath);
      if (f.existsSync()) {
        currentPath = f.parent.path;
      }
    } else if (store.recentFiles.isNotEmpty) {
      final f = File(store.recentFiles.first);
      currentPath = f.parent.path;
    } else {
      currentPath =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/';
    }
    _navigate(currentPath);
  }

  Future<void> _navigate(String path) async {
    setState(() {
      loading = true;
      loadError = null;
    });

    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        setState(() {
          loadError = 'Directory does not exist';
          loading = false;
        });
        return;
      }

      final list = await dir.list().toList();
      // Sort directories first, then files, both alphabetically
      list.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir && !bIsDir) return -1;
        if (!aIsDir && bIsDir) return 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });

      setState(() {
        currentPath = dir.path;
        entries = list;
        loading = false;
      });
    } catch (e) {
      setState(() {
        loadError = e.toString();
        loading = false;
      });
    }
  }

  void _goUp() {
    final parent = Directory(currentPath).parent.path;
    if (parent != currentPath) {
      _navigate(parent);
    }
  }

  String _basename(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i >= 0 ? path.substring(i + 1) : path;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<TraceStore>();
    final t = context.bxpTheme;
    final bgColor = t.dialogBg;
    final borderColor = t.borderColor;

    final parts = currentPath.split(Platform.pathSeparator).where((p) => p.isNotEmpty).toList();

    // Escape closes the modal — mirrors bxp-ui's window-level keydown
    // handler in OpenDialog.tsx. Wrap in Focus(autofocus) so the
    // shortcut binding receives keys without requiring the user to
    // first click into the dialog.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 580,
          height: 460,
          decoration: BoxDecoration(
            color: bgColor,
            border: Border.all(color: borderColor),
            boxShadow: [BoxShadow(color: t.dialogShadow, blurRadius: 20)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title Bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: borderColor))),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('OPEN CONFIG', style: BxpText.title(context)),
                    InkWell(
                      onTap: () => Navigator.of(context).pop(),
                      child: Text('✕',
                          style: TextStyle(color: t.textMuted, fontSize: 12)),
                    ),
                  ],
                ),
              ),

              // Breadcrumbs
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: borderColor))),
                child: Row(
                  children: [
                    IconButton(
                      icon: Text('↑',
                          style: TextStyle(color: t.textPrimary, fontSize: 16)),
                      onPressed: _goUp,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            Text('/',
                                style: BxpText.body(context,color: t.textMuted, size: BxpSize.md)),
                            ...parts.asMap().entries.map((e) {
                              final path = '/${parts.sublist(0, e.key + 1).join('/')}';
                              return Row(
                                children: [
                                  InkWell(
                                    onTap: () => _navigate(path),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4.0),
                                      child: Text(e.value,
                                          style: BxpText.body(context,
                                              color: t.textPrimary, size: BxpSize.md)),
                                    ),
                                  ),
                                  if (e.key < parts.length - 1)
                                    Text('/',
                                        style: BxpText.body(context,
                                            color: t.textMuted, size: BxpSize.md)),
                                ],
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // File List
              Expanded(
                child: loading
                  ? Center(child: Text('Loading...',
                      style: BxpText.italic(context)))
                  : loadError != null
                    ? Center(child: Text(loadError!,
                        style: BxpText.body(context, color: t.errorText)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          final isDir = entry is Directory;
                          final name = _basename(entry.path);

                          return InkWell(
                            onTap: () {
                              if (isDir) {
                                _navigate(entry.path);
                              } else {
                                widget.onOpen(entry.path);
                                Navigator.of(context).pop();
                              }
                            },
                            hoverColor: t.hoverOverlay,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                              child: Row(
                                children: [
                                  Text(isDir ? '📁' : '📄', style: const TextStyle(fontSize: 14)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: BxpText.body(context,
                                          color: isDir
                                              ? t.codeColumn
                                              : t.textPrimary,
                                          size: BxpSize.md),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),

              if (context.watch<TraceStore>().recentFiles.isNotEmpty)
                Container(
                  decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: borderColor))),
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                        child: Text('RECENT', style: BxpText.label(context)),
                      ),
                      Flexible(
                        child: ListView(
                          padding: const EdgeInsets.only(bottom: 6),
                          shrinkWrap: true,
                          children: [
                            for (final p in context.read<TraceStore>().recentFiles)
                              InkWell(
                                onTap: () {
                                  widget.onOpen(p);
                                  Navigator.of(context).pop();
                                },
                                hoverColor: t.hoverOverlay,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 3),
                                  child: Text(p,
                                      style: BxpText.body(context,
                                          color: t.textMuted, size: BxpSize.sm),
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
        ),
      ),
    );
  }
}
