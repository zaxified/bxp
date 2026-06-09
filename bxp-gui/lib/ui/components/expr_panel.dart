import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../platform_shortcuts.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_editor.dart';
import 'expr_highlight.dart';
import 'expr_playground.dart';

/// Width of the trailing slot (Cancel + gap + Apply) at the bottom of
/// the in-panel editor. Reused by ExprPlayground as an empty
/// reservation so the shared error box wraps to the same width in both
/// modes — without it the playground's error would span full width
/// while the panel's would visually stop short of the buttons.
const double exprButtonsSlotWidth = 170;

/// Height of the bottom row that hosts the error box + buttons. Tall
/// enough for two-line wrapped error text plus button vertical padding.
const double exprBottomRowHeight = 60;

class ExprPanel extends StatefulWidget {
  const ExprPanel({super.key});

  @override
  State<ExprPanel> createState() => _ExprPanelState();
}

/// Capped + scrollable error display reused by both the in-panel editor
/// and the ExprPlayground. When [message] is null/empty the widget
/// renders a transparent placeholder of the same shape so the
/// surrounding row layout doesn't jump as errors appear/disappear.
class _ExprErrorBox extends StatelessWidget {
  final String? message;
  const _ExprErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    if (message == null || message!.isEmpty) {
      return const SizedBox.shrink();
    }
    // Align(topLeft) keeps the red background hugging the text — without
    // it the Container would stretch to fill the Expanded slot and paint
    // a giant red rectangle next to a short error message. ConstrainedBox
    // caps the painted box at [exprBottomRowHeight] so an unusually long
    // diagnostic doesn't blow up the bottom row.
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: exprBottomRowHeight),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: t.errorBg),
          child: SingleChildScrollView(
            child: SelectableText(
              message!,
              style: BxpText.body(context, color: t.errorText, size: BxpSize.sm),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExprPanelState extends State<ExprPanel> {
  final _controller = ExprTextEditingController();
  final _focusNode = FocusNode();
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
      // Selecting a new expr (tree click, click-to-jump from row-detail)
      // should drop the user straight into typing — same UX as opening
      // any inline tree editor. Defer to post-frame so the TextField is
      // mounted before we requestFocus.
      if (store.selectedExprPath != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNode.requestFocus();
        });
      }
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Newlines in the editor are a typing aid (the user can press Enter
  /// to split a long expression across visual lines while editing).
  /// They are stripped before validation and before commit so neither
  /// `the bridge expr validator validate` nor the persisted config sees them — both
  /// would reject a literal newline mid-token.
  String _strip(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' ');

  void _commit(TraceStore store) {
    if (store.selectedExprPath == null) return;
    final text = _strip(_controller.text);
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
      // Both slices are tight-flex so the column always fills its parent
      // top-to-bottom. The playground manages its own internal layout —
      // editor expands to fill, scrollbar stays inside the editor box,
      // not on the whole slice.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(flex: 25, child: ExprPlayground()),
          Expanded(
            flex: 75,
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
        Expanded(
          flex: 25,
          child: Container(
            // Padding matches ExprPlayground (LTR 16, no bottom) so the
            // buttons row sits flush against the docs divider — without
            // a trailing 16 px the user used to see a ~1 cm gap before
            // the docs columns started. The TextField inside is
            // `expands: true` and scrolls its own content, leaving
            // header / error / buttons anchored.
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: dividerColor)),
            ),
            child: _buildEditor(context, store, dividerColor),
          ),
        ),
        const Expanded(flex: 75, child: _DocsPanel()),
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
              // 4-state validation badge (idle/pending/ok/error) so the user
              // sees a "checking" pulse during the 500ms debounce + the bridge
              // spawn instead of stale flicker between "valid" and "invalid".
              // Muted to "idle" while the autocomplete popup is up: the
              // user is mid-completion, a stale INVALID from the previous
              // partial keystroke shouts at them while they're picking.
              ExprValidationBadgeSlot(
                state: store.isExprAutocompleteOpen
                    ? ExprValidationState.idle
                    : store.exprValidationState,
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
        Expanded(
          child: ExprEditor(
            controller: _controller,
            focusNode: _focusNode,
            // Same masking as the badge: a red border while the popup
            // is open reads as "you're wrong" exactly when the user is
            // about to type the right thing.
            hasError: !store.isExprAutocompleteOpen &&
                store.exprValidationError != null,
            expands: true,
            onChanged: (text) => store.updateSelectedExprText(_strip(text)),
            onAutocompleteVisibilityChanged: store.setExprAutocompleteOpen,
          ),
        ),

        const SizedBox(height: 8),
        // Error box + Cancel/Apply share one row: the error widget gets
        // the leftover space (Expanded) while the buttons take a
        // fixed [exprButtonsSlotWidth] slot on the right. The
        // ExprPlayground reuses the same row but with an empty slot in
        // place of the buttons, so the error wraps to the same width
        // in both modes — no visual divergence between
        // has-expr / scratchpad. Row sizes to its taller child (button
        // height 28 px or wrapped error text up to its internal cap),
        // so an absent error doesn't waste vertical space above the
        // docs divider.
        IntrinsicHeight(
          child: Row(
            // `stretch` makes each cell fill the row's intrinsic height
            // (= max(error_height, button_height)). Inside, the error
            // cell uses Align(topLeft) so it stays anchored at the top
            // and the buttons cell uses Align(bottomRight) so the
            // buttons stay glued to the row's bottom edge — without
            // that pairing, growing/shrinking the error visibly hops
            // the buttons by a few pixels each time it toggles.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _ExprErrorBox(
                  message: store.isExprAutocompleteOpen
                      ? null
                      : store.exprValidationError,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: exprButtonsSlotWidth,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                    // Cancel = discard pending edits + close the editor
                    // pane. Always enabled: even with no pending edits
                    // it lets the user back out of the editor with one
                    // click.
                    _ExprActionButton(
                      label: 'Cancel',
                      primary: false,
                      onPressed: () => store.clearSelectedExpr(),
                    ),
                    const SizedBox(width: 6),
                    _ExprActionButton(
                      label: 'Apply',
                      primary: true,
                      // Apply stays disabled if the last validation said
                      // INVALID. While the popup is up the badge is
                      // muted but the underlying error is still real,
                      // so we keep Apply gated on it — clicking Apply
                      // mid-completion would commit a partial expression.
                      onPressed: store.exprValidationError == null
                          ? () => _commit(store)
                          : null,
                    ),
                  ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // Small gap below the buttons so they don't sit flush against
        // the docs divider (which reads as cramped at typical zoom).
        const SizedBox(height: 6),
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
    // (see _StartupGate in main.dart) — the bridge docs catalog is the only source
    // of truth.
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
                  for (final f in ([...store.docFunctions]..sort((a, b) =>
                      (a['name']?.toString() ?? '')
                          .compareTo(b['name']?.toString() ?? ''))))
                    _FuncDoc(f),
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
                _TipDoc('$commandModifierLabel+Scroll zooms the whole UI; '
                    '$commandModifierLabel+0 resets, '
                    '$commandModifierLabel++/$commandModifierLabel+- step.'),
                _TipDoc('$commandModifierLabel+Shift+S opens the settings / '
                    'runtime inspector — it lists every keyboard shortcut, '
                    'the binary paths, and the active config status.'),
              ],
            ),
          ),
        ),
      ],
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

/// One FUNCTIONS-panel entry: bold signature, muted description, and an
/// optional `e.g. …` example. The signature and the example are
/// click-to-insert — tapping the signature splices the call scaffold
/// (ArgKind-aware quoting via [ExprEditor.scaffoldFor]) and tapping the
/// example splices it verbatim into the live editor at the caret (see
/// `TraceStore.requestExprInsert`). A hover background flags clickability;
/// no Tooltip — Flutter's Tooltip steals hover + blocks scroll inside the
/// scrollable docs column.
class _FuncDoc extends StatefulWidget {
  final Map<String, dynamic> fn;
  const _FuncDoc(this.fn);
  @override
  State<_FuncDoc> createState() => _FuncDocState();
}

class _FuncDocState extends State<_FuncDoc> {
  // 0 = none hovered, 1 = signature, 2 = example.
  int _hover = 0;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final fn = widget.fn;
    final sig = fn['signature']?.toString() ?? fn['name']?.toString() ?? '';
    final desc = fn['description']?.toString() ?? '';
    final example = fn['example']?.toString() ?? '';
    final hoverBg = t.accentHighlight.withValues(alpha: 0.12);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Signature + example share a line (Wrap drops the example to the
          // next line when the pair is too wide for the column, e.g.
          // DATE_CONVERT). Each is independently click-to-insert.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 1,
            children: [
              _clickable(
                id: 1,
                hoverBg: hoverBg,
                onTap: () {
                  final store = context.read<TraceStore>();
                  store.requestExprInsert(ExprEditor.scaffoldFor(store, fn));
                },
                child: Text(
                  sig,
                  style: BxpText.body(
                    context,
                    color: t.codeFunction,
                    size: BxpSize.sm,
                    weight: BxpWeight.bold,
                  ),
                ),
              ),
              if (example.isNotEmpty)
                _clickable(
                  id: 2,
                  hoverBg: hoverBg,
                  onTap: () =>
                      context.read<TraceStore>().requestExprInsert(example),
                  child: RichText(
                    text: TextSpan(children: [
                      TextSpan(
                        text: '→  ',
                        style: BxpText.muted(context, size: BxpSize.xs),
                      ),
                      TextSpan(
                        text: example,
                        style: BxpText.body(
                          context,
                          color: t.codeString,
                          size: BxpSize.xs,
                        ),
                      ),
                    ]),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(desc, style: BxpText.muted(context, size: BxpSize.xs)),
          ),
        ],
      ),
    );
  }

  Widget _clickable({
    required int id,
    required Color hoverBg,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = id),
      onExit: (_) => setState(() {
        if (_hover == id) _hover = 0;
      }),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: _hover == id ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          child: child,
        ),
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

// Map a `the bridge docs catalog tokens[].kind` value to the active theme's
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
/// breadcrumb row. The label changes ("VALID"/"INVALID"/"checking"/—)
/// have different rendered widths; without a fixed envelope the
/// surrounding breadcrumb path and ✕ button hop a few pixels with
/// each state transition, which looks like a glitch.
///
/// Width is sized to fit the longest label in the bundled Roboto font
/// (see [pubspec.yaml] `flutter.fonts`) — that is the reason we bundle
/// Roboto rather than rely on the system sans: across Linux, macOS, and
/// Windows the system fallback differs (DejaVu / SF Pro / Segoe UI),
/// each metric a different width for "checking", and a slot tuned on
/// one platform wraps to two lines on another. The trailing
/// `softWrap:false`/`overflow:clip` guards make the slot resilient
/// to a future font change too — an overflowing label gets clipped,
/// never reflows.
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
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: BxpText.label(context, color: t.okText),
          ),
          ExprValidationState.error => Text(
            'INVALID',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: BxpText.label(context, color: t.errorText),
          ),
          ExprValidationState.pending => Text(
            'checking',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: BxpText.label(context, color: t.infoText),
          ),
          ExprValidationState.idle => const SizedBox.shrink(),
        },
      ),
    );
  }
}

/// Cancel/Apply pair use the same button shell so the editor footer reads
/// as one consistent control row. Apply is differentiated by background
/// fill only — same height, padding, and font as Cancel. Disabled state
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
