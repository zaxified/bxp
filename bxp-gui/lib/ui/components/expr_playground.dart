import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/bxp_process_client.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_editor.dart';
import 'expr_highlight.dart';
import 'expr_panel.dart'
    show
        ExprValidationBadgeSlot,
        exprButtonsSlotWidth,
        exprBottomRowHeight;
// `exprBottomRowHeight` is intentionally re-exported to keep the cap on
// `_PlaygroundErrorBox` height in sync with the panel-side `_ExprErrorBox`.

/// Standalone expression scratchpad — mirrors bxp-ui's ExprPlayground.
///
/// The playground is the same expression editor as the in-panel one — it
/// reuses [ExprEditor] for autocomplete and the syntax-highlighting
/// controller and shares the validation badge widget. The only differences
/// are the header (preset example chips instead of the JSON path
/// breadcrumb) and the absence of Reset/Apply buttons (no config to
/// commit into).
class ExprPlayground extends StatefulWidget {
  const ExprPlayground({super.key});

  @override
  State<ExprPlayground> createState() => _ExprPlaygroundState();
}

class _ExprPlaygroundState extends State<ExprPlayground> {
  // Same preset set as bxp-ui ExprPlayground.tsx so the "help a user learn
  // the DSL" experience is interchangeable.
  static const _examples = <_Example>[
    _Example('date convert',
        "DATE_CONVERT([Date], 'YYYY-MM-DD', 'DD.MM.YYYY')"),
    _Example('buy/sell', "IF([Qty] > 0, 'BUY', 'SELL')"),
    _Example('ticker map', 'TICKER([Symbol])'),
    _Example('price parts',
        "PRICE_VALUE([Price]) & ' ' & PRICE_CURRENCY([Price])"),
    _Example('coalesce',
        "COALESCE([ISIN], LOOKUP([Symbol], 'isin'), '')"),
  ];

  late final ExprTextEditingController _ctrl;
  Timer? _debounce;
  ExprValidationState _state = ExprValidationState.idle;
  String _errorMessage = '';
  /// Mirrors the panel-side suspension flag: while the autocomplete
  /// popup is up, skip the bxp-fmt spawn so partial-input typing
  /// doesn't flicker an INVALID badge during selection.
  bool _autocompleteOpen = false;

  @override
  void initState() {
    super.initState();
    _ctrl = ExprTextEditingController(text: _examples.first.expr);
    _ctrl.addListener(_onChanged);
    _validate(_ctrl.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    super.dispose();
  }

  /// Same newline rule as the in-panel editor: a typing aid only —
  /// stripped before validation so bxp-fmt sees a single-line input
  /// in both modes. Without this, the playground would surface a
  /// `UnexpectedChar '\n'` error the moment the user pressed Enter,
  /// while the panel silently accepted the same input — divergent UX.
  String _stripNewlines(String s) =>
      s.replaceAll(RegExp(r'[\r\n]+'), ' ');

  void _onChanged() {
    _debounce?.cancel();
    final text = _stripNewlines(_ctrl.text);
    if (text.trim().isEmpty) {
      setState(() {
        _state = ExprValidationState.idle;
        _errorMessage = '';
      });
      return;
    }
    if (_autocompleteOpen) {
      // User is mid-completion — leave the badge alone, the actual
      // validate fires when the popup closes (see _onAutocompleteVisibility).
      return;
    }
    setState(() => _state = ExprValidationState.pending);
    _debounce = Timer(const Duration(milliseconds: 500), () => _validate(text));
  }

  void _onAutocompleteVisibility(bool open) {
    setState(() => _autocompleteOpen = open);
    if (open) {
      _debounce?.cancel();
    } else {
      // Popup closed — re-validate the final text so the badge catches
      // up to whatever the user picked / typed past the suggestions.
      _onChanged();
    }
  }

  Future<void> _validate(String text) async {
    text = _stripNewlines(text);
    if (text.trim().isEmpty) {
      setState(() {
        _state = ExprValidationState.idle;
        _errorMessage = '';
      });
      return;
    }
    final res = await BxpProcessClient.validateExpr(text);
    // Guard against races: caller may have replaced text in the meantime
    // — compare the stripped version since `_ctrl.text` keeps newlines.
    if (!mounted || _stripNewlines(_ctrl.text) != text) return;
    setState(() {
      final err = res.error;
      if (err == null) {
        _state = ExprValidationState.ok;
        _errorMessage = '';
        _ctrl.setValidationSpan(offset: null, length: null);
      } else {
        _state = ExprValidationState.error;
        _errorMessage = err;
        // Push the offending token span into the controller so the
        // wavy underline lines up with the bridge response — same UX
        // as the tree editor, which routes through the TraceStore.
        _ctrl.setValidationSpan(offset: res.offset, length: res.length);
      }
    });
  }

  void _loadExample(String expr) {
    // Build text+selection in one TextEditingValue so the controller fires
    // listeners once — assigning .text then .selection emits two notifies
    // and forces an extra ExprEditor rebuild for every example tap.
    _ctrl.value = TextEditingValue(
      text: expr,
      selection: TextSelection.collapsed(offset: expr.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<TraceStore>();
    // Mute INVALID badge / red border / error box while the autocomplete
    // popup is up — same rationale as the in-panel editor.
    final isError =
        !_autocompleteOpen && _state == ExprValidationState.error;
    final shownState = _autocompleteOpen ? ExprValidationState.idle : _state;

    return Padding(
      // No bottom padding — matches the panel-mode container so the
      // playground's bottom row sits at the same Y as the panel's,
      // with a uniform 6 px gap added below before the docs divider.
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Fixed header height matches the ExprPanel breadcrumb row so
          // the editor box below does not jump when the user toggles
          // between an opened expression and the playground (Esc / ✕).
          SizedBox(
            height: 32,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('EXPRESSION SCRATCHPAD', style: BxpText.label(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 2,
                    runSpacing: 2,
                    children: [
                      for (final ex in _examples)
                        _ExampleBtn(
                            label: ex.label,
                            onTap: () => _loadExample(ex.expr)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ExprValidationBadgeSlot(state: shownState),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Editor fills the playground slot vertically; its TextField
          // scrolls its own content when the user adds many newlines —
          // the surrounding column does not push the error box out.
          Expanded(
            child: ExprEditor(
              controller: _ctrl,
              hasError: isError,
              expands: true,
              onAutocompleteVisibilityChanged: _onAutocompleteVisibility,
            ),
          ),
          const SizedBox(height: 8),
          // Mirrors the panel's bottom row: error box on the left
          // (Expanded) + a fixed-width slot on the right that's empty
          // here (no Cancel/Apply in scratchpad). IntrinsicHeight lets
          // the row collapse when there's no error so the playground
          // doesn't reserve dead space above the docs divider.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _PlaygroundErrorBox(
                    message: isError ? _errorMessage : null,
                  ),
                ),
                const SizedBox(width: 8),
                const SizedBox(width: exprButtonsSlotWidth),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

/// Same shape as the in-panel `_ExprErrorBox` but lives here to keep the
/// panel-side widget private. Cosmetics are identical so the two modes
/// render the same red box for the same diagnostic text.
class _PlaygroundErrorBox extends StatelessWidget {
  final String? message;
  const _PlaygroundErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    if (message == null || message!.isEmpty) {
      return const SizedBox.shrink();
    }
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

class _Example {
  final String label;
  final String expr;
  const _Example(this.label, this.expr);
}

class _ExampleBtn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _ExampleBtn({required this.label, required this.onTap});

  @override
  State<_ExampleBtn> createState() => _ExampleBtnState();
}

class _ExampleBtnState extends State<_ExampleBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: _hovered ? t.withHover(t.borderColor) : Colors.transparent,
          child: Text(
            widget.label.toUpperCase(),
            style: BxpText.label(context,
                color: _hovered ? t.textPrimary : t.textMuted),
          ),
        ),
      ),
    );
  }
}
