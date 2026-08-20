import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import '../../services/doc_links.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';

/// Application-level navigation bar. Contains the CONFIG / RUNNER tab selectors
/// on the left and the DOCS link + theme-cycle button on the right.
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
            label: 'DOCS',
            active: false,
            tooltip: 'Open the BXP manual ($kDocsSiteUrl)',
            onTap: () => openExternalUrl(kDocsSiteUrl),
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
