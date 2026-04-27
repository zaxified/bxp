import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_highlight.dart';

class JsonTree extends StatefulWidget {
  final dynamic json;
  final bool expandAll;
  final bool readOnly;

  const JsonTree({super.key, required this.json, this.expandAll = false, this.readOnly = false});

  @override
  State<JsonTree> createState() => _JsonTreeState();
}

class _JsonTreeState extends State<JsonTree> {
  @override
  Widget build(BuildContext context) {
    return _JsonNode(
      keyName: 'config',
      value: widget.json,
      expandAll: widget.expandAll,
      depth: 0,
      path: const [],
    );
  }
}

class _JsonNode extends StatefulWidget {
  final String? keyName;
  final dynamic value;
  final bool expandAll;
  final int depth;
  final List<String> path;

  /// Comments with `placement: "trailing"` that the parent attached to this
  /// node so they render inline (after the value, before the action buttons)
  /// instead of on their own row. Pre-pass logic lives in [_buildMap] /
  /// [_buildList]; comments without a preceding real key still render as
  /// standalone rows via the `\$comm_` branch in [build].
  final List<String> trailingComments;

  const _JsonNode({
    this.keyName,
    this.value,
    required this.expandAll,
    required this.depth,
    required this.path,
    this.trailingComments = const [],
  });

  @override
  State<_JsonNode> createState() => _JsonNodeState();
}

class _JsonNodeState extends State<_JsonNode> {
  late bool expanded;
  bool isHovered = false;

  @override
  void initState() {
    super.initState();
    // Default expansion goes one level deeper than before (was depth<1):
    // for a typical bxp-cli config the user lands on the inside of each
    // template (data_dir, file_pattern_in, …) without an extra click.
    expanded = widget.expandAll || widget.depth < 2;
  }

  @override
  void didUpdateWidget(covariant _JsonNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandAll != widget.expandAll) {
      expanded = widget.expandAll || widget.depth < 3;
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyName = widget.keyName;

    final t = context.bxpTheme;

    // Comments
    if (keyName != null && keyName.startsWith('\$comm_')) {
      final obj = widget.value;
      final text = (obj is Map && obj['text'] is String) ? obj['text'] as String : '';
      return Padding(
        padding: const EdgeInsets.only(left: 24.0, top: 2, bottom: 2),
        child: Text(
          text,
          style: BxpText.body(context,color: t.codeComment, size: BxpSize.md)
              .copyWith(fontStyle: FontStyle.italic),
        ),
      );
    }

    // Errors
    if (keyName != null && keyName.startsWith('\$err_')) {
      return Padding(
        padding: const EdgeInsets.only(left: 24.0, top: 2, bottom: 2),
        child: Container(
          decoration: BoxDecoration(
            color: t.errorBg,
            border: Border(left: BorderSide(color: t.errorBorder, width: 2)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Text(
            widget.value?.toString() ?? '',
            style: BxpText.body(context,color: t.errorText, size: BxpSize.xs)
                .copyWith(fontStyle: FontStyle.italic),
          ),
        ),
      );
    }

    if (widget.value is Map) {
      return _buildMap(widget.value as Map);
    } else if (widget.value is List) {
      return _buildList(widget.value as List);
    } else {
      return _buildPrimitive();
    }
  }

  Widget _buildMap(Map map) {
    final t = context.bxpTheme;
    if (map.isEmpty) {
      return _buildRow(Text('(empty object)', style: BxpText.italic(context)));
    }
    final children = _mapChildNodes(map);
    // Count "real" children (skip $meta_/$elem_meta_/$meta_self/$err_/$comm_).
    final realCount = map.keys
        .where((k) => !k.toString().startsWith(r'$'))
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildExpandableRow('{ $realCount }', true),
        if (expanded)
          Container(
            margin: const EdgeInsets.only(left: 6.0),
            padding: const EdgeInsets.only(left: 16.0),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: t.borderColor)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
      ],
    );
  }

  /// Pre-pass over a map's entries: trailing-placement `$comm_<N>` siblings
  /// attach to the preceding real key so they render inline. Other comment
  /// entries (leading / standalone / block) and all real keys keep their
  /// own rows; `$meta_<key>`, `$elem_meta_<key>`, `$meta_self` carry byte
  /// offsets for OpApply and are not displayed in the tree.
  List<Widget> _mapChildNodes(Map map) {
    final out = <Widget>[];
    int? lastRealIdx;
    for (final e in map.entries) {
      final k = e.key.toString();
      if (k.startsWith(r'$meta_') ||
          k.startsWith(r'$elem_meta_') ||
          k == r'$meta_self') {
        continue;
      }
      if (k.startsWith(r'$comm_')) {
        final v = e.value;
        final placement = (v is Map) ? v['placement']?.toString() : null;
        final text = (v is Map && v['text'] is String) ? v['text'] as String : '';
        if (placement == 'trailing' && lastRealIdx != null) {
          // Re-emit the previous node with this comment appended inline.
          final prev = out[lastRealIdx] as _JsonNode;
          out[lastRealIdx] = _JsonNode(
            keyName: prev.keyName,
            value: prev.value,
            expandAll: prev.expandAll,
            depth: prev.depth,
            path: prev.path,
            trailingComments: [...prev.trailingComments, text],
          );
          continue;
        }
        // Leading / standalone / block — render as its own row.
        out.add(_JsonNode(
          keyName: k,
          value: v,
          expandAll: widget.expandAll,
          depth: widget.depth + 1,
          path: [...widget.path, k],
        ));
        continue;
      }
      out.add(_JsonNode(
        keyName: k,
        value: e.value,
        expandAll: widget.expandAll,
        depth: widget.depth + 1,
        path: [...widget.path, k],
      ));
      lastRealIdx = out.length - 1;
    }
    return out;
  }

  Widget _buildList(List list) {
    final t = context.bxpTheme;
    if (list.isEmpty) {
      return _buildRow(Text('(empty array)', style: BxpText.italic(context)));
    }
    final children = _listChildNodes(list);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildExpandableRow('[ ${list.length} ]', true),
        if (expanded)
          Container(
            margin: const EdgeInsets.only(left: 6.0),
            padding: const EdgeInsets.only(left: 16.0),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: t.borderColor)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
      ],
    );
  }

  /// In-array comments live as single-key `{$comm_<N>: {text, placement}}`
  /// pseudo-objects between real elements. Trailing-placement comments
  /// inline onto the preceding real element; the rest render as their own
  /// rows.
  List<Widget> _listChildNodes(List list) {
    final out = <Widget>[];
    int? lastRealIdx;
    for (int i = 0; i < list.length; i++) {
      final v = list[i];
      if (v is Map && v.length == 1) {
        final k0 = v.keys.first.toString();
        if (k0.startsWith(r'$comm_')) {
          final inner = v.values.first;
          final placement = (inner is Map) ? inner['placement']?.toString() : null;
          final text = (inner is Map && inner['text'] is String) ? inner['text'] as String : '';
          if (placement == 'trailing' && lastRealIdx != null) {
            final prev = out[lastRealIdx] as _JsonNode;
            out[lastRealIdx] = _JsonNode(
              keyName: prev.keyName,
              value: prev.value,
              expandAll: prev.expandAll,
              depth: prev.depth,
              path: prev.path,
              trailingComments: [...prev.trailingComments, text],
            );
            continue;
          }
          out.add(_JsonNode(
            keyName: k0,
            value: inner,
            expandAll: widget.expandAll,
            depth: widget.depth + 1,
            path: [...widget.path, k0],
          ));
          continue;
        }
        if (k0.startsWith(r'$err_')) {
          out.add(_JsonNode(
            keyName: k0,
            value: v.values.first,
            expandAll: widget.expandAll,
            depth: widget.depth + 1,
            path: [...widget.path, k0],
          ));
          continue;
        }
      }
      out.add(_JsonNode(
        keyName: i.toString(),
        value: v,
        expandAll: widget.expandAll,
        depth: widget.depth + 1,
        path: [...widget.path, i.toString()],
      ));
      lastRealIdx = out.length - 1;
    }
    return out;
  }

  // Detects whether this path is a BXP expression leaf.
  // Mirrors isExprPath() from ConfigTree.tsx.
  bool get _isExprPath {
    final p = widget.path;
    if (p.length < 4) return false;
    if (p[0] != 'conversion_templates') return false;
    final section = p[2];
    if (section == 'input_schema') return p.length == 4;
    // output_schema values are just variable names (e.g. '$var'), not expressions.
    if (section == 'row_rules') {
      if (p.length == 5 && p[4] == 'when') return true;
      if (p.length == 7 && p[4] == 'rows' && int.tryParse(p[5]) != null) return true;
    }
    if (section == 'pre_pass') {
      if (p.length == 4 && (p[3] == 'when' || p[3] == 'key')) return true;
      if (p.length == 5 && p[3] == 'values') return true;
    }
    return false;
  }

  Widget _buildPrimitive() {
    final t = context.bxpTheme;
    Widget valWidget;
    final isComment = widget.keyName?.startsWith('//') == true;

    if (widget.value is String) {
      if (_isExprPath) {
        valWidget = _ExprLeaf(
          text: widget.value as String,
          path: widget.path,
        );
      } else {
        valWidget = _EditableString(
          value: widget.value,
          color: isComment ? t.codeComment : t.codeString,
          onCommit: (val) {
            context.read<TraceStore>().editConfigNode(widget.path, val);
          },
        );
      }
    } else if (widget.value is num) {
      valWidget = _EditableNumber(
        value: widget.value,
        color: isComment ? t.codeComment : t.codeNumber,
        onCommit: (val) {
          context.read<TraceStore>().editConfigNode(widget.path, val);
        },
      );
    } else if (widget.value is bool) {
      valWidget = _EditableBoolean(
        value: widget.value,
        color: isComment ? t.codeComment : t.valueBool,
        onCommit: (val) {
          context.read<TraceStore>().editConfigNode(widget.path, val);
        },
      );
    } else {
      valWidget = Text('null',
          style: BxpText.body(context,color: t.textMuted, size: BxpSize.md)
              .copyWith(fontStyle: FontStyle.italic));
    }

    return _buildRow(valWidget);
  }

  Widget _buildRow(Widget valueWidget) {
    final t = context.bxpTheme;
    final muted = BxpText.body(context,color: t.textMuted, size: BxpSize.md);
    return MouseRegion(
      onEnter: (_) => setState(() => isHovered = true),
      onExit: (_) => setState(() => isHovered = false),
      child: Container(
        color: isHovered ? t.withHover(t.surfaceBg) : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 2.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 16),
            if (widget.keyName != null && int.tryParse(widget.keyName!)?.toString() != widget.keyName) ...[
              Text('${widget.keyName}',
                  style: BxpText.body(context,
                      color: widget.keyName!.startsWith('//')
                          ? t.codeComment
                          : t.codeVariable,
                      size: BxpSize.md,
                      fontStyle: widget.keyName!.startsWith('//')
                          ? FontStyle.italic
                          : FontStyle.normal)),
              Text(' : ',
                  style: BxpText.body(context,color: t.borderColor, size: BxpSize.md)),
            ] else if (widget.keyName != null) ...[
              Text('[${widget.keyName}]', style: muted),
              Text(' : ', style: muted),
            ],
            valueWidget,
            ..._inlineTrailingWidgets(),
            const SizedBox(width: 40),
            Opacity(
              opacity: isHovered ? 1.0 : 0.0,
              child: _buildActionButtons(isComposite: false),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _inlineTrailingWidgets() {
    if (widget.trailingComments.isEmpty) return const [];
    final t = context.bxpTheme;
    final style = BxpText.body(context, color: t.codeComment, size: BxpSize.sm)
        .copyWith(fontStyle: FontStyle.italic);
    return [
      for (final c in widget.trailingComments)
        Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: Text(c, style: style),
        ),
    ];
  }

  Widget _buildExpandableRow(String summary, bool isComposite) {
    final t = context.bxpTheme;
    final muted = BxpText.body(context,color: t.textMuted, size: BxpSize.md);
    return MouseRegion(
      onEnter: (_) => setState(() => isHovered = true),
      onExit: (_) => setState(() => isHovered = false),
      child: InkWell(
        onTap: () => setState(() => expanded = !expanded),
        child: Container(
          color: isHovered ? t.withHover(t.surfaceBg) : Colors.transparent,
          padding: const EdgeInsets.symmetric(vertical: 2.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 16,
                child: Center(
                  child: Text(expanded ? '▾' : '▸', style: muted),
                ),
              ),
              if (widget.keyName != null && int.tryParse(widget.keyName!)?.toString() != widget.keyName) ...[
                _SchemaTooltipKey(
                  keyName: widget.keyName!,
                  path: widget.path,
                ),
                Text(' : ', style: muted),
              ] else if (widget.keyName != null) ...[
                Text('[${widget.keyName}]', style: muted),
                Text(' : ', style: muted),
              ],
              Text(summary, style: muted),
              if (isComposite && _hasDescendantError(widget.value))
                Padding(
                  padding: const EdgeInsets.only(left: 6.0),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: t.errorBorder,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ..._inlineTrailingWidgets(),
              // 5-char gap before the action buttons so they don't crowd
              // the value/summary text.
              const SizedBox(width: 40),
              if (widget.keyName != 'config')
                Opacity(
                  opacity: isHovered ? 1.0 : 0.0,
                  child: _buildActionButtons(isComposite: true),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons({bool isComposite = false}) {
    final store = context.read<TraceStore>();
    final t = context.bxpTheme;
    final isArrayEntry = widget.path.isNotEmpty &&
        int.tryParse(widget.path.last) != null;

    return SizedBox(
      height: 16,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isArrayEntry) ...[
            _ActionBtn(
              icon: '↑',
              tooltip: 'Move up',
              color: t.textMuted,
              onTap: () => store.moveConfigNode(widget.path, -1),
            ),
            _ActionBtn(
              icon: '↓',
              tooltip: 'Move down',
              color: t.textMuted,
              onTap: () => store.moveConfigNode(widget.path, 1),
            ),
          ],
          if (isComposite)
            _ActionBtn(
              icon: '+',
              tooltip: 'Add child',
              color: t.textMuted,
              onTap: () => _showAddDialog(),
            ),
          _ActionBtn(
            icon: '⧉',
            tooltip: 'Duplicate',
            color: t.textMuted,
            onTap: () => store.duplicateConfigNode(widget.path),
          ),
          _ActionBtn(
            icon: '×',
            tooltip: 'Delete',
            color: t.errorText,
            onTap: () => store.deleteConfigNode(widget.path),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// Recursively scans [node] for any `$err_*` key. Sibling `$comm_*`
  /// nodes are skipped during recursion to avoid mistaking a comment
  /// containing the literal text "$err_" for an actual diagnostic.
  bool _hasDescendantError(dynamic node) {
    if (node is Map) {
      for (final e in node.entries) {
        final k = e.key.toString();
        if (k.startsWith(r'$err_')) return true;
      }
      for (final e in node.entries) {
        final k = e.key.toString();
        if (k.startsWith(r'$')) continue; // skip ALL $-prefixed UI metadata
        if (_hasDescendantError(e.value)) return true;
      }
      return false;
    }
    if (node is List) {
      for (final v in node) {
        if (_hasDescendantError(v)) return true;
      }
    }
    return false;
  }

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _AddChildDialog(
        isMap: widget.value is Map,
        onConfirm: (key, value) {
          context.read<TraceStore>().insertConfigNode(widget.path, key, value);
        },
      ),
    );
  }
}

// ── Action button helper ────────────────────────────────────────────
class _ActionBtn extends StatelessWidget {
  final String icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  const _ActionBtn({required this.icon, required this.tooltip, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          child: Text(icon,
              style: BxpText.body(context,
                  color: color, sizePx: 13, height: 1.0)),
        ),
      ),
    );
  }
}

// ── Dialog pro přidání nového uzlu ─────────────────────────────────
class _AddChildDialog extends StatefulWidget {
  final bool isMap;
  final void Function(String? key, dynamic value) onConfirm;

  const _AddChildDialog({required this.isMap, required this.onConfirm});

  @override
  State<_AddChildDialog> createState() => _AddChildDialogState();
}

class _AddChildDialogState extends State<_AddChildDialog> {
  final _keyController = TextEditingController();
  String _type = 'string';
  String? _error;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  dynamic _defaultValue() {
    switch (_type) {
      case 'string': return '';
      case 'number': return 0;
      case 'boolean': return false;
      case 'object': return <String, dynamic>{};
      case 'array': return <dynamic>[];
      default: return '';
    }
  }

  void _confirm() {
    final key = widget.isMap ? _keyController.text.trim() : null;
    if (widget.isMap && (key == null || key.isEmpty)) {
      // Surface the failure instead of silently ignoring the click —
      // mirrors bxp-ui's "Key name cannot be empty" red banner.
      setState(() => _error = 'Key name cannot be empty');
      return;
    }
    widget.onConfirm(key, _defaultValue());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final th = context.bxpTheme;
    final borderColor = th.borderColor;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _confirm,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _confirm,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: th.dialogBg,
          shape: RoundedRectangleBorder(
              side: BorderSide(color: borderColor),
              borderRadius: BorderRadius.zero),
          child: SizedBox(
            width: 360,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Add entry to ${widget.isMap ? 'object' : 'array'}',
                      style: BxpText.title(context)),
                  const SizedBox(height: 12),
                  if (widget.isMap) ...[
                    Text('Key',
                        style: BxpText.body(context,
                            color: th.textMuted, size: BxpSize.sm)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _keyController,
                      autofocus: true,
                      onChanged: (_) {
                        if (_error != null) setState(() => _error = null);
                      },
                      onSubmitted: (_) => _confirm(),
                      style:
                          BxpText.body(context,color: th.codeVariable, size: BxpSize.md),
                      cursorColor: th.accentHighlight,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'new_key',
                        hintStyle: BxpText.body(context,
                            color: th.inputPlaceholder, size: BxpSize.md),
                        border: OutlineInputBorder(
                            borderSide: BorderSide(color: th.inputBorder)),
                        enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: th.inputBorder)),
                        focusedBorder: OutlineInputBorder(
                            borderSide:
                                BorderSide(color: th.inputBorderFocused)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text('Type',
                      style: BxpText.body(context,
                          color: th.textMuted, size: BxpSize.sm)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: ['string', 'number', 'boolean', 'object', 'array']
                        .map((typ) {
                      final sel = _type == typ;
                      return InkWell(
                        onTap: () => setState(() => _type = typ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: sel
                                    ? th.accentHighlight
                                    : borderColor),
                            color: sel ? th.selectionBg : Colors.transparent,
                          ),
                          child: Text(typ,
                              style: BxpText.body(context,
                                  color: sel
                                      ? th.selectionText
                                      : th.textMuted,
                                  size: BxpSize.sm)),
                        ),
                      );
                    }).toList(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: BxpText.body(context,color: th.errorText, size: BxpSize.sm)),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text('Cancel',
                            style: BxpText.body(context, color: th.textMuted)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: th.accentHighlight,
                            foregroundColor: Colors.white),
                        onPressed: _confirm,
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Expression leaf – kliknutím otevře ExprPanel ───────────────────────────
class _ExprLeaf extends StatelessWidget {
  final String text;
  final List<String> path;

  const _ExprLeaf({required this.text, required this.path});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final isActive = store.selectedExprPath != null &&
        _listEq(store.selectedExprPath!, path);
    // Show red underline on the selected leaf when bxp-fmt reports an
    // error for its current text. Non-selected leaves never get marked —
    // validating every expression on load would require one spawn per leaf.
    final showError = isActive && store.exprValidationError != null;

    return Tooltip(
      message: 'click to edit in panel',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
      onTap: () => context.read<TraceStore>().setSelectedExpr(path, text),
      child: Builder(builder: (ctx) {
        final t = ctx.bxpTheme;
        final quoteStyle = BxpText.body(context,color: t.textMuted, size: BxpSize.md);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: isActive ? t.selectionBg : null,
            border: isActive ? Border.all(color: t.borderColor) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('"', style: quoteStyle),
              Container(
                decoration: showError
                    ? BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                              color: t.errorBorder,
                              width: 1.5,
                              style: BorderStyle.solid),
                        ),
                      )
                    : null,
                child: ExprHighlight(text: text, size: BxpSize.md),
              ),
              Text('"', style: quoteStyle),
            ],
          ),
        );
      }),
        ),
      ),
    );
  }

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _EditableString extends StatefulWidget {

  final String value;
  final Color color;
  final ValueChanged<String> onCommit;

  const _EditableString({required this.value, required this.color, required this.onCommit});

  @override
  State<_EditableString> createState() => _EditableStringState();
}

class _EditableStringState extends State<_EditableString> {
  bool isEditing = false;
  late TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value);
  }

  void _commit() {
    setState(() => isEditing = false);
    if (controller.text != widget.value) {
      widget.onCommit(controller.text);
    }
  }

  /// Discard pending edits and leave edit mode without firing onCommit.
  /// Mirrors bxp-ui's EditableString Escape handler.
  void _cancel() {
    controller.text = widget.value;
    setState(() => isEditing = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    if (!isEditing) {
      return InkWell(
        onTap: () {
          setState(() {
            isEditing = true;
            controller.text = widget.value;
          });
        },
        child: Text('"${widget.value}"',
            style: BxpText.body(context,color: widget.color, size: BxpSize.md)),
      );
    }

    return SizedBox(
      height: 20,
      width: 150,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        },
        child: TextField(
          controller: controller,
          autofocus: true,
          style: BxpText.body(context,color: widget.color, size: BxpSize.md),
          cursorColor: t.accentHighlight,
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            border: OutlineInputBorder(
                borderSide: BorderSide(color: t.inputBorder)),
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: t.inputBorder)),
            focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: t.inputBorderFocused)),
          ),
          onSubmitted: (_) => _commit(),
          onTapOutside: (_) => _commit(),
        ),
      ),
    );
  }
}

class _EditableNumber extends StatefulWidget {
  final num value;
  final Color color;
  final ValueChanged<num> onCommit;

  const _EditableNumber({required this.value, required this.color, required this.onCommit});

  @override
  State<_EditableNumber> createState() => _EditableNumberState();
}

class _EditableNumberState extends State<_EditableNumber> {
  bool isEditing = false;
  late TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value.toString());
  }

  void _commit() {
    setState(() => isEditing = false);
    final n = num.tryParse(controller.text);
    if (n != null && n != widget.value) {
      widget.onCommit(n);
    } else {
      controller.text = widget.value.toString();
    }
  }

  /// Discard pending edits and leave edit mode without firing onCommit.
  /// Mirrors bxp-ui's EditableNumber Escape handler.
  void _cancel() {
    controller.text = widget.value.toString();
    setState(() => isEditing = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    if (!isEditing) {
      return InkWell(
        onTap: () {
          setState(() {
            isEditing = true;
            controller.text = widget.value.toString();
          });
        },
        child: Text('${widget.value}',
            style: BxpText.body(context,color: widget.color, size: BxpSize.md)),
      );
    }

    return SizedBox(
      height: 20,
      width: 100,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        },
        child: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: BxpText.body(context,color: widget.color, size: BxpSize.md),
          cursorColor: t.accentHighlight,
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            border: OutlineInputBorder(
                borderSide: BorderSide(color: t.inputBorder)),
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: t.inputBorder)),
            focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: t.inputBorderFocused)),
          ),
          onSubmitted: (_) => _commit(),
          onTapOutside: (_) => _commit(),
        ),
      ),
    );
  }
}

class _EditableBoolean extends StatelessWidget {
  final bool value;
  final Color color;
  final ValueChanged<bool> onCommit;

  const _EditableBoolean({required this.value, required this.color, required this.onCommit});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'click to toggle',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          onTap: () => onCommit(!value),
          child: Text('$value',
              style: BxpText.body(context,color: color, size: BxpSize.md)),
        ),
      ),
    );
  }
}

/// Renders a config-tree key label with an optional schema-doc tooltip.
///
/// Looks the path up against `bxp-fmt --docs` config_schema (with `*`
/// wildcards). When a description exists, the label gets a dotted
/// underline + help cursor and a hover tooltip — matches bxp-ui's
/// LabelSpan + findSchemaDoc behaviour. When no doc is found (or docs
/// haven't loaded yet), the label renders unchanged.
class _SchemaTooltipKey extends StatelessWidget {
  final String keyName;
  final List<String> path;
  const _SchemaTooltipKey({required this.keyName, required this.path});

  static bool _matches(String pattern, List<String> p) {
    final segs = pattern.split('.');
    if (segs.length != p.length) return false;
    for (int i = 0; i < segs.length; i++) {
      if (segs[i] == '*') continue;
      if (segs[i] != p[i]) return false;
    }
    return true;
  }

  Map<String, dynamic>? _findDoc(List<Map<String, dynamic>> schema) {
    for (final f in schema) {
      final k = f['key']?.toString() ?? '';
      if (_matches(k, path)) return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final isComment = keyName.startsWith('//');
    final color = isComment ? t.codeComment : t.codeVariable;
    final style = BxpText.body(context,color: color, size: BxpSize.md).copyWith(
      fontStyle: isComment ? FontStyle.italic : FontStyle.normal,
    );

    if (isComment || path.isEmpty) {
      return Text(keyName, style: style);
    }

    final store = context.watch<TraceStore>();
    final doc = _findDoc(store.docConfigSchema);
    if (doc == null) return Text(keyName, style: style);

    final type = doc['type_name']?.toString() ?? '';
    final required = doc['required'] == true;
    final defaultVal = doc['default']?.toString();
    final desc = doc['description']?.toString() ?? '';

    final headerParts = <String>[
      if (type.isNotEmpty) type,
      if (required) 'required',
      if (defaultVal != null && defaultVal != 'null') 'default: $defaultVal',
    ];
    final tooltipMsg =
        headerParts.isEmpty ? desc : '${headerParts.join(' · ')}\n\n$desc';

    return Tooltip(
      message: tooltipMsg,
      waitDuration: const Duration(milliseconds: 300),
      preferBelow: true,
      textStyle: BxpText.body(context,color: t.textPrimary, size: BxpSize.sm),
      decoration: BoxDecoration(
        color: t.dialogBg,
        border: Border.all(color: t.borderColor),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.help,
        child: Text(
          keyName,
          style: style.copyWith(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
            decorationColor: t.textMuted,
          ),
        ),
      ),
    );
  }
}
