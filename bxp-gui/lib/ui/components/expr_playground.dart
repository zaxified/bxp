import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/bxp_process_client.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_editor.dart';
import 'expr_highlight.dart';
import 'expr_panel.dart' show ExprValidationBadgeSlot;

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
        "DATE_CONVERT([Date], '%Y-%m-%d', '%d.%m.%Y')"),
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

  void _onChanged() {
    // Debounce 300ms so rapid typing doesn't spawn bxp-fmt on every char.
    _debounce?.cancel();
    final text = _ctrl.text;
    if (text.trim().isEmpty) {
      setState(() {
        _state = ExprValidationState.idle;
        _errorMessage = '';
      });
      return;
    }
    setState(() => _state = ExprValidationState.pending);
    _debounce = Timer(const Duration(milliseconds: 300), () => _validate(text));
  }

  Future<void> _validate(String text) async {
    if (text.trim().isEmpty) {
      setState(() {
        _state = ExprValidationState.idle;
        _errorMessage = '';
      });
      return;
    }
    final err = await BxpProcessClient.validateExpr(text);
    // Guard against races: caller may have replaced text in the meantime.
    if (!mounted || _ctrl.text != text) return;
    setState(() {
      if (err == null) {
        _state = ExprValidationState.ok;
        _errorMessage = '';
      } else {
        _state = ExprValidationState.error;
        _errorMessage = err;
      }
    });
  }

  void _loadExample(String expr) {
    _ctrl.text = expr;
    _ctrl.selection = TextSelection.collapsed(offset: expr.length);
  }

  @override
  Widget build(BuildContext context) {
    context.watch<TraceStore>();
    final t = context.bxpTheme;
    final isError = _state == ExprValidationState.error;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
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
                ExprValidationBadgeSlot(state: _state),
              ],
            ),
          ),
          const SizedBox(height: 10),

          ExprEditor(
            controller: _ctrl,
            hasError: isError,
            minLines: 5,
          ),
          if (isError) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: t.errorBg),
              child: SelectableText(
                _errorMessage,
                style: BxpText.body(context, color: t.errorText, size: BxpSize.sm),
              ),
            ),
          ],
        ],
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
