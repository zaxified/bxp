import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';

const _githubUrl = 'https://github.com/zaxified/bxp';

class TopBar extends StatelessWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final t = context.bxpTheme;
    final activeTab = store.activeTabIndex;

    return Container(
      decoration: BoxDecoration(
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

  void _openGithub() {
    if (Platform.isLinux) {
      Process.run('xdg-open', [_githubUrl]);
    } else if (Platform.isMacOS) {
      Process.run('open', [_githubUrl]);
    } else if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', _githubUrl]);
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
