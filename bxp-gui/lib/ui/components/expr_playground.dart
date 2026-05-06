import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/bxp_process_client.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_highlight.dart';

/// Standalone expression scratchpad — mirrors bxp-ui's ExprPlayground.
///
/// Differs from the in-panel editor (which binds to `store.selectedExprPath`
/// and writes its value back into `configJson`): this widget is entirely
/// disconnected from the config. The user can paste or type any expression,
/// click one of the preset examples, and see a live "valid/invalid" badge
/// from `bxp-fmt --expr`. Useful for learning the DSL and sanity-checking
/// an expression before pasting it into the real config.
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
  _Status _status = const _Status.idle();

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
      setState(() => _status = const _Status.idle());
      return;
    }
    setState(() => _status = const _Status.pending());
    _debounce = Timer(const Duration(milliseconds: 300), () => _validate(text));
  }

  Future<void> _validate(String text) async {
    if (text.trim().isEmpty) {
      setState(() => _status = const _Status.idle());
      return;
    }
    final err = await BxpProcessClient.validateExpr(text);
    // Guard against races: caller may have replaced text in the meantime.
    if (!mounted || _ctrl.text != text) return;
    setState(() => _status = err == null ? const _Status.ok() : _Status.error(err));
  }

  void _loadExample(String expr) {
    _ctrl.text = expr;
    _ctrl.selection = TextSelection.collapsed(offset: expr.length);
  }

  @override
  Widget build(BuildContext context) {
    context.watch<TraceStore>();
    final t = context.bxpTheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('EXPRESSION', style: BxpText.label(context)),
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
              _StatusBadge(status: _status),
            ],
          ),
          const SizedBox(height: 10),

          // Editor box.
          Container(
            decoration: BoxDecoration(
              color: t.panelBg,
              border: Border.all(
                  color: _status.isError ? t.errorBorder : t.borderColor),
            ),
            child: TextField(
              controller: _ctrl,
              maxLines: null,
              minLines: 5,
              style: BxpText.body(context,color: t.textPrimary, sizePx: 13),
              cursorColor: t.accentHighlight,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.all(12),
                border: InputBorder.none,
              ),
            ),
          ),
          if (_status.isError) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: t.errorBg),
              child: SelectableText(
                _status.message,
                style: BxpText.body(context,color: t.errorText, size: BxpSize.sm),
              ),
            ),
          ],

          const SizedBox(height: 10),

          Text(
            'Scratchpad — changes here do not affect the config.',
            style: BxpText.italic(context, size: BxpSize.xs),
          ),
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

class _StatusBadge extends StatelessWidget {
  final _Status status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    late final String label;
    late final Color color;
    if (status.isOk) {
      label = 'valid';
      color = t.okText;
    } else if (status.isError) {
      label = 'invalid';
      color = t.errorText;
    } else if (status.isPending) {
      label = 'checking';
      color = t.infoText;
    } else {
      label = '';
      color = Colors.transparent;
    }
    return SizedBox(
      width: 56,
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(label, style: BxpText.label(context, color: color)),
      ),
    );
  }
}

class _Status {
  final int _kind; // 0=idle, 1=pending, 2=ok, 3=error
  final String message;
  const _Status._(this._kind, this.message);
  const _Status.idle() : this._(0, '');
  const _Status.pending() : this._(1, '');
  const _Status.ok() : this._(2, '');
  const _Status.error(String msg) : this._(3, msg);

  bool get isIdle => _kind == 0;
  bool get isPending => _kind == 1;
  bool get isOk => _kind == 2;
  bool get isError => _kind == 3;
}
