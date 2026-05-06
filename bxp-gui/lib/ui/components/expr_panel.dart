import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_highlight.dart';
import 'expr_playground.dart';

class ExprPanel extends StatefulWidget {
  const ExprPanel({super.key});

  @override
  State<ExprPanel> createState() => _ExprPanelState();
}

class _ExprPanelState extends State<ExprPanel> {
  final _controller = ExprTextEditingController();
  final _focusNode = FocusNode();
  final _editorLink = LayerLink();
  int _lastGen = -1;

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
    _controller.addListener(_onEdit);
    _focusNode.addListener(_onFocusChange);
    _focusNode.onKeyEvent = _onKeyEvent;
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
    final text = _controller.text;
    final sel = _controller.selection;
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
        : _functions.map((f) => (f.$1.split('(').first, f.$1, f.$2)).toList();
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
        : _keywords;
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
    final text = _controller.text;
    final newText = text.replaceRange(
      _acReplaceStart,
      _acReplaceEnd,
      item.insert,
    );
    _controller.value = TextEditingValue(
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
      width: 320,
      child: CompositedTransformFollower(
        link: _editorLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(0, 2),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 220),
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
                return InkWell(
                  onTap: () => _applyAutocomplete(it),
                  child: Container(
                    color: selected ? t.selectionBg : Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Text(
                          it.kind == _AcKind.fn ? 'fn' : 'kw',
                          style: BxpText.body(
                            ctx,
                            color: it.kind == _AcKind.fn
                                ? t.codeFunction
                                : t.codeKeyword,
                            sizePx: 9,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            it.label,
                            overflow: TextOverflow.ellipsis,
                            style: BxpText.body(
                              context,
                              color: selected ? t.textPrimary : t.textSubtle,
                              size: BxpSize.sm,
                              weight: selected
                                  ? BxpWeight.semiBold
                                  : BxpWeight.regular,
                            ),
                          ),
                        ),
                        if (selected)
                          Expanded(
                            flex: 2,
                            child: Text(
                              it.desc,
                              overflow: TextOverflow.ellipsis,
                              style: BxpText.body(
                                ctx,
                                color: t.textMuted,
                                size: BxpSize.xs,
                              ),
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
    _hidePopup();
    _controller.removeListener(_onEdit);
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ExprPlayground(),
          Expanded(
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
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: dividerColor)),
          ),
          child: _buildEditor(context, store, dividerColor),
        ),
        const Expanded(child: _DocsPanel()),
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
        // Breadcrumb row
        Row(
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
            _ValidationBadgeSlot(state: store.exprValidationState),
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
        const SizedBox(height: 8),

        // Editor box — wrapped in CompositedTransformTarget so the
        // autocomplete overlay can anchor its floating popup to the
        // editor's bottom-left corner via `_editorLink`.
        CompositedTransformTarget(
          link: _editorLink,
          child: Container(
            decoration: BoxDecoration(
              color: t.surfaceBg,
              border: Border.all(
                color: store.exprValidationError == null
                    ? dividerColor
                    : t.errorBorder,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: false,
              maxLines: null,
              minLines: 4,
              style: BxpText.body(context, color: t.textPrimary, sizePx: 13),
              cursorColor: t.accentHighlight,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.all(12),
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: (text) {
                store.updateSelectedExprText(text);
              },
              onSubmitted: (_) => _commit(store),
              onEditingComplete: () => _commit(store),
              onTapOutside: (_) => _commit(store),
            ),
          ),
        ),

        // Error message
        if (store.exprValidationError != null) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: t.errorBg),
            child: Text(
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
            TextButton(
              onPressed: () {
                _controller.text = store.selectedExprText;
                store.updateSelectedExprText(store.selectedExprText);
              },
              child: Text(
                'Reset',
                style: BxpText.body(
                  context,
                  color: t.textMuted,
                  size: BxpSize.sm,
                ),
              ),
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: t.accentHighlight,
                foregroundColor: t.brightness == Brightness.dark
                    ? Colors.white
                    : Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: store.exprValidationError == null
                  ? () => _commit(store)
                  : null,
              child: Text(
                'Apply',
                style: BxpText.body(context, size: BxpSize.sm),
              ),
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
    final fns = store.docFunctions.isNotEmpty
        ? store.docFunctions
              .map(
                (f) => (
                  f['signature']?.toString() ?? f['name']?.toString() ?? '',
                  f['description']?.toString() ?? '',
                ),
              )
              .toList()
        : _functions;
    final kws = store.docKeywords.isNotEmpty
        ? store.docKeywords
              .map(
                (k) => (
                  k['name']?.toString() ?? '',
                  k['description']?.toString() ?? '',
                ),
              )
              .toList()
        : _keywords;
    final ops = store.docOperators.isNotEmpty
        ? store.docOperators
              .map(
                (o) => (
                  o['token']?.toString() ?? '',
                  o['description']?.toString() ?? '',
                ),
              )
              .toList()
        : _operators;
    // SYNTAX section: docs payload supplies (syntax, description, kind);
    // we map kind → theme-aware color so the swatch matches the inline
    // highlighter (light/dark themes paint completely different
    // palettes). Static fallback `_syntaxStatic` is parallel data
    // shape — kind names mirror what bxp-fmt emits.
    final syntax = store.docTokens.isNotEmpty
        ? store.docTokens
              .map(
                (tok) => (
                  tok['syntax']?.toString() ?? '',
                  tok['description']?.toString() ?? '',
                  _syntaxColorFor(tok['kind']?.toString() ?? '', t),
                ),
              )
              .toList()
        : _syntaxStatic
              .map((e) => (e.$1, e.$2, _syntaxColorFor(e.$3, t)))
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
              ],
            ),
          ),
        ),
      ],
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

// ── Static docs data ────────────────────────────────────────────────────────

const _functions = [
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

const _keywords = [
  (
    'AND',
    'Logical AND. Both operands are evaluated. Returns "true" or "false".',
  ),
  ('OR', 'Logical OR. Both operands are evaluated. Returns "true" or "false".'),
];

const _operators = [
  ('&', 'String concatenation: "Hello" & " " & "World"'),
  ('=', 'Equality comparison. Returns "true" or "false".'),
  ('!=', 'Inequality comparison.'),
  ('<', 'Less-than comparison (numeric or lexicographic).'),
  ('>', 'Greater-than comparison.'),
  ('<=', 'Less-than-or-equal comparison.'),
  ('>=', 'Greater-than-or-equal comparison.'),
  ('+', 'Numeric addition.'),
  ('-', 'Numeric subtraction.'),
  ('*', 'Numeric multiplication.'),
  ('/', 'Numeric division.'),
];

// Static fallback for the SYNTAX docs section. Stored as
// (syntax, description, kind) so colour resolution flows through
// `_syntaxColorFor` and stays theme-aware (matching the live docs
// payload's shape).
const _syntaxStatic = [
  (
    '[ColumnName]',
    'Input CSV column value by header name. Case-sensitive.',
    'columnRef',
  ),
  (
    r'$variable',
    r'Named variable declared in input_schema. Must start with $.',
    'inputVar',
  ),
  (
    "'single quoted'",
    "String literal. Escape with \\' for embedded quote.",
    'string',
  ),
  (
    '123 / 3.14',
    'Numeric literal. American thousands separators (1,234.56) parsed automatically.',
    'number',
  ),
  ('FUNCNAME(...)', 'Built-in function call. See functions list.', 'function'),
  ('AND / OR', 'Logical keyword operators.', 'keyword'),
];

/// Constant-width slot for the 4-state validation badge in the
/// breadcrumb row. The label changes ("valid"/"invalid"/"checking"/—)
/// have different rendered widths; without a fixed envelope the
/// surrounding breadcrumb path and ✕ button hop a few pixels with
/// each state transition, which looks like a glitch.
///
/// Width was sized to fit the longest label ("checking" at 10 px).
class _ValidationBadgeSlot extends StatelessWidget {
  final ExprValidationState state;
  const _ValidationBadgeSlot({required this.state});

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
