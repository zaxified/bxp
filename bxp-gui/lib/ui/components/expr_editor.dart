import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_highlight.dart';

/// Shared expression editor used by both the in-panel ExprPanel (which
/// commits back into the config tree) and the standalone ExprPlayground
/// (which is a scratchpad). Bundles:
///   - the multi-line `TextField` + syntax-highlighting controller wiring
///   - the autocomplete overlay (Ctrl+Space, identifier-prefix triggering,
///     ↑/↓ to navigate, Tab/Enter to insert, Esc to dismiss)
///   - error-border styling driven by [hasError]
///
/// The text controller is supplied by the caller — owning text is the
/// caller's job (ExprPanel mirrors store.selectedExprText, Playground
/// keeps a local instance). [onChanged] is fired on every keystroke;
/// [onEditingComplete] / [onSubmitted] / [onTapOutside] are forwarded
/// to the underlying TextField so the caller can decide what "commit"
/// means in its context.
class ExprEditor extends StatefulWidget {
  final ExprTextEditingController controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final ValueChanged<PointerDownEvent>? onTapOutside;
  final bool hasError;
  final int minLines;

  const ExprEditor({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTapOutside,
    this.hasError = false,
    this.minLines = 4,
  });

  @override
  State<ExprEditor> createState() => _ExprEditorState();
}

class _ExprEditorState extends State<ExprEditor> {
  final _focusNode = FocusNode();
  final _editorLink = LayerLink();

  // Autocomplete popup state. Lives in an OverlayEntry anchored to the
  // editor via LayerLink so it floats above surrounding widgets (mirrors
  // CodeMirror 6's dropdown behaviour). Triggered automatically while
  // typing an identifier prefix; Ctrl+Space force-opens even without a
  // prefix (shows all functions + keywords).
  OverlayEntry? _popup;
  List<_AcItem> _acItems = const [];
  int _acIndex = 0;
  int _acReplaceStart = 0;
  int _acReplaceEnd = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onEdit);
    _focusNode.addListener(_onFocusChange);
    _focusNode.onKeyEvent = _onKeyEvent;
  }

  @override
  void didUpdateWidget(covariant ExprEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onEdit);
      widget.controller.addListener(_onEdit);
    }
  }

  @override
  void dispose() {
    _hidePopup();
    widget.controller.removeListener(_onEdit);
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) _hidePopup();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // Ctrl+Space — force-open the popup regardless of prefix.
    if (event.logicalKey == LogicalKeyboardKey.space &&
        HardwareKeyboard.instance.isControlPressed) {
      _refreshAutocomplete(force: true);
      return KeyEventResult.handled;
    }
    if (_popup == null) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        setState(() => _acIndex = (_acIndex + 1) % _acItems.length);
        _popup!.markNeedsBuild();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        setState(
          () => _acIndex = (_acIndex - 1 + _acItems.length) % _acItems.length,
        );
        _popup!.markNeedsBuild();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.tab:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _applyAutocomplete(_acItems[_acIndex]);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        _hidePopup();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onEdit() => _refreshAutocomplete();

  /// Recompute the popup's item list based on the identifier under the
  /// cursor. Opens the popup if there are matches, otherwise hides it.
  /// With `force=true`, shows all completions (used by Ctrl+Space).
  void _refreshAutocomplete({bool force = false}) {
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    if (!sel.isValid || sel.start != sel.end) {
      _hidePopup();
      return;
    }
    final before = text.substring(0, sel.start);
    final m = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*$').firstMatch(before);
    final prefix = m?.group(0) ?? '';
    final start = m?.start ?? sel.start;
    final end = sel.start;

    if (!force && prefix.isEmpty) {
      _hidePopup();
      return;
    }

    final items = <_AcItem>[];
    final up = prefix.toUpperCase();
    final store = context.read<TraceStore>();
    // Source autocomplete from live docs when available; fall back to the
    // hardcoded catalog so completion works on first launch (before the
    // bxp-fmt --docs spawn returns) and when the binary isn't found.
    final fnSrc = store.docFunctions.isNotEmpty
        ? store.docFunctions
              .map(
                (f) => (
                  f['name']?.toString() ?? '',
                  f['signature']?.toString() ?? '',
                  f['description']?.toString() ?? '',
                ),
              )
              .where((e) => e.$1.isNotEmpty)
              .toList()
        : kExprFunctionsFallback
              .map((f) => (f.$1.split('(').first, f.$1, f.$2))
              .toList();
    final kwSrc = store.docKeywords.isNotEmpty
        ? store.docKeywords
              .map(
                (k) => (
                  k['name']?.toString() ?? '',
                  k['description']?.toString() ?? '',
                ),
              )
              .where((e) => e.$1.isNotEmpty)
              .toList()
        : kExprKeywordsFallback;
    for (final f in fnSrc) {
      if (f.$1.toUpperCase().startsWith(up)) {
        items.add(
          _AcItem(
            insert: '${f.$1}(',
            label: f.$2,
            desc: f.$3,
            kind: _AcKind.fn,
          ),
        );
      }
    }
    for (final k in kwSrc) {
      if (k.$1.toUpperCase().startsWith(up)) {
        items.add(
          _AcItem(
            insert: '${k.$1} ',
            label: k.$1,
            desc: k.$2,
            kind: _AcKind.kw,
          ),
        );
      }
    }
    if (items.isEmpty) {
      _hidePopup();
      return;
    }

    _acItems = items;
    if (_acIndex >= items.length) _acIndex = 0;
    _acReplaceStart = start;
    _acReplaceEnd = end;

    if (_popup == null) {
      _popup = OverlayEntry(builder: _buildPopup);
      Overlay.of(context).insert(_popup!);
    } else {
      _popup!.markNeedsBuild();
    }
  }

  void _hidePopup() {
    _popup?.remove();
    _popup = null;
  }

  void _applyAutocomplete(_AcItem item) {
    final text = widget.controller.text;
    final newText = text.replaceRange(
      _acReplaceStart,
      _acReplaceEnd,
      item.insert,
    );
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: _acReplaceStart + item.insert.length,
      ),
    );
    _hidePopup();
  }

  Widget _buildPopup(BuildContext ctx) {
    final t = ctx.bxpTheme;
    return Positioned(
      width: 520,
      child: CompositedTransformFollower(
        link: _editorLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(0, 2),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
              color: t.panelBg,
              border: Border.all(color: t.borderColor),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _acItems.length,
              itemBuilder: (c, i) {
                final it = _acItems[i];
                final selected = i == _acIndex;
                // Selected row expands vertically: label on top, full
                // signature/description below with soft wrap so even long
                // fndoc strings stay legible. Non-selected rows stay
                // single-line (label only) so the popup can list more
                // items at a glance.
                return InkWell(
                  onTap: () => _applyAutocomplete(it),
                  child: Container(
                    color: selected ? t.selectionBg : Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            it.kind == _AcKind.fn ? 'fn' : 'kw',
                            style: BxpText.body(
                              ctx,
                              color: it.kind == _AcKind.fn
                                  ? t.codeFunction
                                  : t.codeKeyword,
                              sizePx: 9,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                it.label,
                                overflow: TextOverflow.ellipsis,
                                style: BxpText.body(
                                  context,
                                  color: selected
                                      ? t.textPrimary
                                      : t.textSubtle,
                                  size: BxpSize.sm,
                                  weight: selected
                                      ? BxpWeight.semiBold
                                      : BxpWeight.regular,
                                ),
                              ),
                              if (selected && it.desc.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  it.desc,
                                  softWrap: true,
                                  style: BxpText.body(
                                    ctx,
                                    color: t.textMuted,
                                    size: BxpSize.xs,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return CompositedTransformTarget(
      link: _editorLink,
      child: Container(
        decoration: BoxDecoration(
          color: t.surfaceBg,
          border: Border.all(
            color: widget.hasError ? t.errorBorder : t.borderColor,
          ),
          borderRadius: BorderRadius.circular(2),
        ),
        child: TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          autofocus: false,
          maxLines: null,
          minLines: widget.minLines,
          style: BxpText.body(context, color: t.textPrimary, sizePx: 13),
          cursorColor: t.accentHighlight,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.all(12),
            border: InputBorder.none,
            isDense: true,
          ),
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          onEditingComplete: widget.onEditingComplete,
          onTapOutside: widget.onTapOutside,
        ),
      ),
    );
  }
}

// ── Autocomplete item types ─────────────────────────────────────────────────

enum _AcKind { fn, kw }

class _AcItem {
  final String insert;
  final String label;
  final String desc;
  final _AcKind kind;
  const _AcItem({
    required this.insert,
    required this.label,
    required this.desc,
    required this.kind,
  });
}

// ── Static fallback catalog ─────────────────────────────────────────────────
//
// Used only until `bxp-fmt --docs` returns (or when the binary is missing).
// Mirrors the hand-written list that historically lived in expr_panel.dart;
// kept public so the DocsPanel can share the same fallback strings.

const kExprFunctionsFallback = [
  (
    'IF(cond, yes, no)',
    "Short-circuit conditional. Returns 'yes' if 'cond' is truthy, else 'no'.",
  ),
  ('ABS(f)', 'Absolute numeric value.'),
  ('NOW()', 'Current UTC datetime as ISO 8601 string (YYYY-MM-DDTHH:MM:SSZ).'),
  ('TRIM(f)', 'Strip leading and trailing whitespace from a string.'),
  ('ROUND(f, n)', "Round 'f' to 'n' decimal places."),
  ('FLOOR(f)', "Round 'f' down to nearest integer."),
  ('CEILING(f)', "Round 'f' up to nearest integer."),
  ('RAND()', 'Random float in [0, 1).'),
  (
    'COALESCE(a, b, ...)',
    'First non-empty argument. Returns last argument verbatim as fallback.',
  ),
  (
    'DATE_CONVERT(f, from, to)',
    'Reformat a date/time string using sunrise syntax (e.g. %Y-%m-%d).',
  ),
  (
    'PRICE_VALUE(f)',
    'Strip currency symbol from a price string, return the numeric part.',
  ),
  (
    'PRICE_CURRENCY(f)',
    "Extract currency code from a price string (e.g. 'EUR', 'USD').",
  ),
  ('TICKER(f)', "Map field value through the template's ticker_map."),
  ('LOOKUP(key, field)', 'Retrieve a value stored by the pre_pass table.'),
  (
    'SPLIT_PART(s, delim, n)',
    "Return the n-th part of 's' split by 'delim' (1-based index).",
  ),
  (
    'CONTAINS(haystack, needle)',
    "Returns 'true' if 'haystack' contains 'needle', else 'false'.",
  ),
  (
    'REPLACE(s, from, to)',
    "Replace all occurrences of 'from' in 's' with 'to'.",
  ),
  (
    'FIELDS(n)',
    'Field value by 1-based column index (alternative to [ColumnName]).',
  ),
];

const kExprKeywordsFallback = [
  (
    'AND',
    'Logical AND. Both operands are evaluated. Returns "true" or "false".',
  ),
  ('OR', 'Logical OR. Both operands are evaluated. Returns "true" or "false".'),
];
