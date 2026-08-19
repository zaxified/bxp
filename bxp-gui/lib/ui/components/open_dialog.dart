import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../services/bxp_process_client.dart';
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

/// HOME is the standard on Linux/macOS; USERPROFILE is its Windows equivalent.
/// Falls back to CWD (always available) when neither is set — that keeps the
/// dialog functional in restricted environments without crashing.
String _userHome() =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    Directory.current.path;

/// Enumerate present drive letters on Windows by probing A–Z.
///
/// `Directory.existsSync` returns `false` for unmapped letters but
/// THROWS `FileSystemException` (errno 21, "device not ready") for
/// mapped-but-empty volumes — typical CD-ROM drives, optical media
/// readers, and offline network drives. Letting that exception
/// propagate through `_QuickSidebar.build` would cause the
/// OpenDialog tree to rebuild repeatedly trying to render an error
/// widget; on Windows, that build storm has been observed to
/// stress the D3D11 device into a TDR cascade
/// (`DXGI_ERROR_DEVICE_REMOVED` → `EGL Context Lost` infinite
/// recovery loop), wedging the app entirely. Treat any exception as
/// "drive not present" so the sidebar lists only mounted, ready
/// volumes.
List<String> _windowsDrives() {
  final drives = <String>[];
  for (var c = 65; c <= 90; c++) {
    final path = '${String.fromCharCode(c)}:\\';
    try {
      if (Directory(path).existsSync()) drives.add(path);
    } catch (_) {
      // Drive letter is mapped but the volume is offline / has no
      // media — skip it.
    }
  }
  return drives;
}

// Matches anything with "json" in the extension chain — `.json`, `.json5`,
// `.jsonl`, `.jsonc`, `.json.bak`, etc. Case-insensitive.
bool _isConfigFile(String path) {
  final name = p.basename(path).toLowerCase();
  final dot = name.indexOf('.');
  if (dot < 0) return false;
  return name.substring(dot).contains('json');
}

class _OpenDialogState extends State<OpenDialog> {
  String currentPath = '';
  List<FileSystemEntity> entries = [];
  List<FileSystemEntity> visible = [];
  bool loading = false;
  String? loadError;
  String searchQuery = '';
  int selectedIndex = 0;
  bool showAllFiles = false;

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  // Root focus owns the dialog's keyboard handler. Sidebar/breadcrumb
  // taps (GestureDetector) don't grab focus on their own; the search
  // TextField does. After every navigation we hand focus back to root
  // unless the search field has it, so type-ahead keeps working.
  final FocusNode _rootFocus = FocusNode(debugLabel: 'OpenDialogRoot');
  final ScrollController _listCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    final store = context.read<TraceStore>();
    // Prioritise the folder containing the already-open config — the user
    // most likely wants a sibling or nearby file. Fall back to the most
    // recently opened config's directory, then to HOME.
    String start;
    if (store.configPath.isNotEmpty &&
        File(store.configPath).existsSync()) {
      start = p.dirname(store.configPath);
    } else if (store.recentFiles.isNotEmpty) {
      start = p.dirname(store.recentFiles.first);
    } else {
      start = _userHome();
    }
    _navigate(start);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _rootFocus.dispose();
    _listCtrl.dispose();
    super.dispose();
  }

  /// Return keyboard focus to the root handler after a sidebar / breadcrumb
  /// click so arrow-key navigation and type-ahead continue to work. Skip when
  /// the search TextField already has focus — it owns the keyboard for typing.
  void _refocusRootIfSearchInactive() {
    if (!_searchFocus.hasFocus) _rootFocus.requestFocus();
  }

  Future<void> _navigate(String path) async {
    setState(() {
      loading = true;
      loadError = null;
    });

    try {
      final dir = Directory(path);
      final exists = await dir.exists();
      if (!mounted) return;
      if (!exists) {
        setState(() {
          loadError = 'Directory does not exist';
          loading = false;
        });
        return;
      }

      final list = await dir.list().toList();
      if (!mounted) return;
      // Only the always-on filter (hidden entries) is applied here — the
      // file-extension filter lives in _recomputeVisible so toggling
      // showAllFiles doesn't require re-listing the directory.
      final filtered = list.where((e) {
        final name = p.basename(e.path);
        return !name.startsWith('.');
      }).toList();
      // Directories first, then files; alphabetical within each group.
      filtered.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir && !bIsDir) return -1;
        if (!aIsDir && bIsDir) return 1;
        return p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
      });

      setState(() {
        currentPath = dir.path;
        entries = filtered;
        searchQuery = '';
        _searchCtrl.clear();
        selectedIndex = 0;
        loading = false;
        _recomputeVisible();
      });
      _refocusRootIfSearchInactive();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loadError = e.toString();
        loading = false;
      });
    }
  }

  void _recomputeVisible() {
    final q = searchQuery.trim().toLowerCase();
    visible = entries.where((e) {
      // Directories always pass the file-type filter.
      if (e is! Directory && !showAllFiles && !_isConfigFile(e.path)) {
        return false;
      }
      if (q.isEmpty) return true;
      return p.basename(e.path).toLowerCase().contains(q);
    }).toList();
    if (selectedIndex >= visible.length) {
      selectedIndex = visible.isEmpty ? 0 : visible.length - 1;
    }
  }

  void _toggleShowAllFiles() {
    setState(() {
      showAllFiles = !showAllFiles;
      selectedIndex = 0;
      _recomputeVisible();
    });
  }

  void _onSearchChanged(String v) {
    setState(() {
      searchQuery = v;
      selectedIndex = 0;
      _recomputeVisible();
    });
  }

  void _goUp() {
    final parent = p.dirname(currentPath);
    if (!p.equals(parent, currentPath)) {
      _navigate(parent);
    }
  }

  /// Copy the bundled `bxp-cli.examples.json` into the folder currently in
  /// view (verbatim name; unique-suffixed on collision). Lets a GUI-only
  /// install grab the starter templates without the console archive. Re-
  /// lists so the new file shows up, and reports the outcome via snackbar.
  Future<void> _createExamplesHere() async {
    final messenger = ScaffoldMessenger.of(context);
    String? created;
    try {
      created = BxpProcessClient.copyExamplesInto(currentPath);
    } catch (_) {
      created = null;
    }
    if (!mounted) return;
    final createdPath = created;
    if (createdPath == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Example templates are not bundled with this build.'),
      ));
    } else {
      await _navigate(currentPath); // refresh so the new file appears
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Created ${p.basename(createdPath)}'),
      ));
    }
    _refocusRootIfSearchInactive();
  }

  void _activateSelected() {
    if (visible.isEmpty) return;
    final entry = visible[selectedIndex];
    if (entry is Directory) {
      _navigate(entry.path);
    } else {
      widget.onOpen(entry.path);
      Navigator.of(context).pop();
    }
  }

  void _moveSelection(int delta) {
    if (visible.isEmpty) return;
    final next = (selectedIndex + delta).clamp(0, visible.length - 1);
    if (next == selectedIndex) return;
    setState(() => selectedIndex = next);
    _scrollSelectedIntoView();
  }

  void _jumpSelection(int target) {
    if (visible.isEmpty) return;
    final next = target.clamp(0, visible.length - 1);
    setState(() => selectedIndex = next);
    _scrollSelectedIntoView();
  }

  void _scrollSelectedIntoView() {
    if (!_listCtrl.hasClients) return;
    const rowHeight = 30.0;
    final viewport = _listCtrl.position.viewportDimension;
    final offset = selectedIndex * rowHeight;
    final cur = _listCtrl.offset;
    if (offset < cur) {
      _listCtrl.jumpTo(offset);
    } else if (offset + rowHeight > cur + viewport) {
      _listCtrl.jumpTo(offset + rowHeight - viewport);
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent ev) {
    if (ev is! KeyDownEvent && ev is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = ev.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageDown) {
      _moveSelection(10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageUp) {
      _moveSelection(-10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.home) {
      _jumpSelection(0);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.end) {
      _jumpSelection(visible.length - 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      _activateSelected();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace && _searchCtrl.text.isEmpty) {
      _goUp();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    // Type-ahead: when the search field isn't focused and the user types
    // a printable character (no Ctrl/Meta), forward it to the search
    // input and grab focus so further keystrokes go straight there.
    if (!_searchFocus.hasFocus) {
      final ch = ev.character;
      final modifiers = HardwareKeyboard.instance;
      final hasModifier = modifiers.isControlPressed ||
          modifiers.isMetaPressed ||
          modifiers.isAltPressed;
      if (ch != null &&
          ch.isNotEmpty &&
          !hasModifier &&
          ch.codeUnitAt(0) >= 0x20) {
        // Hand focus to the TextField first; then write the char and
        // collapse the selection at the end. If we set the value before
        // focusing, the TextField re-establishes a full selection on
        // first focus, so the next keystroke would replace the char.
        // Re-asserting selection in a post-frame callback is the
        // belt-and-braces fix for that race.
        _searchFocus.requestFocus();
        final newText = _searchCtrl.text + ch;
        _searchCtrl.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: newText.length),
        );
        _onSearchChanged(newText);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_searchCtrl.selection.baseOffset !=
                  _searchCtrl.text.length ||
              _searchCtrl.selection.extentOffset !=
                  _searchCtrl.text.length) {
            _searchCtrl.selection = TextSelection.collapsed(
                offset: _searchCtrl.text.length);
          }
        });
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<TraceStore>();
    final t = context.bxpTheme;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Container(
            width: 820,
            height: 500,
            decoration: BoxDecoration(
              color: t.dialogBg,
              border: Border.all(color: t.borderColor),
              boxShadow: [BoxShadow(color: t.dialogShadow, blurRadius: 20)],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DialogTitleBar(onClose: () => Navigator.of(context).pop()),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 300,
                        child: _QuickSidebar(
                          currentPath: currentPath,
                          onPick: (path) {
                            _navigate(path);
                          },
                          onPickFile: (path) {
                            widget.onOpen(path);
                            Navigator.of(context).pop();
                          },
                          onRemoveCustomPlace: (path) {
                            context
                                .read<TraceStore>()
                                .removeCustomPlace(path);
                            _refocusRootIfSearchInactive();
                          },
                        ),
                      ),
                      Container(width: 1, color: t.borderColor),
                      Expanded(
                        child: _BrowserPanel(
                          currentPath: currentPath,
                          entries: visible,
                          loading: loading,
                          loadError: loadError,
                          selectedIndex: selectedIndex,
                          searchCtrl: _searchCtrl,
                          searchFocus: _searchFocus,
                          listCtrl: _listCtrl,
                          showAllFiles: showAllFiles,
                          onUp: () {
                            _goUp();
                          },
                          onCrumb: _navigate,
                          onSearchChanged: _onSearchChanged,
                          onToggleShowAll: () {
                            _toggleShowAllFiles();
                            _refocusRootIfSearchInactive();
                          },
                          onSelect: (i) {
                            setState(() => selectedIndex = i);
                            _refocusRootIfSearchInactive();
                          },
                          onActivate: (i) {
                            setState(() => selectedIndex = i);
                            _activateSelected();
                          },
                          onAddCurrentToPlaces: () {
                            context
                                .read<TraceStore>()
                                .addCustomPlace(currentPath);
                            _refocusRootIfSearchInactive();
                          },
                          onAddPathToPlaces: (path) {
                            context.read<TraceStore>().addCustomPlace(path);
                            _refocusRootIfSearchInactive();
                          },
                          onCreateExamples: () => _createExamplesHere(),
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
    );
  }
}

class _DialogTitleBar extends StatelessWidget {
  final VoidCallback onClose;
  const _DialogTitleBar({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.borderColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('OPEN CONFIG', style: BxpText.title(context)),
          _IconBtn(
            icon: Icons.close,
            tooltip: 'Close (Esc)',
            onTap: onClose,
          ),
        ],
      ),
    );
  }
}

class _QuickSidebar extends StatelessWidget {
  final String currentPath;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onPickFile;
  final ValueChanged<String> onRemoveCustomPlace;

  const _QuickSidebar({
    required this.currentPath,
    required this.onPick,
    required this.onPickFile,
    required this.onRemoveCustomPlace,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final store = context.watch<TraceStore>();
    final home = _userHome();
    final docs = p.join(home, 'Documents');
    final showDocs = Directory(docs).existsSync();
    final drives = Platform.isWindows ? _windowsDrives() : const <String>[];
    final custom = store.customPlaces;

    return Container(
      color: t.panelBg,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            _SidebarSectionLabel(text: 'PLACES'),
            _SidebarRow(
              icon: Icons.home_outlined,
              label: 'Home',
              active: p.equals(currentPath, home),
              onTap: () => onPick(home),
            ),
            if (showDocs)
              _SidebarRow(
                icon: Icons.folder_outlined,
                label: 'Documents',
                active: p.equals(currentPath, docs),
                onTap: () => onPick(docs),
              ),
            for (final path in custom)
              _SidebarRow(
                icon: Icons.bookmark_outline,
                label: p.basename(path).isEmpty ? path : p.basename(path),
                tooltip: path,
                active: p.equals(currentPath, path),
                onTap: () => onPick(path),
                onSecondaryTap: (pos) => _showRemoveMenu(context, pos, path),
              ),
            if (drives.isNotEmpty) ...[
              const SizedBox(height: 8),
              _SidebarSectionLabel(text: 'DRIVES'),
              for (final d in drives)
                _SidebarRow(
                  icon: Icons.storage_outlined,
                  label: d,
                  active: p.equals(currentPath, d),
                  onTap: () => onPick(d),
                ),
            ],
            if (store.recentFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              _SidebarSectionLabel(text: 'RECENT'),
              for (final path in store.recentFiles)
                _RecentRow(path: path, onTap: () => onPickFile(path)),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showRemoveMenu(BuildContext ctx, Offset pos, String path) async {
    final selected = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [_compactMenuItem('remove', 'Remove from Places')],
    );
    if (selected == 'remove') {
      onRemoveCustomPlace(path);
    }
  }
}

PopupMenuItem<String> _compactMenuItem(String value, String label) {
  return PopupMenuItem<String>(
    value: value,
    height: 28,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Text(label, style: const TextStyle(fontSize: 12)),
  );
}

/// Small icon button with explicit hover background + tooltip. Used for
/// the breadcrumb ↑, the close ✕, and the bookmark-add icons in the
/// dialog chrome — InkWell's default ripple is too subtle on the dark
/// dialog bg, so we paint a hoverOverlay-derived square ourselves.
class _IconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color:
                  _hover ? t.withHover(t.dialogBg) : Colors.transparent,
              border: Border.all(
                color: _hover ? t.borderColor : Colors.transparent,
              ),
            ),
            child: Icon(widget.icon, size: 16, color: t.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _SidebarSectionLabel extends StatelessWidget {
  final String text;
  const _SidebarSectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Text(text, style: BxpText.label(context)),
    );
  }
}

class _SidebarRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final String? tooltip;
  final ValueChanged<Offset>? onSecondaryTap;

  const _SidebarRow({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.tooltip,
    this.onSecondaryTap,
  });

  @override
  State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final bg = widget.active
        ? t.selectionBg
        : (_hover ? t.withHover(t.panelBg) : Colors.transparent);
    final fg = widget.active ? t.selectionText : t.textPrimary;
    Widget row = GestureDetector(
      onTap: widget.onTap,
      onSecondaryTapDown: widget.onSecondaryTap == null
          ? null
          : (d) => widget.onSecondaryTap!(d.globalPosition),
      child: Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            Icon(widget.icon, size: 14, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.label,
                style: BxpText.body(context, color: fg, size: BxpSize.sm),
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
          ],
        ),
      ),
    );
    if (widget.tooltip != null) {
      row = Tooltip(
        message: widget.tooltip!,
        waitDuration: const Duration(milliseconds: 600),
        child: row,
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: row,
    );
  }
}

class _RecentRow extends StatefulWidget {
  final String path;
  final VoidCallback onTap;
  const _RecentRow({required this.path, required this.onTap});

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final name = p.basename(widget.path);
    final dir = p.dirname(widget.path);
    final bg = _hover ? t.withHover(t.panelBg) : Colors.transparent;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.path,
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            color: bg,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: BxpText.body(context, size: BxpSize.sm),
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
                Text(
                  dir,
                  style: BxpText.muted(context),
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowserPanel extends StatelessWidget {
  final String currentPath;
  final List<FileSystemEntity> entries;
  final bool loading;
  final String? loadError;
  final int selectedIndex;
  final TextEditingController searchCtrl;
  final FocusNode searchFocus;
  final ScrollController listCtrl;
  final bool showAllFiles;
  final VoidCallback onUp;
  final ValueChanged<String> onCrumb;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onToggleShowAll;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onActivate;
  final VoidCallback onAddCurrentToPlaces;
  final ValueChanged<String> onAddPathToPlaces;
  final VoidCallback onCreateExamples;

  const _BrowserPanel({
    required this.currentPath,
    required this.entries,
    required this.loading,
    required this.loadError,
    required this.selectedIndex,
    required this.searchCtrl,
    required this.searchFocus,
    required this.listCtrl,
    required this.showAllFiles,
    required this.onUp,
    required this.onCrumb,
    required this.onSearchChanged,
    required this.onToggleShowAll,
    required this.onSelect,
    required this.onActivate,
    required this.onAddCurrentToPlaces,
    required this.onAddPathToPlaces,
    required this.onCreateExamples,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BreadcrumbBar(
          path: currentPath,
          onUp: onUp,
          onPick: onCrumb,
          onAddCurrent: onAddCurrentToPlaces,
          onCreateExamples: onCreateExamples,
        ),
        _SearchBar(
          controller: searchCtrl,
          focusNode: searchFocus,
          onChanged: onSearchChanged,
          showAllFiles: showAllFiles,
          onToggleShowAll: onToggleShowAll,
        ),
        Expanded(
          child: _EntryList(
            entries: entries,
            loading: loading,
            loadError: loadError,
            selectedIndex: selectedIndex,
            listCtrl: listCtrl,
            onSelect: onSelect,
            onActivate: onActivate,
            onAddDirToPlaces: onAddPathToPlaces,
          ),
        ),
      ],
    );
  }
}

class _BreadcrumbBar extends StatelessWidget {
  final String path;
  final VoidCallback onUp;
  final ValueChanged<String> onPick;
  final VoidCallback onAddCurrent;
  final VoidCallback onCreateExamples;

  const _BreadcrumbBar({
    required this.path,
    required this.onUp,
    required this.onPick,
    required this.onAddCurrent,
    required this.onCreateExamples,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final parts = path.isEmpty ? const <String>[] : p.split(path);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.borderColor)),
      ),
      child: Row(
        children: [
          _IconBtn(
            icon: Icons.arrow_upward,
            tooltip: 'Parent folder (Backspace)',
            onTap: onUp,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  for (var i = 0; i < parts.length; i++) ...[
                    InkWell(
                      onTap: () =>
                          onPick(p.joinAll(parts.sublist(0, i + 1))),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          parts[i] == p.separator ? p.separator : parts[i],
                          style: BxpText.body(context,
                              color: t.textPrimary, size: BxpSize.md),
                        ),
                      ),
                    ),
                    if (i < parts.length - 1 &&
                        parts[i] != p.separator)
                      Text(p.separator,
                          style: BxpText.body(context,
                              color: t.textMuted, size: BxpSize.md)),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          _IconBtn(
            icon: Icons.bookmark_add_outlined,
            tooltip: 'Add current folder to Places',
            onTap: onAddCurrent,
          ),
          _IconBtn(
            icon: Icons.note_add_outlined,
            tooltip: 'Create example templates (bxp-cli.examples.json) here',
            onTap: onCreateExamples,
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final bool showAllFiles;
  final VoidCallback onToggleShowAll;

  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.showAllFiles,
    required this.onToggleShowAll,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              style: BxpText.body(context,
                  color: t.textPrimary, size: BxpSize.sm),
              cursorColor: t.textPrimary,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter (type to search, ↑↓ to move, Enter to open)',
                hintStyle: BxpText.body(context,
                    color: t.inputPlaceholder, size: BxpSize.sm),
                prefixIcon: Icon(Icons.search,
                    size: 14, color: t.inputPlaceholder),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 28, minHeight: 24),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                filled: true,
                fillColor: t.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: t.inputBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: t.inputBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: t.inputBorderFocused),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _FilterToggle(
            showAllFiles: showAllFiles,
            onTap: onToggleShowAll,
          ),
        ],
      ),
    );
  }
}

class _FilterToggle extends StatefulWidget {
  final bool showAllFiles;
  final VoidCallback onTap;
  const _FilterToggle({required this.showAllFiles, required this.onTap});

  @override
  State<_FilterToggle> createState() => _FilterToggleState();
}

class _FilterToggleState extends State<_FilterToggle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final label = widget.showAllFiles ? '*.*' : '*.json*';
    final bg = _hover ? t.withHover(t.inputFill) : t.inputFill;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.showAllFiles
            ? 'Showing all files — click to show only *.json*'
            : 'Showing *.json* — click to show all files',
        waitDuration: const Duration(milliseconds: 400),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: t.inputBorder),
            ),
            child: Text(
              label,
              style: BxpText.body(context,
                  color: t.textPrimary, size: BxpSize.sm),
            ),
          ),
        ),
      ),
    );
  }
}

class _EntryList extends StatelessWidget {
  final List<FileSystemEntity> entries;
  final bool loading;
  final String? loadError;
  final int selectedIndex;
  final ScrollController listCtrl;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onActivate;
  final ValueChanged<String> onAddDirToPlaces;

  const _EntryList({
    required this.entries,
    required this.loading,
    required this.loadError,
    required this.selectedIndex,
    required this.listCtrl,
    required this.onSelect,
    required this.onActivate,
    required this.onAddDirToPlaces,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;

    if (loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(loadError!,
              style: BxpText.body(context, color: t.errorText)),
        ),
      );
    }
    if (entries.isEmpty) {
      return Center(
        child: Text('No matching files', style: BxpText.italic(context)),
      );
    }

    return Scrollbar(
      controller: listCtrl,
      thumbVisibility: true,
      child: ListView.builder(

        controller: listCtrl,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final entry = entries[i];
          final isDir = entry is Directory;
          return _EntryRow(
            name: p.basename(entry.path),
            isDir: isDir,
            selected: i == selectedIndex,
            onTap: () => onSelect(i),
            onDoubleTap: () => onActivate(i),
            onSecondaryTap: !isDir
                ? null
                : (pos) => _showAddMenu(context, pos, entry.path),
          );
        },
      ),
    );
  }

  void _showAddMenu(BuildContext ctx, Offset pos, String path) async {
    final selected = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [_compactMenuItem('add', 'Add to Places')],
    );
    if (selected == 'add') {
      onAddDirToPlaces(path);
    }
  }
}

class _EntryRow extends StatefulWidget {
  final String name;
  final bool isDir;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset>? onSecondaryTap;

  const _EntryRow({
    required this.name,
    required this.isDir,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    this.onSecondaryTap,
  });

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final bg = widget.selected
        ? t.selectionBg
        : (_hover ? t.withHover(t.panelBg) : Colors.transparent);
    final fg = widget.selected
        ? t.selectionText
        : (widget.isDir ? t.codeColumn : t.textPrimary);
    final icon = widget.isDir ? Icons.folder : Icons.description_outlined;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapDown: widget.onSecondaryTap == null
            ? null
            : (d) => widget.onSecondaryTap!(d.globalPosition),
        child: Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.name,
                  style: BxpText.body(context, color: fg, size: BxpSize.md),
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
