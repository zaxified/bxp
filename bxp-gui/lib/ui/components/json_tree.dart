import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:json5_ast/ast.dart';
import 'package:json5_ast/path.dart' as ast_path;
import 'package:provider/provider.dart';
import '../../services/dart_validator.dart';
import '../../services/debug_settings.dart';
import '../../services/dev_trace.dart';
import '../../services/schema_doc_lookup.dart';
import '../../services/schema_gate.dart';
import '../../store/trace_store.dart';
import '../layout_defaults.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';
import 'expr_highlight.dart';

/// Phase 5c-C3: walks the live AST (`TraceStore.astRoot`) directly.
/// `$err_*` diagnostic markers are looked up via `TraceStore.errorsAt` /
/// `TraceStore.hasErrorIn` at render time — they live in `configJson`
/// (still maintained as a Map by the adapter) until Phase 5c-D folds
/// them into a dedicated path-keyed structure.
class JsonTree extends StatefulWidget {
  final JsonAstNode? root;
  final bool expandAll;
  final bool readOnly;
  /// Minimum width forced on every row so per-row trailing action buttons
  /// can right-align against the same X column near the vertical
  /// scrollbar — without it, rows take only their intrinsic width and
  /// the buttons hop horizontally with each row's content length. Null
  /// means "no min-width constraint" (legacy/embedded use).
  final double? rowMinWidth;

  const JsonTree(
      {super.key,
      required this.root,
      this.expandAll = false,
      this.readOnly = false,
      this.rowMinWidth});

  @override
  State<JsonTree> createState() => _JsonTreeState();
}

class _JsonTreeState extends State<JsonTree> {
  @override
  Widget build(BuildContext context) {
    final root = widget.root;
    if (root == null) return const SizedBox.shrink();
    // Compute global $comm_<N> numbering once per build; pass down.
    final numbering = ast_path.globalCommentNumbering(root);
    return _RowMinWidth(
      width: widget.rowMinWidth,
      child: _JsonNode(
        keyName: 'config',
        value: root,
        expandAll: widget.expandAll,
        depth: 0,
        path: const [],
        commentN: numbering,
      ),
    );
  }
}

/// Threads the viewport-derived min-width to every descendant row.
class _RowMinWidth extends InheritedWidget {
  final double? width;
  const _RowMinWidth({required this.width, required super.child});
  static double? of(BuildContext ctx) {
    final i = ctx.dependOnInheritedWidgetOfExactType<_RowMinWidth>();
    return i?.width;
  }
  @override
  bool updateShouldNotify(_RowMinWidth old) => old.width != width;
}

/// Sticky action toolbox controller. `_RowEnvelope` publishes its own
/// trailing-actions widget + Y position (in the tree's overlay Stack
/// coord space) whenever the row enters its hovered/visible state, and
/// clears the entry on exit. A single overlay above the horizontal
/// `SingleChildScrollView` reads this controller and renders the
/// currently-published actions pinned to the tree pane's right edge —
/// the row content still scrolls horizontally underneath it.
class TreeActionsController extends ChangeNotifier {
  Object? _ownerId;
  Widget? _actions;
  double? _y;

  Object? get ownerId => _ownerId;
  Widget? get actions => _actions;
  double? get y => _y;

  void publish(Object id, Widget actions, double y) {
    if (_ownerId == id && identical(_actions, actions) && _y == y) return;
    _ownerId = id;
    _actions = actions;
    _y = y;
    notifyListeners();
  }

  /// Idempotent — only clears when `id` matches the current owner so a
  /// late `onExit` after a sibling's `onEnter` doesn't wipe the new
  /// owner's payload.
  void clear(Object id) {
    if (_ownerId != id) return;
    _ownerId = null;
    _actions = null;
    _y = null;
    notifyListeners();
  }
}

/// Provides the per-tree [TreeActionsController] and the
/// `RenderObject`-anchor [GlobalKey] of the overlay `Stack` to deeply
/// nested rows. Rows look it up non-dependently (via
/// `getInheritedWidgetOfExactType`) so they don't rebuild on controller
/// notifications — they only call `publish` / `clear`.
class TreeActionsBinding extends InheritedWidget {
  final TreeActionsController controller;
  final GlobalKey stackKey;
  const TreeActionsBinding({
    super.key,
    required this.controller,
    required this.stackKey,
    required super.child,
  });

  static TreeActionsBinding? maybeOf(BuildContext c) =>
      c.getInheritedWidgetOfExactType<TreeActionsBinding>();

  /// Synchronously publishes a row's action toolbox. **Call from a
  /// pointer-event handler** (`MouseRegion.onEnter`), NOT from `build`
  /// / `didUpdateWidget`: the underlying `notifyListeners` would mark
  /// the overlay's `ListenableBuilder` dirty mid-build and trip
  /// Flutter's "markNeedsBuild during build" assertion. Returns `false`
  /// when the row's `RenderBox` isn't laid out yet — in practice this
  /// only happens on the very first build of a row that mounts already
  /// under the cursor.
  static bool publishFromRow(
    BuildContext context,
    GlobalKey rowKey,
    Object id,
    Widget actions,
  ) {
    final binding = maybeOf(context);
    if (binding == null) return false;
    final rowBox = rowKey.currentContext?.findRenderObject() as RenderBox?;
    final stackBox =
        binding.stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (rowBox == null || stackBox == null) return false;
    if (!rowBox.attached || !stackBox.attached) return false;
    if (!rowBox.hasSize) return false;
    final offset = rowBox.localToGlobal(Offset.zero, ancestor: stackBox);
    binding.controller.publish(id, actions, offset.dy);
    return true;
  }

  static void clearFromRow(BuildContext context, Object id) {
    maybeOf(context)?.controller.clear(id);
  }

  @override
  bool updateShouldNotify(TreeActionsBinding old) =>
      controller != old.controller || stackKey != old.stackKey;
}

/// Trailing comment payload threaded from parent into [_JsonNode] so the
/// inline `// foo` rendering can wire its own commit path back to the
/// store without re-walking the tree.
class _TrailingComment {
  final List<String> path;
  final CommentNode comment;
  const _TrailingComment({required this.path, required this.comment});
}

class _JsonNode extends StatefulWidget {
  final String? keyName;
  final JsonAstNode? value;
  final bool expandAll;
  final int depth;
  final List<String> path;

  /// Identity-keyed map from each [CommentLine] in the whole tree to its
  /// 1-based source-order `$comm_<N>` index. Computed once at the root and
  /// threaded through every child so comment-row click handlers can build
  /// op_log paths without re-walking the tree per render.
  final Map<CommentLine, int> commentN;

  /// Comments with `inlinePlacement: true` that the parent attached to this
  /// node so they render inline (after the value, before the action buttons)
  /// instead of on their own row.
  final List<_TrailingComment> trailingComments;

  const _JsonNode({
    this.keyName,
    this.value,
    required this.expandAll,
    required this.depth,
    required this.path,
    required this.commentN,
    this.trailingComments = const [],
  });

  @override
  State<_JsonNode> createState() => _JsonNodeState();
}

class _JsonNodeState extends State<_JsonNode> {
  late bool expanded;
  bool isHovered = false;
  /// Anchor the row Container's `RenderBox` so `TreeActionsBinding`
  /// can sample the row's Y in the overlay Stack's coord space.
  /// Shared across the leaf / expandable render paths — only one is
  /// active at any given time.
  final GlobalKey _rowKey = GlobalKey();
  /// Stable identity for `TreeActionsController.publish` / `clear` so
  /// a late `onExit` after a sibling's `onEnter` is a no-op.
  final Object _actionId = Object();
  /// Cached controller ref so `dispose()` can clear our overlay slot
  /// without a context lookup — during unmount the element is no
  /// longer active and the inherited-widget asserts would fire.
  TreeActionsController? _actionsCtrl;
  /// True between an expand-click and a collapse-click. When set, child
  /// nodes are constructed with `expandAll: true` so a single click on a
  /// collapsed parent cascades down to every descendant. Reset on collapse
  /// (children then snap back to depth-based default — this is intentional
  /// so re-expanding a parent recurses freshly instead of restoring stale
  /// per-child expansion state).
  bool _recursiveExpand = false;

  /// True when the active `selectedExprPath` lives somewhere inside this
  /// node's subtree. Used by `_buildMap`/`_buildList` to render this node
  /// expanded even if the user collapsed it manually — so click-to-jump
  /// from the row-detail tables can reveal a deeply nested expression.
  /// Recomputed every build via `context.watch<TraceStore>()`.
  bool _isOnRevealPath(BuildContext ctx) {
    final selected = ctx.watch<TraceStore>().selectedExprPath;
    if (selected == null) return false;
    if (selected.length <= widget.path.length) return false;
    for (int i = 0; i < widget.path.length; i++) {
      if (selected[i] != widget.path[i]) return false;
    }
    return true;
  }

  /// Cached TraceStore ref captured on first build so we can detach the
  /// pendingAddChild listener during dispose without an InheritedWidget
  /// lookup (which is forbidden once the element starts unmounting).
  TraceStore? _storeRef;

  /// True while the user is renaming this row's Map key via inline
  /// TextField. Double-click on the key chip flips it on; commit or
  /// cancel flips it off. Only meaningful when the parent is a Map.
  bool _renamingKey = false;
  TextEditingController? _renameController;
  FocusNode? _renameFocus;
  String? _renameError;

  @override
  void initState() {
    super.initState();
    // Default expansion goes one level deeper than before (was depth<1):
    // for a typical bxp-cli config the user lands on the inside of each
    // template (data_dir, file_pattern_in, …) without an extra click.
    expanded = widget.expandAll || widget.depth < 2;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _actionsCtrl = TreeActionsBinding.maybeOf(context)?.controller;
    // Subscribe to the Ctrl+Shift+Insert request channel. When the
    // shortcut fires in main_view with this node's path, pop the
    // Add-Child dialog from here — the dialog needs `widget.value`
    // (the parent JsonObject) and `_showAddDialog`'s local schema
    // walk, which only this State can supply.
    final store = context.read<TraceStore>();
    if (!identical(_storeRef, store)) {
      _storeRef?.pendingAddChildPath.removeListener(_onAddChildPending);
      _storeRef = store;
      store.pendingAddChildPath.addListener(_onAddChildPending);
    }
  }

  void _onAddChildPending() {
    final store = _storeRef;
    if (store == null || !mounted) return;
    final pending = store.pendingAddChildPath.value;
    if (pending == null || pending.length != widget.path.length) return;
    for (var i = 0; i < widget.path.length; i++) {
      if (pending[i] != widget.path[i]) return;
    }
    // Guard scalar leaves: Add-Child only makes sense for object/array
    // containers. Silently drop the request so a stray Ctrl+Shift+Insert
    // on a `$ticker: ""` cell doesn't pop a malformed dialog.
    final v = widget.value;
    if (v is! JsonObject && v is! JsonArray) {
      store.clearPendingAddChild();
      return;
    }
    // Consume the request so other matching nodes (none should exist —
    // path identity is unique — but defensively) don't also pop a dialog.
    store.clearPendingAddChild();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showAddDialog();
    });
  }

  @override
  void dispose() {
    // Defer the toolbox clear past `BuildOwner.finalizeTree`: clear
    // notifies the overlay's `ListenableBuilder`, and setState while
    // the tree is unmount-locked tripped the framework. Post-frame
    // runs in the idle phase where setState is legal. Owner-id gated
    // inside `clear`, so a sibling row that took ownership in the
    // meantime won't have its slot wiped.
    final ctrl = _actionsCtrl;
    final id = _actionId;
    if (ctrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.clear(id));
    }
    _storeRef?.pendingAddChildPath.removeListener(_onAddChildPending);
    _renameController?.dispose();
    _renameFocus?.dispose();
    super.dispose();
  }

  /// Switch this row into rename-key edit mode. Pre-fills the controller
  /// with the current key and selects all so the user can immediately
  /// overtype or amend.
  void _enterRenameKey() {
    if (widget.keyName == null) return;
    if (widget.path.isEmpty) return;
    _renameController?.dispose();
    _renameFocus?.dispose();
    _renameController = TextEditingController(text: widget.keyName);
    _renameController!.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.keyName!.length,
    );
    _renameFocus = FocusNode();
    setState(() {
      _renamingKey = true;
      _renameError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _renameFocus?.requestFocus();
    });
  }

  /// Commit the rename if validation passes. Duplicate keys among
  /// siblings and empty input are rejected inline (red error text); the
  /// validator catches semantic problems (e.g. dangling references) on
  /// the next Validate run, mirroring the permissive policy the plan
  /// settled on.
  void _commitRenameKey() {
    final c = _renameController;
    if (c == null) return;
    final newKey = c.text.trim();
    if (newKey.isEmpty) {
      setState(() => _renameError = 'Key must not be empty');
      return;
    }
    if (newKey == widget.keyName) {
      _cancelRenameKey();
      return;
    }
    final store = context.read<TraceStore>();
    final parentPath = widget.path.sublist(0, widget.path.length - 1);
    final parent = store.astAtPublic(parentPath);
    if (parent is JsonObject) {
      for (final p in parent.properties.whereType<JsonProperty>()) {
        if (p.key == newKey) {
          setState(() => _renameError =
              "Key '$newKey' already exists in this object");
          return;
        }
      }
    }
    store.renameConfigKey(widget.path, newKey);
    setState(() {
      _renamingKey = false;
      _renameError = null;
    });
  }

  void _cancelRenameKey() {
    setState(() {
      _renamingKey = false;
      _renameError = null;
    });
  }

  /// Inline TextField swapped in for the key chip while [_renamingKey]
  /// is true. Enter commits, Escape cancels, focus loss commits (the
  /// user clicking away from the row reads as "I'm done"). Sized to
  /// match the average key width so the row doesn't reflow on toggle.
  Widget _buildRenameField(BxpTheme t) {
    final hasError = _renameError != null;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 280),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): _commitRenameKey,
          const SingleActivator(LogicalKeyboardKey.numpadEnter):
              _commitRenameKey,
          const SingleActivator(LogicalKeyboardKey.escape): _cancelRenameKey,
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _renameController,
              focusNode: _renameFocus,
              autofocus: true,
              onSubmitted: (_) => _commitRenameKey(),
              onTapOutside: (_) => _commitRenameKey(),
              onChanged: (_) {
                if (_renameError != null) {
                  setState(() => _renameError = null);
                }
              },
              style: BxpText.body(context,
                  color: t.codeVariable, size: BxpSize.md),
              cursorColor: t.accentHighlight,
              decoration: InputDecoration(
                isDense: true,
                border: OutlineInputBorder(
                    borderSide:
                        BorderSide(color: hasError ? t.errorBorder : t.inputBorder)),
                enabledBorder: OutlineInputBorder(
                    borderSide:
                        BorderSide(color: hasError ? t.errorBorder : t.inputBorder)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                        color: hasError ? t.errorBorder : t.inputBorderFocused)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 4),
              ),
            ),
            if (hasError)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  _renameError!,
                  style: BxpText.body(context,
                      color: t.errorText, size: BxpSize.xs),
                ),
              ),
          ],
        ),
      ),
    );
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
    final v = widget.value;
    if (v is JsonObject) return _buildMap(v);
    if (v is JsonArray) return _buildList(v);
    return _buildPrimitive();
  }

  Widget _buildMap(JsonObject obj) {
    final t = context.bxpTheme;
    final realCount =
        obj.properties.whereType<JsonProperty>().length;
    final children = _mapChildNodes(obj);
    final showChildren = expanded || _isOnRevealPath(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildExpandableRow('{ $realCount }', true),
        if (showChildren)
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

  /// Walk a JsonObject's properties in source order. Each [JsonProperty]
  /// becomes a `_JsonNode` row; each [CommentLine] becomes either an
  /// inline trailing tag on the previous row (when `inlinePlacement` is
  /// true) or a standalone `_CommentRow`. After the row is built, any
  /// `$err_*` markers that the validator attached to the row's path
  /// follow as red banner widgets — looked up via TraceStore so the AST
  /// itself stays unburdened by diagnostic state.
  List<Widget> _mapChildNodes(JsonObject obj) {
    final out = <Widget>[];
    int? lastRowIdx;
    // Index of the first entry in the "trailing block" — the suffix of
    // the container that contains only comments (no more JsonProperty
    // entries follow). Standalone comments inside the trailing block
    // render with the deeper indent (the user manually parked them at
    // the end of the object); standalone comments BEFORE it lead a real
    // sibling and align with that sibling.
    int firstTrailingIdx = obj.properties.length;
    for (var i = obj.properties.length - 1; i >= 0; i--) {
      if (obj.properties[i] is JsonProperty) {
        firstTrailingIdx = i + 1;
        break;
      }
      if (i == 0) firstTrailingIdx = 0; // container is comments-only
    }
    for (var entryIdx = 0; entryIdx < obj.properties.length; entryIdx++) {
      final entry = obj.properties[entryIdx];
      if (entry is CommentLine) {
        final n = widget.commentN[entry];
        final commKey = n == null ? r'$comm_?' : '\$comm_$n';
        final commPath = [...widget.path, commKey];
        if (entry.inlinePlacement && lastRowIdx != null) {
          // Attach inline to the preceding row by rebuilding its
          // _JsonNode with an added trailing tag.
          final prev = out[lastRowIdx] as _JsonNode;
          out[lastRowIdx] = _JsonNode(
            keyName: prev.keyName,
            value: prev.value,
            expandAll: prev.expandAll || _recursiveExpand,
            depth: prev.depth,
            path: prev.path,
            commentN: prev.commentN,
            trailingComments: [
              ...prev.trailingComments,
              _TrailingComment(path: commPath, comment: entry.comment),
            ],
          );
          continue;
        }
        out.add(_CommentRow(
          path: commPath,
          comment: entry.comment,
          depth: widget.depth + 1,
          deepIndent: entryIdx >= firstTrailingIdx,
        ));
        continue;
      }
      if (entry is JsonProperty) {
        final childPath = [...widget.path, entry.key];
        out.add(_JsonNode(
          keyName: entry.key,
          value: entry.value,
          expandAll: widget.expandAll || _recursiveExpand,
          depth: widget.depth + 1,
          path: childPath,
          commentN: widget.commentN,
        ));
        lastRowIdx = out.length - 1;
        // Surface any validator $err_* / $warn_* / $info_* markers
        // attached to this child. `select` (not `read`) so the row
        // rebuilds the moment the validator's diagnostic maps change —
        // without it, the banner only refreshed when `treeLoadGen`
        // ticked, leaving stale entries showing for live edits between
        // full reloads. Phase 3 — Dart-side `$dart_<N>` entries are
        // merged in alongside bxp-fmt's `$err_<N>` (same bucket, same
        // banner style).
        // Banners use `read` here (not `select`) because the dedup
        // helper consults paths and bucket contents that change in
        // lockstep with the diagnostic maps themselves — every map
        // change goes through `notifyListeners` already, so the
        // outer ConfigView rebuild covers the refresh path. `select`
        // on `errorsAt(childPath)` alone wouldn't notice when a
        // descendant's diagnostic flips and de-dups would go stale.
        final store = context.read<TraceStore>();
        final errors = store.errorsAt(childPath);
        if (errors.isNotEmpty) {
          final filtered = store.dedupBannerMessages(
              childPath, DartSeverity.error, errors.values);
          for (final msg in filtered) {
            out.add(_ErrorRow(message: msg, severity: _DiagSeverity.error));
          }
        }
        final warnings = store.warningsAt(childPath);
        if (warnings.isNotEmpty) {
          final filtered = store.dedupBannerMessages(
              childPath, DartSeverity.warning, warnings.values);
          for (final msg in filtered) {
            out.add(_ErrorRow(message: msg, severity: _DiagSeverity.warning));
          }
        }
        final infos = store.infoAt(childPath);
        if (infos.isNotEmpty) {
          final filtered = store.dedupBannerMessages(
              childPath, DartSeverity.info, infos.values);
          for (final msg in filtered) {
            out.add(_ErrorRow(message: msg, severity: _DiagSeverity.info));
          }
        }
      }
    }
    return out;
  }

  Widget _buildList(JsonArray arr) {
    final t = context.bxpTheme;
    final realCount =
        arr.elements.where((e) => e is! CommentLine).length;
    final children = _listChildNodes(arr);
    final showChildren = expanded || _isOnRevealPath(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildExpandableRow('[ $realCount ]', true),
        if (showChildren)
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

  /// Walk a JsonArray's elements. Path segments are RAW positions in
  /// `elements` (matching the convention enforced by the path resolver);
  /// visible labels stay real-only so `[N]` aligns with the
  /// `rule_index` / `output_row_index` values bxp-cli emits in trace
  /// events.
  List<Widget> _listChildNodes(JsonArray arr) {
    final out = <Widget>[];
    int? lastRowIdx;
    int realLabel = 0;
    // Same trailing-block logic as the map walker — see _mapChildNodes.
    int firstTrailingIdx = arr.elements.length;
    for (var i = arr.elements.length - 1; i >= 0; i--) {
      if (arr.elements[i] is! CommentLine) {
        firstTrailingIdx = i + 1;
        break;
      }
      if (i == 0) firstTrailingIdx = 0;
    }
    for (var i = 0; i < arr.elements.length; i++) {
      final el = arr.elements[i];
      if (el is CommentLine) {
        final n = widget.commentN[el];
        final commKey = n == null ? r'$comm_?' : '\$comm_$n';
        final commPath = [...widget.path, commKey];
        if (el.inlinePlacement && lastRowIdx != null) {
          final prev = out[lastRowIdx] as _JsonNode;
          out[lastRowIdx] = _JsonNode(
            keyName: prev.keyName,
            value: prev.value,
            expandAll: prev.expandAll || _recursiveExpand,
            depth: prev.depth,
            path: prev.path,
            commentN: prev.commentN,
            trailingComments: [
              ...prev.trailingComments,
              _TrailingComment(path: commPath, comment: el.comment),
            ],
          );
          continue;
        }
        out.add(_CommentRow(
          path: commPath,
          comment: el.comment,
          depth: widget.depth + 1,
          deepIndent: i >= firstTrailingIdx,
        ));
        continue;
      }
      final childPath = [...widget.path, i.toString()];
      out.add(_JsonNode(
        keyName: realLabel.toString(),
        value: el,
        expandAll: widget.expandAll || _recursiveExpand,
        depth: widget.depth + 1,
        path: childPath,
        commentN: widget.commentN,
      ));
      lastRowIdx = out.length - 1;
      realLabel++;
      // Same dedup-aware banner render as the map walker. Errors,
      // warnings, infos all surface here; descendant duplicates are
      // suppressed by `dedupBannerMessages`.
      final store = context.read<TraceStore>();
      final errors = store.errorsAt(childPath);
      if (errors.isNotEmpty) {
        for (final msg in store.dedupBannerMessages(
            childPath, DartSeverity.error, errors.values)) {
          out.add(_ErrorRow(message: msg, severity: _DiagSeverity.error));
        }
      }
      final warnings = store.warningsAt(childPath);
      if (warnings.isNotEmpty) {
        for (final msg in store.dedupBannerMessages(
            childPath, DartSeverity.warning, warnings.values)) {
          out.add(_ErrorRow(message: msg, severity: _DiagSeverity.warning));
        }
      }
      final infos = store.infoAt(childPath);
      if (infos.isNotEmpty) {
        for (final msg in store.dedupBannerMessages(
            childPath, DartSeverity.info, infos.values)) {
          out.add(_ErrorRow(message: msg, severity: _DiagSeverity.info));
        }
      }
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
      // Legacy: conversion_templates.<id>.pre_pass.when      (path len 4)
      // Legacy: conversion_templates.<id>.pre_pass.values.<f>(path len 5)
      // New:    conversion_templates.<id>.pre_pass.<name>.when      (path len 5)
      // New:    conversion_templates.<id>.pre_pass.<name>.values.<f>(path len 6)
      if (p.length == 4 && (p[3] == 'when' || p[3] == 'key')) return true;
      if (p.length == 5 && p[3] == 'values') return true;
      if (p.length == 5 && (p[4] == 'when' || p[4] == 'key')) return true;
      if (p.length == 6 && p[4] == 'values') return true;
    }
    return false;
  }

  Widget _buildPrimitive() {
    final t = context.bxpTheme;
    Widget valWidget;
    final v = widget.value;

    if (v is JsonString) {
      if (_isExprPath) {
        valWidget = _ExprLeaf(
          text: v.value,
          path: widget.path,
        );
      } else {
        // Schema-driven enum: when the field has a fixed set of values
        // (e.g. csv_text_quote_in: "none"|"single"|"double"), swap the free
        // TextField for a dropdown so invalid values cannot be entered.
        final doc = context.read<TraceStore>().findSchemaDoc(widget.path);
        final enumValues = (doc?['enum_values'] as List?)?.cast<String>();
        if (enumValues != null && enumValues.isNotEmpty) {
          valWidget = _EditableEnum(
            value: v.value,
            values: enumValues,
            color: t.codeString,
            onCommit: (val) {
              context.read<TraceStore>().editConfigNode(widget.path, val);
            },
          );
        } else {
          valWidget = _EditableString(
            value: v.value,
            color: t.codeString,
            path: widget.path,
            onCommit: (val) {
              context.read<TraceStore>().editConfigNode(widget.path, val);
            },
          );
        }
      }
    } else if (v is JsonNumber) {
      final parsed = num.tryParse(v.rawText) ?? 0;
      valWidget = _EditableNumber(
        value: parsed,
        color: t.codeNumber,
        path: widget.path,
        onCommit: (val) {
          context.read<TraceStore>().editConfigNode(widget.path, val);
        },
      );
    } else if (v is JsonBool) {
      valWidget = _EditableBoolean(
        value: v.value,
        color: t.valueBool,
        onCommit: (val) {
          context.read<TraceStore>().editConfigNode(widget.path, val);
        },
      );
    } else {
      valWidget = Text('null',
          style: BxpText.body(context, color: t.textMuted, size: BxpSize.md)
              .copyWith(fontStyle: FontStyle.italic));
    }

    return _buildRow(valWidget);
  }

  Widget _buildRow(Widget valueWidget) {
    final t = context.bxpTheme;
    final muted = BxpText.body(context,color: t.textMuted, size: BxpSize.md);
    // Hover wiring is gated by DebugSettings so the diagnostic panel
    // can flip it live. When `hoverBackground` is OFF, no MouseRegion
    // / setState — the row is purely static (no rebuild cascade per
    // hover). `hoverActionButtons` controls whether the trailing
    // buttons subtree is mounted at all — when hidden via Opacity
    // they remain a ~500-listener pointer-event sink (~100 rows ×
    // ~4 buttons each).
    final debug = context.watch<DebugSettings>();
    final inner = Container(
      key: _rowKey,
      color: (debug.hoverBackground && isHovered)
          ? t.withHover(t.surfaceBg)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: _RowEnvelope(
        depth: widget.depth,
        children: [
          const SizedBox(width: 16),
          if (widget.keyName != null && int.tryParse(widget.keyName!)?.toString() != widget.keyName) ...[
            _SchemaTooltipKey(keyName: widget.keyName!, path: widget.path),
            Text(' : ',
                style: BxpText.body(context,color: t.borderColor, size: BxpSize.md)),
          ] else if (widget.keyName != null) ...[
            Text('[${widget.keyName}]', style: muted),
            Text(' : ', style: muted),
          ],
          valueWidget,
          ..._inlineTrailingWidgets(),
        ],
      ),
    );
    if (!debug.hoverBackground && !debug.hoverActionButtons) {
      // No state cares about hover — skip the MouseRegion entirely so
      // we don't add a pointer-event subscriber per row.
      return inner;
    }
    return MouseRegion(
      onEnter: (_) {
        if (debug.hoverActionButtons) {
          TreeActionsBinding.publishFromRow(context, _rowKey, _actionId,
              _buildActionButtons(isComposite: false));
        }
        setState(() => isHovered = true);
      },
      onExit: (_) {
        TreeActionsBinding.clearFromRow(context, _actionId);
        setState(() => isHovered = false);
      },
      child: inner,
    );
  }

  List<Widget> _inlineTrailingWidgets() {
    if (widget.trailingComments.isEmpty) return const [];
    return [
      for (final c in widget.trailingComments)
        Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: _InlineCommentEdit(path: c.path, comment: c.comment),
        ),
    ];
  }

  Widget _buildExpandableRow(String summary, bool isComposite) {
    final t = context.bxpTheme;
    final muted = BxpText.body(context,color: t.textMuted, size: BxpSize.md);
    final debug = context.watch<DebugSettings>();
    // Keyboard-focus highlight: thin left-border accent when this row is
    // the active target of structural shortcuts. Watching ensures we
    // re-render on focus changes; the path comparison is O(depth) per
    // row but depth is small (config tree rarely exceeds ~6 levels).
    final focusedPath = context.watch<TraceStore>().focusedNodePath;
    final isFocused = focusedPath != null &&
        focusedPath.length == widget.path.length &&
        () {
          for (var i = 0; i < widget.path.length; i++) {
            if (focusedPath[i] != widget.path[i]) return false;
          }
          return true;
        }();
    // Tap target — Material `InkWell` (with internal MouseRegion +
    // AnimationController + ripple) when DebugSettings.useInkWell is
    // ON; lighter-weight `GestureDetector` when OFF. The toggle exists
    // so a future regression can flip away from the heavier widget
    // without touching the call site.
    void onTap() {
      // Mark this row as the keyboard-focused tree node so global
      // shortcuts (Ctrl+Shift+↑/↓/Del/Insert) target it without requiring
      // a separate explicit-focus click. Setting focus on tap matches the
      // mouse user's mental model: "I clicked it, so it's selected."
      context.read<TraceStore>().setFocusedNode(widget.path);
      setState(() {
        expanded = !expanded;
        // Cascade: a single click on a collapsed node expands every
        // descendant. Children read this via the expandAll prop below.
        _recursiveExpand = expanded;
      });
    }
    final inner = Container(
      key: _rowKey,
      decoration: BoxDecoration(
        color: (debug.hoverBackground && isHovered)
            ? t.withHover(t.surfaceBg)
            : Colors.transparent,
        border: isFocused
            ? Border(left: BorderSide(color: t.accentHighlight, width: 2))
            : null,
      ),
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: _RowEnvelope(
        depth: widget.depth,
        children: [
          SizedBox(
            width: 16,
            child: Center(
              child: Text(expanded ? '▾' : '▸', style: muted),
            ),
          ),
          if (widget.keyName != null && int.tryParse(widget.keyName!)?.toString() != widget.keyName) ...[
            if (_renamingKey)
              _buildRenameField(t)
            else
              GestureDetector(
                onDoubleTap: _enterRenameKey,
                behavior: HitTestBehavior.opaque,
                child: _SchemaTooltipKey(
                  keyName: widget.keyName!,
                  path: widget.path,
                ),
              ),
            Text(' : ', style: muted),
          ] else if (widget.keyName != null) ...[
            Text('[${widget.keyName}]', style: muted),
            Text(' : ', style: muted),
          ],
          Text(summary, style: muted),
          if (isComposite &&
              context.read<TraceStore>().hasErrorIn(widget.path))
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
        ],
      ),
    );
    final tappable = debug.useInkWell
        // Disable Material's default hoverColor — the row already
        // paints its own MouseRegion + Container hover background, and
        // the InkWell overlay otherwise double-shaded the tap target
        // (visible as a second darker rectangle bleeding under long
        // keys / values past the viewport edge).
        ? InkWell(onTap: onTap, hoverColor: Colors.transparent, child: inner)
        : GestureDetector(onTap: onTap, child: inner);
    if (!debug.hoverBackground && !debug.hoverActionButtons) {
      return tappable;
    }
    return MouseRegion(
      onEnter: (_) {
        // Root `config` row has no actions — skip publish so the
        // overlay doesn't render an empty toolbox card.
        if (debug.hoverActionButtons && widget.keyName != 'config') {
          TreeActionsBinding.publishFromRow(context, _rowKey, _actionId,
              _buildActionButtons(isComposite: true));
        }
        setState(() => isHovered = true);
      },
      onExit: (_) {
        TreeActionsBinding.clearFromRow(context, _actionId);
        setState(() => isHovered = false);
      },
      child: tappable,
    );
  }

  Widget _buildActionButtons({bool isComposite = false}) {
    final store = context.read<TraceStore>();
    final t = context.bxpTheme;
    final isArrayEntry = widget.path.isNotEmpty &&
        int.tryParse(widget.path.last) != null;

    // Schema-driven gates:
    //   - reorder ↑/↓ for ordered arrays (parent has ordered: true) AND
    //     for map entries whose parent is documented as ordered (e.g.
    //     conversion_templates: bxp-cli runs templates in declaration order).
    //   - delete × disabled for required map keys
    final parentPath = widget.path.isEmpty
        ? const <String>[]
        : widget.path.sublist(0, widget.path.length - 1);
    final parentDoc = store.findSchemaDoc(parentPath);
    bool canReorder = false;
    if (isArrayEntry) {
      // Unknown array doc = allow reorder by default (don't lock the user
      // out of arrays the schema doesn't cover yet).
      canReorder = parentDoc == null || parentDoc['ordered'] == true;
    } else if (widget.path.isNotEmpty) {
      // Map-key reorder is opt-in: only when the parent map is explicitly
      // marked ordered. Maps default to unordered in JSON semantics.
      canReorder = parentDoc != null && parentDoc['ordered'] == true;
    }
    final selfDoc = store.findSchemaDoc(widget.path);
    final isRequired = !isArrayEntry && selfDoc != null && selfDoc['required'] == true;

    // Fixed slot order (left → right): comment-inline, comment-above,
    // add-child, move-up, move-down, duplicate, delete. Conditional
    // buttons render greyed-out (`onTap: null`) instead of being
    // skipped so the toolbox doesn't shift horizontally between rows
    // with different schemas — the rightmost glyph stays at the same
    // X position regardless of which actions are currently legal.
    final isNonRoot = widget.path.isNotEmpty;
    return SizedBox(
      height: 16,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // "comment above" inserts a fresh leading comment immediately
          // above this row; "comment inline" attaches a trailing
          // `// note` to the same source line. Root rows can't host
          // either, so we drop both for the root entry only.
          if (isNonRoot) ...[
            _ActionBtn(
              icon: '✐',
              tooltip: 'Add inline comment',
              color: t.textMuted,
              onTap: () =>
                  store.insertInlineCommentNode(widget.path, '//', ' '),
            ),
            _ActionBtn(
              icon: '✎',
              tooltip: 'Add comment above',
              color: t.textMuted,
              onTap: () => store.insertCommentNode(widget.path, '//', ' '),
            ),
          ],
          _ActionBtn(
            icon: '+',
            tooltip: isComposite
                ? 'Add child'
                : 'Add child — leaf rows can\'t host children',
            // `codeNumber` (active) vs `textMuted` (disabled) —
            // amber/gold sits clearly between the accent-blue move
            // arrows and the error-red delete glyph; the prior
            // `okText` green was visually too close to the accent
            // hue to read as a distinct "create" affordance.
            color: isComposite ? t.codeNumber : t.textMuted,
            onTap: isComposite ? () => _showAddDialog() : null,
          ),
          _ActionBtn(
            icon: '↑',
            tooltip: canReorder
                ? 'Move up'
                : 'Move up — order is not significant here',
            color: canReorder ? t.accentHighlight : t.textMuted,
            onTap: canReorder
                ? () => store.moveConfigNode(widget.path, -1)
                : null,
          ),
          _ActionBtn(
            icon: '↓',
            tooltip: canReorder
                ? 'Move down'
                : 'Move down — order is not significant here',
            color: canReorder ? t.accentHighlight : t.textMuted,
            onTap: canReorder
                ? () => store.moveConfigNode(widget.path, 1)
                : null,
          ),
          _ActionBtn(
            icon: '⎘',
            tooltip: 'Duplicate',
            // Vibrant rose — hard-coded so it stays visibly distinct
            // from `textMuted` (greyed-out) across every preset theme.
            // Theme-driven options collided in at least one theme:
            // `codeNumber` blends with FTX's amber `textMuted`,
            // `okText`/`codeString` greens read as accent-blue
            // neighbours.
            color: t.codeFunction,
            onTap: () => store.duplicateConfigNode(widget.path),
          ),
          _ActionBtn(
            icon: '×',
            tooltip: isRequired ? 'Required key — cannot delete' : 'Delete',
            color: isRequired ? t.textMuted : t.errorText,
            onTap: isRequired ? null : () => store.deleteConfigNode(widget.path),
          ),
        ],
      ),
    );
  }

  void _showAddDialog() {
    final store = context.read<TraceStore>();
    final v = widget.value;
    final isMap = v is JsonObject;
    devTrace('action.addChild.open', {
      'parentPath': widget.path,
      'isMap': isMap,
    });
    // SchemaGate consults FnDocs for valid keys + skips ones already
    // present. We pass the existing top-level property keys so it can do
    // that without re-walking the AST.
    final existing = <String>{
      if (v is JsonObject)
        for (final p in v.properties.whereType<JsonProperty>()) p.key,
    };
    // Phase 5f: for arrays, surface the wildcard child's schema candidate
    // as a single suggestion so its `insert_template` (e.g. row_rules.* →
    // { when, rows }) is visible as a chip and auto-pre-selected.
    final List<InsertKeyCandidate> sugg;
    if (isMap) {
      sugg = SchemaGate(store).validInsertKeys(widget.path, existing);
    } else {
      final wildcards = SchemaGate(store)
          .validInsertKeys(widget.path, const <String>{})
          .where((c) => c.isFreeForm)
          .toList();
      sugg = wildcards;
    }
    showDialog(
      context: context,
      builder: (ctx) => _AddChildDialog(
        isMap: isMap,
        parent: v is JsonObject ? v : null,
        parentPath: widget.path,
        suggestions: sugg,
        onConfirm: (key, value, atIndex) {
          store.insertConfigNode(widget.path, key, value, atIndex: atIndex);
        },
      ),
    );
  }
}

/// Inline diagnostic row rendered beneath a `_JsonNode` whose path
/// carries one or more `$err_*` markers from the background validator.
enum _DiagSeverity { error, warning, info }

class _ErrorRow extends StatelessWidget {
  final String message;
  final _DiagSeverity severity;
  const _ErrorRow({
    required this.message,
    this.severity = _DiagSeverity.error,
  });

  /// Extract a missing-data_dir path from the error message if present.
  /// bxp-core emits `data_dir does not exist: '<absolute path>'` and that
  /// substring is stable enough to pattern-match — `code` isn't carried
  /// on the Dart side today (see `_validationErrors` doc).
  /// Returns null when this row isn't a dir_not_found diagnostic.
  static String? _dirNotFoundPath(String msg) {
    const marker = 'data_dir does not exist: \'';
    final i = msg.indexOf(marker);
    if (i < 0) return null;
    final start = i + marker.length;
    final end = msg.indexOf('\'', start);
    if (end <= start) return null;
    return msg.substring(start, end);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    // Phase 3: warning + info banners reuse the error chrome but pull
    // softer palette tokens. Falls through to error styling for any
    // future severity not in the switch — safe default.
    final (bg, border, fg) = switch (severity) {
      _DiagSeverity.error => (t.errorBg, t.errorBorder, t.errorText),
      _DiagSeverity.warning => (t.warnBg, t.warnBorder, t.warnText),
      _DiagSeverity.info => (t.infoBg, t.infoBorder, t.infoText),
    };
    final missingDir =
        severity == _DiagSeverity.error ? _dirNotFoundPath(message) : null;
    return Padding(
      padding: const EdgeInsets.only(left: 24.0, top: 2, bottom: 2),
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: Border(left: BorderSide(color: border, width: 2)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                message,
                style: BxpText.body(context, color: fg, size: BxpSize.xs)
                    .copyWith(fontStyle: FontStyle.italic),
              ),
            ),
            if (missingDir != null) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: () =>
                    _confirmCreateDir(context, missingDir),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 1),
                  child: Text(
                    'Create directory',
                    style: BxpText.body(context,
                            color: t.accentHighlight, size: BxpSize.xs)
                        .copyWith(
                            decoration: TextDecoration.underline,
                            fontStyle: FontStyle.italic),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Confirmation dialog + filesystem call. Lives on `_ErrorRow` so the
  /// banner's local context anchors the Navigator route. On success,
  /// triggers a Validate re-run so this diagnostic clears.
  Future<void> _confirmCreateDir(
      BuildContext context, String absolutePath) async {
    final store = context.read<TraceStore>();
    final th = context.bxpTheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: th.dialogBg,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: th.borderColor),
          borderRadius: BorderRadius.zero,
        ),
        title: Text('Create directory?', style: BxpText.title(ctx)),
        content: Text(
          "Directory '$absolutePath' does not exist. Create it now?",
          style: BxpText.body(ctx, color: th.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: BxpText.body(ctx, color: th.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: th.accentHighlight,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Directory(absolutePath).create(recursive: true);
    } catch (e) {
      // Surface a tiny snackbar with the OS error so the user knows the
      // attempt didn't silently no-op. Hard failures (permissions, read-
      // only mount) are rare enough not to warrant a richer recovery
      // path; the user can copy the message and resolve manually.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Failed to create directory: $e"),
        ));
      }
      return;
    }
    // Re-run validation so the dir_not_found error disappears.
    if (store.configPath.isNotEmpty) {
      await store.runValidate();
    }
  }
}

/// Editable standalone comment row. Rendered for each non-inline
/// [CommentLine] peer in a container. Inline trailing comments render via
/// `_inlineTrailingWidgets` on the owning row and use [_InlineCommentEdit].
class _CommentRow extends StatefulWidget {
  final List<String> path;
  final CommentNode comment;
  /// `true` when this comment lives in the trailing-block of its container
  /// (no real key follows). Renders with extra left padding to read as a
  /// "container-bottom" annotation. `false` (default) aligns the comment
  /// with the next sibling row — the user wrote it as a label.
  final bool deepIndent;
  /// Tree depth of this row (matches sibling `_JsonNode.depth`). Used by
  /// `_RowEnvelope` to compute the per-row right-edge anchor.
  final int depth;
  const _CommentRow({
    required this.path,
    required this.comment,
    required this.depth,
    this.deepIndent = false,
  });
  @override
  State<_CommentRow> createState() => _CommentRowState();
}

class _CommentRowState extends State<_CommentRow> {
  bool isHovered = false;
  bool isEditing = false;
  late TextEditingController controller;
  final FocusNode _focus = FocusNode();
  /// Anchor the row Container's `RenderBox` so `TreeActionsBinding`
  /// can compute the row's Y in the overlay Stack's coord space.
  final GlobalKey _rowKey = GlobalKey();
  /// Stable identity for `TreeActionsController.publish` / `clear` so
  /// a stale `onExit` after a sibling's `onEnter` is a no-op.
  final Object _actionId = Object();
  /// Cached controller ref so `dispose()` can clear our overlay slot
  /// without doing a `context.getInheritedWidgetOfExactType` lookup —
  /// during unmount the element is no longer active and Flutter's
  /// debug assert "calling dependOnInheritedWidgetOfExactType in
  /// didChangeDependencies" fires.
  TreeActionsController? _actionsCtrl;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.comment.text);
    _focus.addListener(_onFocusChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _actionsCtrl = TreeActionsBinding.maybeOf(context)?.controller;
  }

  @override
  void dispose() {
    // Defer the toolbox clear to the next frame — `clear` notifies the
    // overlay's `ListenableBuilder`, which would call `setState` while
    // `BuildOwner.finalizeTree` has the widget tree locked (we're
    // running inside `_InactiveElements._unmount` right now). The
    // post-frame callback runs in the idle scheduler phase, when
    // setState is legal again.
    final ctrl = _actionsCtrl;
    final id = _actionId;
    if (ctrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.clear(id));
    }
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CommentRow old) {
    super.didUpdateWidget(old);
    if (!isEditing) controller.text = widget.comment.text;
  }

  // Focus-loss commit covers click-outside / tab-out / programmatic
  // defocus uniformly — Flutter's `onTapOutside` misfires when the
  // outside tap lands on widgets that absorb the pointer event before
  // the TextFieldTapRegion sees it (sibling rows in this tree).
  void _onFocusChange() {
    if (!_focus.hasFocus && isEditing) _commit();
  }

  void _enterEdit() {
    final body = widget.comment.text;
    controller.value = TextEditingValue(
      text: body,
      // Select the whole body so the user can immediately retype to
      // replace, or arrow-key out of the selection to position the
      // cursor. Multi-line `TextField`s would otherwise leave the
      // cursor at offset 0; single-line autofocus selects all by
      // platform default — explicit select-all unifies both shapes.
      selection: TextSelection(baseOffset: 0, extentOffset: body.length),
    );
    setState(() => isEditing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _commit() {
    if (!isEditing) return;
    var body = controller.text;
    final isBlock = widget.comment.style == CommentStyle.block;
    if (!isBlock) {
      // Phase 5b: line comments cannot contain newlines — they would
      // terminate the `//` comment in the source. Strip on commit
      // (paste-from-clipboard guard; the inputFormatters block typed
      // newlines but pasted multiline strings sneak through).
      body = body.replaceAll(RegExp(r'[\r\n]+'), ' ');
    }
    setState(() => isEditing = false);
    _focus.unfocus();
    if (body != widget.comment.text) {
      context.read<TraceStore>().editCommentNode(widget.path, body);
    }
  }

  void _cancel() {
    if (!isEditing) return;
    controller.text = widget.comment.text;
    setState(() => isEditing = false);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final store = context.read<TraceStore>();
    final isBlock = widget.comment.style == CommentStyle.block;
    final body = widget.comment.text;

    // Comments are always positionally moveable / duplicable regardless
    // of the surrounding container's `ordered` schema flag — that flag
    // governs real-key semantics, not annotative noise.

    final commentStyle = BxpText.body(context, color: t.codeComment, size: BxpSize.md)
        .copyWith(fontStyle: FontStyle.italic);

    Widget bodyWidget;
    if (isEditing) {
      // Block comments may span multiple lines — give the field room to grow
      // and let Enter insert a newline. Line comments stay single-line; Enter
      // commits.
      bodyWidget = SizedBox(
        width: 600,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _cancel,
            if (!isBlock)
              const SingleActivator(LogicalKeyboardKey.enter): _commit,
          },
          child: TextField(
            controller: controller,
            focusNode: _focus,
            maxLines: isBlock ? null : 1,
            minLines: isBlock ? 1 : 1,
            keyboardType: isBlock ? TextInputType.multiline : TextInputType.text,
            // Phase 5b: line comments must not contain raw newlines.
            // Block them at input — paste-from-clipboard is sanitised on
            // commit (see _commit).
            inputFormatters: isBlock
                ? null
                : [FilteringTextInputFormatter.deny(RegExp(r'[\r\n]'))],
            onSubmitted: isBlock ? null : (_) => _commit(),
            style: BxpText.body(context, color: t.codeComment, size: BxpSize.md),
            cursorColor: t.accentHighlight,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              border: OutlineInputBorder(
                borderSide: BorderSide(color: t.borderColor),
              ),
            ),
          ),
        ),
      );
    } else {
      // No `minWidth` — that used to force a 300 px hit-area for empty
      // comments but bloated the row's intrinsic past the envelope's
      // depth-aware minWidth, which pushed the action slot off the
      // right edge (delete × clipped). Empty placeholder still reads
      // `(click to edit)` (~98 px) which is plenty to click on.
      bodyWidget = InkWell(
        onTap: _enterEdit,
        // Disable Material's default hoverColor — `_CommentRow` already
        // paints a row-level hover background via MouseRegion +
        // Container, and the InkWell overlay double-shaded the text
        // body (visible as a second darker rectangle ~30 px inside the
        // first one when the mouse crossed the body's left edge).
        hoverColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            body.trim().isEmpty ? '(click to edit)' : body,
            style: body.trim().isEmpty
                ? commentStyle.copyWith(color: t.textMuted)
                : commentStyle,
          ),
        ),
      );
    }

    final debug = context.watch<DebugSettings>();
    final inner = Container(
      key: _rowKey,
      color: (debug.hoverBackground && isHovered)
          ? t.withHover(t.surfaceBg)
          : Colors.transparent,
      // Vertical padding only — the leading indent is provided as the
      // first child of the envelope's row so the envelope's right edge
      // still aligns with the scrollbar (`Container.padding.left` would
      // grow the envelope past minWidth, pushing the action slot off
      // the viewport and clipping the trailing × button).
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: _RowEnvelope(
        depth: widget.depth,
        children: [
          SizedBox(width: widget.deepIndent ? 24.0 : 16.0),
          Text(isBlock ? '/*' : '//', style: commentStyle),
          bodyWidget,
          if (isBlock) Text('*/', style: commentStyle),
        ],
      ),
    );
    if (!debug.hoverBackground && !debug.hoverActionButtons) {
      return inner;
    }
    return MouseRegion(
      onEnter: (_) {
        if (debug.hoverActionButtons) {
          TreeActionsBinding.publishFromRow(
              context, _rowKey, _actionId, _buildCommentActions(store, t));
        }
        setState(() => isHovered = true);
      },
      onExit: (_) {
        TreeActionsBinding.clearFromRow(context, _actionId);
        setState(() => isHovered = false);
      },
      child: inner,
    );
  }

  /// Trailing action toolbox for this comment row. Built fresh on each
  /// hover-enter so `widget.path` always reflects the row's current AST
  /// location (the row instance may have been re-keyed by a structural
  /// rebuild while the cursor was over it). Colour scheme mirrors
  /// `_JsonNode._buildActionButtons` — accent-blue for move,
  /// `textMuted` for neutral, error-red for destructive.
  Widget _buildCommentActions(TraceStore store, BxpTheme t) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionBtn(
          icon: '↑',
          tooltip: 'Move up',
          color: t.accentHighlight,
          onTap: () => store.moveConfigNode(widget.path, -1),
        ),
        _ActionBtn(
          icon: '↓',
          tooltip: 'Move down',
          color: t.accentHighlight,
          onTap: () => store.moveConfigNode(widget.path, 1),
        ),
        _ActionBtn(
          icon: '⎘',
          tooltip: 'Duplicate comment',
          // Matches `_buildActionButtons` — hard-coded rose for
          // cross-theme distinguishability from `textMuted` (the
          // greyed-out fallback used elsewhere in the toolbox).
          color: t.codeFunction,
          onTap: () => store.duplicateCommentNode(widget.path),
        ),
        _ActionBtn(
          icon: '×',
          tooltip: 'Delete comment',
          color: t.errorText,
          onTap: () => store.deleteCommentNode(widget.path),
        ),
      ],
    );
  }
}

/// Inline editor for a trailing-placement comment that renders next to the
/// row it follows (e.g. `key: value, // note`). Click to edit; Enter or
/// tap-outside commits; Escape cancels.
class _InlineCommentEdit extends StatefulWidget {
  final List<String> path;
  final CommentNode comment;
  const _InlineCommentEdit({required this.path, required this.comment});
  @override
  State<_InlineCommentEdit> createState() => _InlineCommentEditState();
}

class _InlineCommentEditState extends State<_InlineCommentEdit> {
  bool isEditing = false;
  late TextEditingController controller;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.comment.text);
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _InlineCommentEdit old) {
    super.didUpdateWidget(old);
    if (!isEditing) controller.text = widget.comment.text;
  }

  void _onFocusChange() {
    if (!_focus.hasFocus && isEditing) _commit();
  }

  void _enterEdit() {
    final body = widget.comment.text;
    controller.value = TextEditingValue(
      text: body,
      selection: TextSelection(baseOffset: 0, extentOffset: body.length),
    );
    setState(() => isEditing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _commit() {
    if (!isEditing) return;
    var body = controller.text;
    final isBlock = widget.comment.style == CommentStyle.block;
    if (!isBlock) {
      // Phase 5b: line comment cannot contain newlines.
      body = body.replaceAll(RegExp(r'[\r\n]+'), ' ');
    }
    setState(() => isEditing = false);
    _focus.unfocus();
    // Empty inline comment → delete the comment entirely. An inline
    // `// ` with no body is visual noise on the row it trails; the
    // standalone CommentRow has its own placeholder and this would only
    // appear there as `(click to edit)`.
    if (body.trim().isEmpty) {
      context.read<TraceStore>().deleteCommentNode(widget.path);
      return;
    }
    if (body != widget.comment.text) {
      context.read<TraceStore>().editCommentNode(widget.path, body);
    }
  }

  void _cancel() {
    if (!isEditing) return;
    controller.text = widget.comment.text;
    setState(() => isEditing = false);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final style = BxpText.body(context, color: t.codeComment, size: BxpSize.sm)
        .copyWith(fontStyle: FontStyle.italic);
    final isBlock = widget.comment.style == CommentStyle.block;
    if (!isEditing) {
      final marker = isBlock
          ? '/*${widget.comment.text}*/'
          : '//${widget.comment.text}';
      return InkWell(
        onTap: _enterEdit,
        // See `_CommentRow.bodyWidget` — row-level MouseRegion owns the
        // hover bg; InkWell's default Material hover overlay would
        // paint a second layer that leaks past the SCV clip.
        hoverColor: Colors.transparent,
        child: Text(marker, style: style),
      );
    }
    return SizedBox(
      width: 400,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
          if (!isBlock)
            const SingleActivator(LogicalKeyboardKey.enter): _commit,
        },
        child: TextField(
          controller: controller,
          focusNode: _focus,
          maxLines: isBlock ? null : 1,
          // Phase 5b: line comments must not contain raw newlines.
          inputFormatters: isBlock
              ? null
              : [FilteringTextInputFormatter.deny(RegExp(r'[\r\n]'))],
          onSubmitted: isBlock ? null : (_) => _commit(),
          style: BxpText.body(context, color: t.codeComment, size: BxpSize.sm),
          cursorColor: t.accentHighlight,
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            border: OutlineInputBorder(
              borderSide: BorderSide(color: t.borderColor),
            ),
            prefixText: isBlock ? '/*' : '//',
            suffixText: isBlock ? '*/' : null,
          ),
        ),
      ),
    );
  }
}

// ── Row envelope ────────────────────────────────────────────────────
/// Wraps a tree-row's content in a min-width envelope so the row
/// stretches out to the viewport edge — the sticky action toolbox
/// painted by `_TreeActionsOverlay` then right-aligns against the
/// same X near the scrollbar regardless of the row's own intrinsic
/// content length. Rows wider than the viewport grow past the
/// envelope and scroll horizontally inside the parent SCV; the
/// toolbox stays fixed because it lives outside the horizontal SCV.
///
/// Pure layout — publication / clearing of the toolbox itself is
/// handled by each row's hover handler via
/// [TreeActionsBinding.publishFromRow] / [clearFromRow].
class _RowEnvelope extends StatelessWidget {
  final List<Widget> children;
  /// Depth of the row in the tree (root = 0). Used to subtract the
  /// per-level indent from the inherited viewport-row width so the
  /// envelope's right edge aligns with the scrollbar at every depth.
  final int depth;
  const _RowEnvelope({
    required this.children,
    required this.depth,
  });

  /// Single source of the indent constant lives in
  /// [LayoutDefaults.treeIndentPerLevel].
  static const double _indentPerLevel = LayoutDefaults.treeIndentPerLevel;

  @override
  Widget build(BuildContext context) {
    final viewportRowWidth = _RowMinWidth.of(context);
    if (viewportRowWidth == null || viewportRowWidth <= 0) {
      // No viewport context (e.g. snapshot tree in tests): plain Row.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      );
    }
    final minWidth = (viewportRowWidth - depth * _indentPerLevel)
        .clamp(0.0, double.infinity);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: IntrinsicWidth(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String icon;
  final String tooltip;
  final Color color;
  /// Null = disabled (rendered greyed out, no hover, no click).
  final VoidCallback? onTap;

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
  final List<InsertKeyCandidate> suggestions;
  final void Function(String? key, dynamic value, int? atIndex) onConfirm;

  /// Phase 5f: parent AST node + path used by `SchemaGate.insertIndexFor`
  /// to compute the canonical insertion position. `parent` is null for
  /// list-target inserts (which always append).
  final JsonObject? parent;
  final List<String> parentPath;

  const _AddChildDialog({
    required this.isMap,
    required this.onConfirm,
    required this.parentPath,
    this.parent,
    this.suggestions = const <InsertKeyCandidate>[],
  });

  @override
  State<_AddChildDialog> createState() => _AddChildDialogState();
}

class _AddChildDialogState extends State<_AddChildDialog> {
  static const _uiTypes = ['string', 'number', 'boolean', 'object', 'array'];

  final _keyController = TextEditingController();
  // Held explicitly so `_pickSuggestion` can yank focus back from a chip's
  // InkWell — without it, clicking a chip moves focus to the InkWell and
  // the next Enter press fires the chip's onTap again instead of the
  // dialog's Enter→_confirm shortcut.
  final _keyFocusNode = FocusNode();
  String _type = 'string';
  String? _error;
  InsertKeyCandidate? _pickedSuggestion;

  /// Map a schema `type_name` (which can be "string", "expression",
  /// "string | object", …) to the subset of [_uiTypes] that the user is
  /// allowed to pick. Restricts the type-button row to whatever the
  /// schema accepts under this path.
  List<String> _normalizeTypes(String typeName) {
    final out = <String>[];
    for (final raw in typeName.split('|')) {
      final t = raw.trim();
      // expression is stored as a JSON string; treat it as such for the
      // UI's purpose of picking a value shape.
      final canonical = (t == 'expression') ? 'string' : t;
      if (_uiTypes.contains(canonical) && !out.contains(canonical)) {
        out.add(canonical);
      }
    }
    return out.isEmpty ? const ['string'] : out;
  }

  /// Allowed UI types for the current dialog state. Picked chip wins;
  /// otherwise the wildcard suggestion (if any) constrains choice;
  /// otherwise all five basic types.
  List<String> _allowedTypes() {
    final picked = _pickedSuggestion;
    if (picked != null) return _normalizeTypes(picked.typeName);
    for (final s in widget.suggestions) {
      if (s.isFreeForm) return _normalizeTypes(s.typeName);
    }
    return _uiTypes;
  }

  @override
  void initState() {
    super.initState();
    // Phase 5f: when there's exactly one schema candidate (typically a
    // wildcard for array element or for a free-form Map child like
    // output_schema.*), auto-pre-pick it so its insert_template applies
    // on Confirm without a manual chip click. With multiple candidates
    // (e.g. conversion_templates.* with named children) the user must
    // pick one explicitly.
    if (widget.suggestions.length == 1) {
      final only = widget.suggestions.first;
      _pickedSuggestion = only;
      _type = _normalizeTypes(only.typeName).first;
      // When the single candidate has a literal key (e.g. `xlsx_sheet`,
      // `pre_pass`), pre-fill the key field so the user just confirms
      // with Enter instead of clicking the suggestion chip or retyping
      // the key. Free-form (`isFreeForm`) candidates keep the field
      // empty — the user names the key themselves.
      if (!only.isFreeForm) {
        _keyController.text = only.key;
      }
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  dynamic _defaultValue() {
    final picked = _pickedSuggestion;
    if (picked != null) {
      // Use FnDoc-supplied default + correct shape for the picked schema
      // entry — guarantees the new key starts in a parser-acceptable state.
      return SchemaGate.scaffoldFor(picked);
    }
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
    int? atIndex;
    if (widget.isMap && widget.parent != null && key != null) {
      final store = context.read<TraceStore>();
      atIndex = SchemaGate(store)
          .insertIndexFor(widget.parentPath, key, widget.parent!);
    }
    widget.onConfirm(key, _defaultValue(), atIndex);
    Navigator.of(context).pop();
  }

  void _pickSuggestion(InsertKeyCandidate c) {
    setState(() {
      _pickedSuggestion = c;
      _type = _normalizeTypes(c.typeName).first;
      _error = null;
      if (!c.isFreeForm) {
        _keyController.text = c.key;
      } else {
        // Wildcard candidate (parent accepts any key name) — clear text
        // so user can type freely; keep the type pre-selected.
        _keyController.text = '';
      }
    });
    // Pull focus back into the key field so the next Enter fires _confirm
    // (the dialog-level CallbackShortcuts) instead of re-triggering the
    // chip InkWell that was just tapped.
    _keyFocusNode.requestFocus();
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
                  if (widget.suggestions.isNotEmpty) ...[
                    Text(widget.isMap
                        ? 'Schema-defined keys'
                        : 'Schema template',
                        style: BxpText.body(context,
                            color: th.textMuted, size: BxpSize.sm)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final s in widget.suggestions)
                          InkWell(
                            onTap: () => _pickSuggestion(s),
                            child: Tooltip(
                              message: s.description ?? '',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                      color: identical(_pickedSuggestion, s)
                                          ? th.accentHighlight
                                          : borderColor),
                                  color: identical(_pickedSuggestion, s)
                                      ? th.selectionBg
                                      : Colors.transparent,
                                ),
                                child: Text(
                                  s.isFreeForm
                                      ? '<custom> (${s.typeName})'
                                      : '${s.key} (${s.typeName})${s.required ? ' *' : ''}',
                                  style: BxpText.body(context,
                                      color: identical(_pickedSuggestion, s)
                                          ? th.selectionText
                                          : th.textMuted,
                                      size: BxpSize.sm),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (widget.isMap) ...[
                    Text('Key',
                        style: BxpText.body(context,
                            color: th.textMuted, size: BxpSize.sm)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _keyController,
                      focusNode: _keyFocusNode,
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
                  if (_allowedTypes().length > 1) ...[
                    Text('Type',
                        style: BxpText.body(context,
                            color: th.textMuted, size: BxpSize.sm)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: _allowedTypes().map((typ) {
                      final sel = _type == typ;
                      return InkWell(
                        onTap: () => setState(() {
                          _type = typ;
                          // Manual type pick overrides any auto-selected
                          // schema template — fall back to type-default
                          // scaffold ({}, [], "", 0, false).
                          _pickedSuggestion = null;
                        }),
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
                  ],
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
class _ExprLeaf extends StatefulWidget {
  final String text;
  final List<String> path;

  const _ExprLeaf({required this.text, required this.path});

  @override
  State<_ExprLeaf> createState() => _ExprLeafState();
}

class _ExprLeafState extends State<_ExprLeaf> {
  // Last `exprGeneration` for which this leaf has performed a scroll-into-
  // view. Without this guard every Provider rebuild while the leaf is
  // active would call `Scrollable.ensureVisible` again.
  int _lastScrolledGen = -1;

  @override
  void initState() {
    super.initState();
    // Phase 5h: expression cells aren't edited inline — clicking them
    // brings up the right-side ExprPanel via `setSelectedExpr`. So if
    // this leaf is the freshly-inserted node, mirror the click here so
    // the user lands in the panel (where the ExprEditor auto-focuses)
    // instead of having to click the leaf themselves.
    final p = widget.path;
    final store = context.read<TraceStore>();
    final pending = store.pendingFocusPath.value;
    if (pending == null || pending.length != p.length) return;
    for (var i = 0; i < p.length; i++) {
      if (pending[i] != p[i]) return;
    }
    store.clearPendingFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) store.setSelectedExpr(widget.path, widget.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final isActive = store.selectedExprPath != null &&
        _listEq(store.selectedExprPath!, widget.path);
    if (isActive && _lastScrolledGen != store.exprGeneration) {
      _lastScrolledGen = store.exprGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = context;
        final renderObject = ctx.findRenderObject();
        if (renderObject == null) return;
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 220),
          alignment: 0.3,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      });
    }
    final text = widget.text;
    final path = widget.path;
    // Show red underline on the selected leaf when bxp-fmt reports an
    // error for its current text. Non-selected leaves never get marked —
    // validating every expression on load would require one spawn per leaf.
    final showError = isActive && store.exprValidationError != null;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
      onTap: () => context.read<TraceStore>().setSelectedExpr(path, text),
      // Row-level MouseRegion owns the hover bg; suppress the InkWell's
      // own overlay so long expression cells don't paint a second hover
      // layer past the SCV clip.
      hoverColor: Colors.transparent,
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
  /// Phase 5h: when set, this cell consults `TraceStore.pendingFocusPath`
  /// on first build and — if the path matches — auto-enters edit mode so
  /// the user lands directly in this field after a fresh `+` insert.
  final List<String>? path;

  const _EditableString({
    required this.value,
    required this.color,
    required this.onCommit,
    this.path,
  });

  @override
  State<_EditableString> createState() => _EditableStringState();
}

class _EditableStringState extends State<_EditableString> {
  bool isEditing = false;
  late TextEditingController controller;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value);
    _focus.addListener(_onFocusChange);
    _maybeAutoFocusPendingPath();
  }

  void _maybeAutoFocusPendingPath() {
    final p = widget.path;
    if (p == null) return;
    final store = context.read<TraceStore>();
    final pending = store.pendingFocusPath.value;
    if (pending == null || pending.length != p.length) return;
    for (var i = 0; i < p.length; i++) {
      if (pending[i] != p[i]) return;
    }
    // Consume the request — clear so other matching cells don't also
    // try to enter edit (insert always targets exactly one new node).
    store.clearPendingFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _enterEdit();
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus && isEditing) _commit();
  }

  void _enterEdit() {
    controller.value = TextEditingValue(
      text: widget.value,
      selection: TextSelection(baseOffset: 0, extentOffset: widget.value.length),
    );
    setState(() => isEditing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _commit() {
    if (!isEditing) return;
    setState(() => isEditing = false);
    _focus.unfocus();
    if (controller.text != widget.value) {
      widget.onCommit(controller.text);
    }
  }

  /// Discard pending edits and leave edit mode without firing onCommit.
  /// Mirrors bxp-ui's EditableString Escape handler.
  void _cancel() {
    if (!isEditing) return;
    controller.text = widget.value;
    setState(() => isEditing = false);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    if (!isEditing) {
      return InkWell(
        onTap: _enterEdit,
        // Row-level MouseRegion owns the hover bg.
        hoverColor: Colors.transparent,
        child: Text('"${widget.value}"',
            style: BxpText.body(context,color: widget.color, size: BxpSize.md)),
      );
    }

    // Field width = intrinsic text width + 20 % headroom for typing,
    // floored at 150 px so very short values still get a usable field.
    // Without this the previous fixed 150 px clipped any value >~18
    // chars and the user couldn't see what they were editing.
    final textStyle =
        BxpText.body(context, color: widget.color, size: BxpSize.md);
    final tp = TextPainter(
      text: TextSpan(text: widget.value, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final fieldWidth = (tp.width * 1.2 + 24)
        .clamp(LayoutDefaults.editableMinWidth, LayoutDefaults.editableMaxWidth);
    return SizedBox(
      height: 20,
      width: fieldWidth,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        },
        child: TextField(
          controller: controller,
          focusNode: _focus,
          style: textStyle,
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
        ),
      ),
    );
  }
}

class _EditableNumber extends StatefulWidget {
  final num value;
  final Color color;
  final ValueChanged<num> onCommit;
  /// Phase 5h: see [_EditableString.path].
  final List<String>? path;

  const _EditableNumber({
    required this.value,
    required this.color,
    required this.onCommit,
    this.path,
  });

  @override
  State<_EditableNumber> createState() => _EditableNumberState();
}

class _EditableNumberState extends State<_EditableNumber> {
  bool isEditing = false;
  late TextEditingController controller;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value.toString());
    _focus.addListener(_onFocusChange);
    _maybeAutoFocusPendingPath();
  }

  void _maybeAutoFocusPendingPath() {
    final p = widget.path;
    if (p == null) return;
    final store = context.read<TraceStore>();
    final pending = store.pendingFocusPath.value;
    if (pending == null || pending.length != p.length) return;
    for (var i = 0; i < p.length; i++) {
      if (pending[i] != p[i]) return;
    }
    store.clearPendingFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _enterEdit();
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus && isEditing) _commit();
  }

  void _enterEdit() {
    final s = widget.value.toString();
    controller.value = TextEditingValue(
      text: s,
      selection: TextSelection(baseOffset: 0, extentOffset: s.length),
    );
    setState(() => isEditing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _commit() {
    if (!isEditing) return;
    setState(() => isEditing = false);
    _focus.unfocus();
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
    if (!isEditing) return;
    controller.text = widget.value.toString();
    setState(() => isEditing = false);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    if (!isEditing) {
      return InkWell(
        onTap: _enterEdit,
        // Row-level MouseRegion owns the hover bg.
        hoverColor: Colors.transparent,
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
          focusNode: _focus,
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
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: () => onCommit(!value),
        // Row-level MouseRegion owns the hover bg.
        hoverColor: Colors.transparent,
        child: Text('$value',
            style: BxpText.body(context, color: color, size: BxpSize.md)),
      ),
    );
  }
}

/// Schema-driven dropdown for fields with `enum_values` (e.g.
/// csv_text_quote_in: "none"|"single"|"double"). Renders the current value
/// like _EditableString (quoted, click-to-open) but the click opens a
/// PopupMenu instead of a TextField so the user can only pick a documented
/// value. If the current value is not in [values] (manually edited config
/// outside the GUI, or a docs/config drift) it stays selectable but appears
/// at the top of the menu marked with a leading "(custom) " label.
class _EditableEnum extends StatelessWidget {
  final String value;
  final List<String> values;
  final Color color;
  final ValueChanged<String> onCommit;

  const _EditableEnum({
    required this.value,
    required this.values,
    required this.color,
    required this.onCommit,
  });

  static String _displayLabel(String v) =>
      v == '\t' ? r'\t' : v;

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final isKnown = values.contains(value);
    final menuItems = <PopupMenuEntry<String>>[];
    if (!isKnown) {
      menuItems.add(PopupMenuItem<String>(
        value: value,
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text('(custom) "${_displayLabel(value)}"',
            style: BxpText.body(context,
                color: t.errorText, size: BxpSize.sm)),
      ));
    }
    for (final v in values) {
      menuItems.add(PopupMenuItem<String>(
        value: v,
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text('"${_displayLabel(v)}"',
            style: BxpText.body(context, color: color, size: BxpSize.sm)),
      ));
    }
    return PopupMenuButton<String>(
      position: PopupMenuPosition.under,
      color: t.panelBg,
      elevation: 2,
      padding: EdgeInsets.zero,
      onSelected: (val) {
        if (val != value) onCommit(val);
      },
      itemBuilder: (_) => menuItems,
      // `tooltip: ''` suppresses PopupMenuButton's default "Show menu"
      // tooltip; null falls back to the localised default.
      tooltip: '',
      // Default `_kMenuDuration` of 300 ms makes the menu visibly
      // linger after the user picks an item before the underlying
      // value updates — reads as input lag. 80 ms is fast enough to
      // feel instant while still keeping the close animation visible.
      popUpAnimationStyle: AnimationStyle.noAnimation,
      child: Text('"${_displayLabel(value)}"',
          style: BxpText.body(context, color: color, size: BxpSize.md)
              .copyWith(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
            decorationColor: t.textMuted,
          )),
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
class _SchemaTooltipKey extends StatefulWidget {
  final String keyName;
  final List<String> path;
  const _SchemaTooltipKey({required this.keyName, required this.path});

  @override
  State<_SchemaTooltipKey> createState() => _SchemaTooltipKeyState();
}

class _SchemaTooltipKeyState extends State<_SchemaTooltipKey> {
  /// Backing fields previously held in [_SchemaTooltipKey] — exposed on
  /// `widget.<name>` after the StatelessWidget → StatefulWidget split.
  String get keyName => widget.keyName;
  List<String> get path => widget.path;

  /// Pending show timer (debounce so a quick pass over the key doesn't
  /// pop a tooltip).
  Timer? _showTimer;
  /// Active overlay entry. Null = no popup currently visible.
  OverlayEntry? _entry;
  /// Layer link anchoring the popup to this row's render box.
  final LayerLink _link = LayerLink();
  /// Captured at hover-enter so the overlay builder doesn't re-derive
  /// the schema lookup every frame.
  String? _pendingMessage;

  static const Duration _showDelay = Duration(milliseconds: 200);

  @override
  void dispose() {
    _showTimer?.cancel();
    _hide();
    super.dispose();
  }

  void _scheduleShow(String message) {
    _pendingMessage = message;
    _showTimer?.cancel();
    _showTimer = Timer(_showDelay, () {
      if (!mounted) return;
      _show();
    });
  }

  void _show() {
    if (_entry != null || _pendingMessage == null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final message = _pendingMessage!;
    final t = context.bxpTheme;
    final entry = OverlayEntry(
      builder: (ctx) {
        // `IgnorePointer` keeps the popup out of hit-testing — no
        // `_ExclusiveMouseRegion` "keep-alive" trap like Flutter's
        // built-in `Tooltip` (raw_tooltip.dart:795). Cursor-leaves-key =
        // popup dismisses synchronously via `onExit` below.
        return Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            offset: const Offset(0, 20),
            child: IgnorePointer(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.dialogBg,
                      border: Border.all(color: t.borderColor),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    child: Text(
                      message,
                      style: BxpText.body(context,
                          color: t.textPrimary, size: BxpSize.sm),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    _entry = entry;
  }

  void _hide() {
    _showTimer?.cancel();
    _showTimer = null;
    _entry?.remove();
    _entry = null;
    _pendingMessage = null;
  }

  Map<String, dynamic>? _findDoc(List<Map<String, dynamic>> schema) =>
      findSchemaDocIn(schema, path);

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

    final underlinedText = Text(
      keyName,
      style: style.copyWith(
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.dotted,
        decorationColor: t.textMuted,
      ),
    );

    // Gated by DebugSettings.tooltipsInTree. When OFF, render only the
    // dotted-underline hint without wrapping in Tooltip — drops 100+
    // Material Tooltip widgets and their internal MouseRegion + Timer
    // plumbing from the tree. When ON (production default), full
    // tooltip with the schema description + type / required / default
    // / enum metadata.
    final debug = context.watch<DebugSettings>();
    if (!debug.tooltipsInTree) {
      return MouseRegion(
        cursor: SystemMouseCursors.help,
        child: underlinedText,
      );
    }

    final type = doc['type_name']?.toString() ?? '';
    final required = doc['required'] == true;
    final defaultVal = doc['default']?.toString();
    final desc = doc['description']?.toString() ?? '';
    final ordered = doc['ordered'] == true;
    final enumValues = (doc['enum_values'] as List?)?.cast<String>();

    final headerParts = <String>[
      if (type.isNotEmpty) type,
      if (required) 'required',
      if (defaultVal != null && defaultVal != 'null') 'default: $defaultVal',
      if (ordered) 'ordered',
    ];
    final extras = <String>[
      if (enumValues != null && enumValues.isNotEmpty)
        'one of: ${enumValues.map((v) => v == "\t" ? r"\t" : v).join(", ")}',
    ];
    final body = [desc, ...extras].where((s) => s.isNotEmpty).join('\n\n');
    final tooltipMsg = headerParts.isEmpty
        ? body
        : '${headerParts.join(' · ')}\n\n$body';

    // Custom hover popup — Flutter's `Tooltip` would install a
    // `_RenderExclusiveMouseRegion` around BOTH the trigger and the
    // popup (raw_tooltip.dart:795), and the popup's mouse-region
    // "steals" focus from the row's MouseRegion, killing the row
    // hover-bg and blocking the tree's scroll wheel. Our overlay is
    // wrapped in `IgnorePointer` and pinned via `LayerLink`, so the
    // popup never participates in hit-testing — mouse leaves key,
    // `onExit` fires synchronously, popup is removed in the same
    // frame.
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        cursor: SystemMouseCursors.help,
        onEnter: (_) => _scheduleShow(tooltipMsg),
        onExit: (_) => _hide(),
        child: underlinedText,
      ),
    );
  }
}
