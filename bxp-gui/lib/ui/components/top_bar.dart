import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import '../../services/dev_trace.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';

const _githubUrl = 'https://github.com/zaxified/bxp';

/// Application-level navigation bar. Contains the CONFIG / RUNNER tab selectors
/// on the left and the GITHUB link + theme-cycle button on the right.
/// Active tab is tracked in TraceStore.activeTabIndex so the IndexedStack in
/// MainView reacts automatically; this widget is purely presentation.
class TopBar extends StatelessWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final t = context.bxpTheme;
    final activeTab = store.activeTabIndex;

    return Container(
      decoration: BoxDecoration(
        // Slight transparency so the surface bleed-through helps the bar
        // feel attached to the content column rather than floating above it.
        color: t.panelBg.withValues(alpha: 0.6),
        border: Border(bottom: BorderSide(color: t.borderColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          _TopTab(
            label: 'CONFIG',
            active: activeTab == 0,
            onTap: () => store.setActiveTab(0),
          ),
          _TopTab(
            label: 'RUNNER',
            active: activeTab == 1,
            onTap: () => store.setActiveTab(1),
          ),
          const Spacer(),
          _TopTab(
            label: 'GITHUB',
            active: false,
            tooltip: 'Open project on GitHub ($_githubUrl)',
            onTap: _openGithub,
          ),
          // Theme cycle button: label shows the current preset's short name
          // (e.g. "SLATE", "ZINC") so the user knows what clicking will do.
          _TopTab(
            label: t.label,
            active: false,
            tooltip: 'Theme: ${store.themePresetName} (click to cycle)',
            onTap: () => store.setThemePreset(nextPresetName(store.themePresetName)),
          ),
        ],
      ),
    );
  }

  Future<void> _openGithub() async {
    // Surface failures via devTrace — fire-and-forget Process.run swallows
    // the missing-binary case (no xdg-open on minimal Linux installs, no
    // `open` if the macOS user nuked it). Without this, a click that does
    // nothing looks like a UI bug.
    final (cmd, args) = switch (Platform.operatingSystem) {
      'linux' => ('xdg-open', [_githubUrl]),
      'macos' => ('open', [_githubUrl]),
      'windows' => ('cmd', ['/c', 'start', _githubUrl]),
      _ => (null, <String>[]),
    };
    if (cmd == null) {
      devTrace('topBar.openGithub.unsupported',
          {'platform': Platform.operatingSystem});
      return;
    }
    try {
      final result = await Process.run(cmd, args);
      if (result.exitCode != 0) {
        devTrace('topBar.openGithub.fail', {
          'cmd': cmd,
          'exitCode': result.exitCode,
          'stderr': result.stderr.toString(),
        });
      }
    } catch (e) {
      devTrace('topBar.openGithub.spawnFail',
          {'cmd': cmd, 'error': e.toString()});
    }
  }
}

class _TopTab extends StatefulWidget {
  final String label;
  final bool active;
  final String? tooltip;
  final VoidCallback onTap;

  const _TopTab({
    required this.label,
    required this.active,
    this.tooltip,
    required this.onTap,
  });

  @override
  State<_TopTab> createState() => _TopTabState();
}

class _TopTabState extends State<_TopTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;

    final activeBg = t.borderColor;
    final hoverBg = t.borderColor.withValues(alpha: 0.6);

    Color textColor;
    if (widget.active) {
      textColor = t.textPrimary;
    } else if (_hovered) {
      textColor = t.textPrimary;
    } else {
      textColor = t.textSubtle;
    }

    final bg = widget.active
        ? activeBg
        : (_hovered ? hoverBg : Colors.transparent);

    final core = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: bg,
          child: Text(widget.label,
              style: BxpText.label(context, color: textColor)),
        ),
      ),
    );
    return widget.tooltip == null
        ? core
        : Tooltip(message: widget.tooltip!, child: core);
  }
}
