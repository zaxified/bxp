import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_editor.dart';
import 'expr_highlight.dart';
import 'expr_playground.dart';

class ExprPanel extends StatefulWidget {
  const ExprPanel({super.key});

  @override
  State<ExprPanel> createState() => _ExprPanelState();
}

class _ExprPanelState extends State<ExprPanel> {
  final _controller = ExprTextEditingController();
  int _lastGen = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.read<TraceStore>();
    if (store.exprGeneration != _lastGen) {
      _lastGen = store.exprGeneration;
      if (_controller.text != store.selectedExprText) {
        _controller.text = store.selectedExprText;
        _controller.selection = TextSelection.collapsed(
          offset: _controller.text.length,
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit(TraceStore store) {
    final text = _controller.text;
    if (store.selectedExprPath == null) return;
    store.editConfigNode(store.selectedExprPath!, text);
    store.setSelectedExpr(store.selectedExprPath!, text);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final t = context.bxpTheme;
    final hasExpr = store.selectedExprPath != null;
    final dividerColor = t.borderColor;

    if (!hasExpr) {
      // Playground sits in its own scrollable Flexible slice (1/3 of the
      // column by default) so a narrow ExprPanel — e.g. when the user has
      // dragged the divider tight or zoomed in — can still render the
      // DocsPanel below it instead of overflowing the column. DocsPanel
      // keeps its 2/3 Expanded share and its own internal column scrollers.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: const ExprPlayground(),
            ),
          ),
          Expanded(
            flex: 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: dividerColor)),
              ),
              child: const _DocsPanel(),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            child: Container(
              // Padding matches ExprPlayground (all: 16) so the editor box
              // sits at the same Y in both modes — toggling ✕/Esc keeps
              // the box visually pinned.
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: dividerColor)),
              ),
              child: _buildEditor(context, store, dividerColor),
            ),
          ),
        ),
        const Expanded(flex: 2, child: _DocsPanel()),
      ],
    );
  }

  Widget _buildEditor(
    BuildContext context,
    TraceStore store,
    Color dividerColor,
  ) {
    final t = context.bxpTheme;
    final path = store.selectedExprPath!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Fixed header height matches the ExprPlayground row so toggling
        // between the in-panel editor and the playground (✕ / Esc) does
        // not visually shift the editor box below.
        SizedBox(
          height: 32,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (int i = 0; i < path.length; i++) ...[
                        if (i > 0)
                          Text(
                            ' › ',
                            style: BxpText.body(
                              context,
                              color: t.textMuted,
                              size: BxpSize.sm,
                            ),
                          ),
                        Text(
                          path[i],
                          style: BxpText.body(
                            context,
                            color: int.tryParse(path[i]) != null
                                ? t.textMuted
                                : t.codeVariable,
                            size: BxpSize.sm,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 4-state validation badge — mirrors bxp-ui's
              // ValidationBadge (idle/pending/ok/error) so the user sees a
              // "checking" pulse during the 200ms debounce + bxp-fmt spawn
              // instead of stale flicker between "valid" and "invalid".
              // Fixed-width slot prevents the breadcrumb / ✕ button from
              // hopping when the label changes length (idle→checking→valid→
              // invalid have different glyph widths in monospace).
              ExprValidationBadgeSlot(state: store.exprValidationState),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => store.clearSelectedExpr(),
                child: Text(
                  '✕',
                  style: TextStyle(color: t.textMuted, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        // Gap below the header — must match ExprPlayground's 10 px so
        // the editor box does not shift when entering/leaving an expr.
        const SizedBox(height: 10),

        // No auto-commit on tap-outside / submit / editing-complete:
        // the only path that writes back into configJson is the Apply
        // button. Auto-committing would (a) silently save invalid
        // expressions when the user clicks anywhere off the field, and
        // (b) clobber the baseline before Reset has a chance to run
        // (the Reset button is "outside" the textfield, so a tap-
        // outside fires *before* its own onPressed).
        ExprEditor(
          controller: _controller,
          hasError: store.exprValidationError != null,
          minLines: 4,
          onChanged: (text) => store.updateSelectedExprText(text),
        ),

        // Error message
        if (store.exprValidationError != null) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: t.errorBg),
            child: SelectableText(
              store.exprValidationError!,
              style: BxpText.body(
                context,
                color: t.errorText,
                size: BxpSize.sm,
              ),
            ),
          ),
        ],

        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _ExprActionButton(
              label: 'Reset',
              primary: false,
              onPressed: store.selectedExprText == store.selectedExprBaseline
                  ? null
                  : () {
                      _controller.text = store.selectedExprBaseline;
                      _controller.selection = TextSelection.collapsed(
                        offset: _controller.text.length,
                      );
                      store.updateSelectedExprText(store.selectedExprBaseline);
                    },
            ),
            const SizedBox(width: 6),
            _ExprActionButton(
              label: 'Apply',
              primary: true,
              onPressed: store.exprValidationError == null
                  ? () => _commit(store)
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

// ── Docs Panel ──────────────────────────────────────────────────────────────

class _DocsPanel extends StatelessWidget {
  const _DocsPanel();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final t = context.bxpTheme;
    // All four catalogs are guaranteed populated by the startup gate
    // (see _StartupGate in main.dart) — bxp-fmt --docs is the only source
    // of truth.
    final fns = store.docFunctions
        .map(
          (f) => (
            f['signature']?.toString() ?? f['name']?.toString() ?? '',
            f['description']?.toString() ?? '',
          ),
        )
        .toList();
    final kws = store.docKeywords
        .map(
          (k) => (
            k['name']?.toString() ?? '',
            k['description']?.toString() ?? '',
          ),
        )
        .toList();
    final ops = store.docOperators
        .map(
          (o) => (
            o['token']?.toString() ?? '',
            o['description']?.toString() ?? '',
          ),
        )
        .toList();
    // SYNTAX section: docs payload supplies (syntax, description, kind);
    // we map kind → theme-aware color so the swatch matches the inline
    // highlighter (light/dark themes paint completely different palettes).
    final syntax = store.docTokens
        .map(
          (tok) => (
            tok['syntax']?.toString() ?? '',
            tok['description']?.toString() ?? '',
            _syntaxColorFor(tok['kind']?.toString() ?? '', t),
          ),
        )
        .toList();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: t.borderColor)),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionLabel('FUNCTIONS'),
                  const SizedBox(height: 10),
                  for (final f in fns) _FuncDoc(f.$1, f.$2),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionLabel('KEYWORDS'),
                const SizedBox(height: 8),
                for (final k in kws) _KeyDoc(k.$1, k.$2, t.codeKeyword),
                const SizedBox(height: 16),
                const _SectionLabel('OPERATORS'),
                const SizedBox(height: 8),
                for (final o in ops) _OpRow(o.$1, o.$2),
                const SizedBox(height: 16),
                const _SectionLabel('SYNTAX'),
                const SizedBox(height: 8),
                for (final s in syntax) _SyntaxDoc(s.$1, s.$2, s.$3),
                const SizedBox(height: 16),
                const _SectionLabel('STATUS BAR'),
                const SizedBox(height: 8),
                _StatusDoc('IDLE',  'no config loaded',           t.textMuted),
                _StatusDoc('LOADED','config parsed cleanly',      t.okText),
                _StatusDoc('ERROR', 'config failed to validate',  t.errorText),
                const SizedBox(height: 6),
                _StatusDoc('idle',       'no run in progress',                t.textMuted),
                _StatusDoc('running',    'dry-run / full run streaming',      t.warnText),
                _StatusDoc('done - OK',  'exit 0 — all rows converted',       t.okText),
                _StatusDoc('done - WARN','exit 2 — converted with warnings',  t.warnText),
                _StatusDoc('done - ERR', 'exit 1 — see stderr panel',         t.errorText),
                const SizedBox(height: 16),
                const _SectionLabel('TIPS'),
                const SizedBox(height: 8),
                const _TipDoc('Click the file icon next to the config '
                    'path to open it in your default editor.'),
                const _TipDoc('Click the stderr badge in the status bar '
                    'to expand / collapse the captured stderr panel.'),
                const _TipDoc('Hover any token in the expression editor '
                    'to see its docstring inline.'),
                const _TipDoc('Ctrl+Scroll zooms the whole UI; Ctrl+0 '
                    'resets, Ctrl++/Ctrl+- step.'),
                const SizedBox(height: 16),
                const _SectionLabel('SHORTCUTS'),
                const SizedBox(height: 8),
                const _ShortcutDoc('Ctrl+S',       'Save config'),
                const _ShortcutDoc('Ctrl+O',       'Open config'),
                const _ShortcutDoc('Ctrl+R',       'Reload config from disk'),
                const _ShortcutDoc('Ctrl+Z',       'Undo'),
                const _ShortcutDoc('Ctrl+Y',       'Redo'),
                const _ShortcutDoc('Ctrl+T',       'Reset draft'),
                const _ShortcutDoc('Ctrl+Shift+T', 'Toggle theme inspector'),
                const _ShortcutDoc('Ctrl+Shift+S', 'Toggle settings / runtime inspector'),
                const _ShortcutDoc('Esc',          'Close open dialog or inspector'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ShortcutDoc extends StatelessWidget {
  final String keys;
  final String desc;
  const _ShortcutDoc(this.keys, this.desc);
  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 100, maxWidth: 110),
            child: Text(
              keys,
              style: BxpText.body(
                context,
                color: t.codeKeyword,
                size: BxpSize.sm,
                weight: BxpWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(desc, style: BxpText.muted(context, size: BxpSize.xs)),
          ),
        ],
      ),
    );
  }
}

class _StatusDoc extends StatelessWidget {
  final String label;
  final String desc;
  final Color color;
  const _StatusDoc(this.label, this.desc, this.color);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 72, maxWidth: 90),
            child: Text(
              label,
              style: BxpText.body(
                context,
                color: color,
                size: BxpSize.sm,
                weight: BxpWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(desc, style: BxpText.muted(context, size: BxpSize.xs)),
          ),
        ],
      ),
    );
  }
}

class _TipDoc extends StatelessWidget {
  final String text;
  const _TipDoc(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: BxpText.muted(context, size: BxpSize.xs)),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) =>
      Text(label, style: BxpText.label(context));
}

class _FuncDoc extends StatelessWidget {
  final String sig;
  final String desc;
  const _FuncDoc(this.sig, this.desc);
  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sig,
            style: BxpText.body(
              context,
              color: t.codeFunction,
              size: BxpSize.sm,
              weight: BxpWeight.bold,
            ),
          ),
          Text(desc, style: BxpText.muted(context, size: BxpSize.xs)),
        ],
      ),
    );
  }
}

class _KeyDoc extends StatelessWidget {
  final String name;
  final String desc;
  final Color color;
  const _KeyDoc(this.name, this.desc, this.color);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 20, maxWidth: 48),
            child: Text(
              name,
              style: BxpText.body(
                context,
                color: color,
                size: BxpSize.sm,
                weight: BxpWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(desc, style: BxpText.muted(context, size: BxpSize.xs)),
          ),
        ],
      ),
    );
  }
}

class _OpRow extends StatelessWidget {
  final String op;
  final String desc;
  const _OpRow(this.op, this.desc);
  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 20, maxWidth: 30),
            child: Text(
              op,
              style: BxpText.body(
                context,
                color: t.codeOperator,
                size: BxpSize.sm,
                weight: BxpWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(desc, style: BxpText.muted(context, size: BxpSize.xs)),
          ),
        ],
      ),
    );
  }
}

class _SyntaxDoc extends StatelessWidget {
  final String syntax;
  final String desc;
  final Color color;
  const _SyntaxDoc(this.syntax, this.desc, this.color);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            syntax,
            style: BxpText.body(
              context,
              color: color,
              size: BxpSize.sm,
              weight: BxpWeight.bold,
            ),
          ),
          Text(desc, style: BxpText.muted(context, size: BxpSize.xs)),
        ],
      ),
    );
  }
}

// Map a `bxp-fmt --docs tokens[].kind` value to the active theme's
// matching syntax color so the docs swatch matches the inline
// highlighter. Light theme paints VS Code Light Modern, dark paints
// Dark Modern — without this the docs panel would freeze on a single
// preset's palette regardless of which theme is active.
Color _syntaxColorFor(String kind, BxpTheme t) {
  switch (kind) {
    case 'columnRef':
      return t.codeColumn;
    case 'inputVar':
      return t.codeVariable;
    case 'string':
      return t.codeString;
    case 'number':
      return t.codeNumber;
    case 'function':
      return t.codeFunction;
    case 'keyword':
      return t.codeKeyword;
    default:
      return t.codeOperator;
  }
}


/// Constant-width slot for the 4-state validation badge in the
/// breadcrumb row. The label changes ("valid"/"invalid"/"checking"/—)
/// have different rendered widths; without a fixed envelope the
/// surrounding breadcrumb path and ✕ button hop a few pixels with
/// each state transition, which looks like a glitch.
///
/// Width was sized to fit the longest label ("checking" at 10 px).
class ExprValidationBadgeSlot extends StatelessWidget {
  final ExprValidationState state;
  const ExprValidationBadgeSlot({required this.state});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return SizedBox(
      width: 56,
      child: Align(
        alignment: Alignment.centerRight,
        child: switch (state) {
          ExprValidationState.ok => Text(
            'VALID',
            style: BxpText.label(context, color: t.okText),
          ),
          ExprValidationState.error => Text(
            'INVALID',
            style: BxpText.label(context, color: t.errorText),
          ),
          ExprValidationState.pending => Text(
            'checking',
            style: BxpText.label(context, color: t.infoText),
          ),
          ExprValidationState.idle => const SizedBox.shrink(),
        },
      ),
    );
  }
}

/// Reset/Apply pair use the same button shell so the editor footer reads
/// as one consistent control row. Apply is differentiated by background
/// fill only — same height, padding, and font as Reset. Disabled state
/// (no `onPressed`) mutes both background and foreground.
class _ExprActionButton extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback? onPressed;

  const _ExprActionButton({
    required this.label,
    required this.primary,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final enabled = onPressed != null;

    final Color bg;
    final Color border;
    final Color fg;
    if (primary) {
      bg = enabled ? t.accentHighlight : t.borderColor;
      border = bg;
      fg = enabled ? Colors.white : t.textMuted;
    } else {
      bg = Colors.transparent;
      border = t.borderColor;
      fg = enabled ? t.textPrimary : t.textMuted;
    }

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: Container(
          height: 28,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
          ),
          child: Text(
            label,
            style: BxpText.body(
              context,
              color: fg,
              size: BxpSize.sm,
              weight: primary ? BxpWeight.semiBold : BxpWeight.regular,
            ),
          ),
        ),
      ),
    );
  }
}
