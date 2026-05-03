import 'dart:async';

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
  /// Optional caller-owned focus node. When supplied, the caller can
  /// `requestFocus()` programmatically (used by ExprPanel to focus the
  /// editor after the user clicks an expr leaf in the tree). When null,
  /// the editor falls back to its own internal node.
  final FocusNode? focusNode;
  /// When true, the underlying TextField fills the parent's available
  /// height and scrolls its content internally — used inside a fixed
  /// Expanded slot (ExprPanel / ExprPlayground) so newlines don't push
  /// the surrounding buttons out of view. Requires a bounded-height
  /// parent. When false (default), TextField sizes to its content using
  /// `minLines` as the floor.
  final bool expands;
  /// Fires `true` when the autocomplete popup transitions to visible
  /// and `false` when it hides. Callers use this to pause expensive
  /// per-keystroke side-effects (validation spawns) while the user is
  /// picking from the popup — see `TraceStore.setExprAutocompleteOpen`.
  final ValueChanged<bool>? onAutocompleteVisibilityChanged;

  const ExprEditor({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTapOutside,
    this.hasError = false,
    this.minLines = 4,
    this.focusNode,
    this.expands = false,
    this.onAutocompleteVisibilityChanged,
  });

  @override
  State<ExprEditor> createState() => _ExprEditorState();
}

class _ExprEditorState extends State<ExprEditor> {
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
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
  /// Debouncer for the typing-driven autocomplete refresh. Lifted to
  /// 500 ms (matching the bxp-fmt validation cadence) so the popup
  /// rebuild + docs filter pass don't run on every keystroke — the
  /// previous immediate refresh produced the noticeable typing lag in
  /// the editor. Ctrl+Space and selection-driven hides bypass the
  /// debounce so the user gets immediate feedback when explicitly
  /// asking for completions.
  Timer? _acDebounce;

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
    _acDebounce?.cancel();
    _hidePopup();
    widget.controller.removeListener(_onEdit);
    _focusNode.removeListener(_onFocusChange);
    // If we attached our key handler to a parent-owned focus node, detach
    // it — otherwise the parent reuses the FocusNode and our (now-dead)
    // _onKeyEvent fires on the next key press, calling into a torn-down
    // state.
    if (widget.focusNode != null) _focusNode.onKeyEvent = null;
    if (widget.focusNode == null) _focusNode.dispose();
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

  void _onEdit() {
    // Debounce so the docs-list scan + overlay rebuild don't fire on
    // every keystroke. 500 ms matches the validation debounce —
    // popup pops up only when the user pauses, not while they're
    // mid-type. Ctrl+Space (`force: true`) bypasses the debounce in
    // `_onKeyEvent` for instant on-demand completion.
    _acDebounce?.cancel();
    _acDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _refreshAutocomplete();
    });
  }

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
    // Live docs are guaranteed populated by the startup gate (see
    // _StartupGate in main.dart) — bxp-fmt --docs is the only catalog.
    final fnSrc = store.docFunctions
        .map(
          (f) => (
            f['name']?.toString() ?? '',
            f['signature']?.toString() ?? '',
            f['description']?.toString() ?? '',
          ),
        )
        .where((e) => e.$1.isNotEmpty)
        .toList();
    final kwSrc = store.docKeywords
        .map(
          (k) => (
            k['name']?.toString() ?? '',
            k['description']?.toString() ?? '',
          ),
        )
        .where((e) => e.$1.isNotEmpty)
        .toList();
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
      widget.onAutocompleteVisibilityChanged?.call(true);
    } else {
      _popup!.markNeedsBuild();
    }
  }

  void _hidePopup() {
    if (_popup == null) return;
    _popup?.remove();
    _popup = null;
    widget.onAutocompleteVisibilityChanged?.call(false);
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

  /// Pixel offset of the cursor inside the editor's content area, so the
  /// autocomplete popup can anchor at the caret position rather than at
  /// the editor's bottom-left corner. Measured by laying out a
  /// [TextPainter] over the prefix `controller.text[0..selection.start]`
  /// using the same font metrics the TextField uses (see `build()`).
  /// Adds `contentPadding` (12) and one line-height so the popup sits
  /// just below the line the cursor is on, mirroring CodeMirror's hint
  /// menu behaviour.
  Offset _caretOffsetInEditor(BuildContext ctx) {
    final controller = widget.controller;
    final sel = controller.selection;
    if (!sel.isValid) return const Offset(12, 12);
    final ts = ctx.read<TraceStore>().textScheme;
    final style = TextStyle(
      fontFamily: ts.fontFamily,
      fontFamilyFallback: ts.fontFamilyFallback,
      fontSize: 13,
      letterSpacing: ts.trackBody,
    );
    final textBefore = controller.text.substring(0, sel.start);
    final tp = TextPainter(
      text: TextSpan(text: textBefore, style: style),
      textDirection: TextDirection.ltr,
      textWidthBasis: TextWidthBasis.longestLine,
    );
    tp.layout();
    final caret = tp.getOffsetForCaret(
      TextPosition(offset: textBefore.length),
      Rect.zero,
    );
    // contentPadding 12 (see TextField below) + ~1 line-height so the
    // popup hangs just below the active line. fontSize 13 × ~1.4 = 18.
    const lineH = 18.0;
    return Offset(12 + caret.dx, 12 + caret.dy + lineH);
  }

  Widget _buildPopup(BuildContext ctx) {
    final t = ctx.bxpTheme;
    final caretOffset = _caretOffsetInEditor(ctx);
    return Positioned(
      width: 520,
      child: CompositedTransformFollower(
        link: _editorLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        offset: caretOffset,
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
          minLines: widget.expands ? null : widget.minLines,
          expands: widget.expands,
          textAlignVertical: TextAlignVertical.top,
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

