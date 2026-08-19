import 'package:material_ui/material_ui.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';

/// A slim section label used atop FileList / RowList / OutputPanel.
///
/// Small uppercase title, letter-spaced, panel-bg background, themed
/// bottom border. Counts render in `BxpText.body` at the same size token
/// as the label so the layout stays consistent with the rest of the
/// app's prose typography.
class PanelHeader extends StatelessWidget {
  final String title;
  final int? count;
  final String? suffix;

  const PanelHeader({
    super.key,
    required this.title,
    this.count,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final countStyle = BxpText.body(context, color: t.textMuted, size: BxpSize.xs);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: t.panelBg,
        border: Border(bottom: BorderSide(color: t.borderColor)),
      ),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: BxpText.label(context, color: t.textMuted),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text('($count)', style: countStyle),
          ],
          if (suffix != null) ...[
            const SizedBox(width: 6),
            Text(suffix!, style: countStyle),
          ],
        ],
      ),
    );
  }
}
