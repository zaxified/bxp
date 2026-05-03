import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../store/trace_model.dart';
import '../../store/trace_store.dart';
import '../theme/bxp_theme.dart';
import '../theme/bxp_text.dart';

// ── BXP Expression tokenizer + inline highlighter ──────────────────────────
// Mirrors the logic in bxp-ui/src/mainview/expr/highlight.tsx + colors.ts.
// Token colours come from the active BxpTheme — light theme renders
// VS Code Light Modern syntax (keyword=#0000FF, string=#A31515, ...),
// dark theme renders Dark Modern (keyword=#569CD6, string=#CE9178, ...).

/// Cached active function/keyword sets, refreshed from the live docs
/// each time the highlighter runs. Keeping this at module scope avoids
/// allocating two new Sets per repaint of every cell with an expression.
/// Never empty in normal operation: the startup gate refuses to launch
/// MainView until `bxp-fmt --docs` populates `TraceStore.docFunctions`
/// and `docKeywords`.
/// Per-build snapshot of the live function/keyword sets. Captured locally
/// each call instead of mutated at module scope — the highlighter is run
/// from multiple builds simultaneously in test fixtures, and shared
/// mutable state caused subtle keyword-class bleed between stores.
class _LiveSets {
  final Set<String> functions;
  final Set<String> keywords;
  const _LiveSets(this.functions, this.keywords);
}

_LiveSets _liveSets(BuildContext context) {
  final store = context.watch<TraceStore>();
  final functions = store.docFunctions
      .map((f) => f['name']?.toString() ?? '')
      .where((s) => s.isNotEmpty)
      .toSet();
  // Always keep boolean/null literals — they're tokenised as keywords for
  // highlighting even though the docs catalog only lists AND/OR.
  final keywords = {
    'true', 'false', 'null',
    ...store.docKeywords
        .map((k) => k['name']?.toString() ?? '')
        .where((s) => s.isNotEmpty),
  };
  return _LiveSets(functions, keywords);
}

enum _Tok {
  column,
  variable,
  string,
  number,
  op,
  punct,
  function_,
  keyword,
  ident,
  ws,
}

class _Span {
  final _Tok kind;
  final String text;
  const _Span(this.kind, this.text);
}

List<_Span> _tokenize(String src, _LiveSets sets) {
  final out = <_Span>[];
  int i = 0;

  final ws = RegExp(r'^\s+');
  final col = RegExp(r'^\[[^\]]*\]');
  final varRef = RegExp(r'^\$[A-Za-z_][A-Za-z0-9_]*');
  final str = RegExp(r"^'([^'\\]|\\.)*'");
  final num = RegExp(r'^\d+(\.\d+)?');
  final op2 = RegExp(r'^(<=|>=|!=)');
  final op1 = RegExp(r'^[=<>+\-*/&]');
  final punct = RegExp(r'^[(),]');
  final id = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*');

  while (i < src.length) {
    final rest = src.substring(i);
    Match? m;
    if ((m = ws.firstMatch(rest)) != null) {
      out.add(_Span(_Tok.ws, m!.group(0)!));
      i += m.group(0)!.length;
      continue;
    }
    if ((m = col.firstMatch(rest)) != null) {
      out.add(_Span(_Tok.column, m!.group(0)!));
      i += m.group(0)!.length;
      continue;
    }
    if ((m = varRef.firstMatch(rest)) != null) {
      out.add(_Span(_Tok.variable, m!.group(0)!));
      i += m.group(0)!.length;
      continue;
    }
    if ((m = str.firstMatch(rest)) != null) {
      out.add(_Span(_Tok.string, m!.group(0)!));
      i += m.group(0)!.length;
      continue;
    }
    if ((m = num.firstMatch(rest)) != null) {
      out.add(_Span(_Tok.number, m!.group(0)!));
      i += m.group(0)!.length;
      continue;
    }
    if ((m = op2.firstMatch(rest)) != null) {
      out.add(_Span(_Tok.op, m!.group(0)!));
      i += m.group(0)!.length;
      continue;
    }
    if ((m = op1.firstMatch(rest)) != null) {
      out.add(_Span(_Tok.op, m!.group(0)!));
      i += m.group(0)!.length;
      continue;
    }
    if ((m = punct.firstMatch(rest)) != null) {
      out.add(_Span(_Tok.punct, m!.group(0)!));
      i += m.group(0)!.length;
      continue;
    }
    if ((m = id.firstMatch(rest)) != null) {
      final word = m!.group(0)!;
      final kind = sets.functions.contains(word)
          ? _Tok.function_
          : sets.keywords.contains(word)
          ? _Tok.keyword
          : _Tok.ident;
      out.add(_Span(kind, word));
      i += word.length;
      continue;
    }
    out.add(_Span(_Tok.ident, src[i]));
    i++;
  }
  return out;
}

Color _colorFor(_Tok kind, BxpTheme t) {
  switch (kind) {
    case _Tok.column:
      return t.codeColumn;
    case _Tok.variable:
      return t.codeVariable;
    case _Tok.string:
      return t.codeString;
    case _Tok.number:
      return t.codeNumber;
    case _Tok.op:
      return t.codeOperator;
    case _Tok.punct:
      return t.codePunct;
    case _Tok.function_:
      return t.codeFunction;
    case _Tok.keyword:
      return t.codeKeyword;
    case _Tok.ident:
      return t.codeIdent;
    case _Tok.ws:
      return Colors.transparent;
  }
}

bool _boldFor(_Tok kind) => kind == _Tok.function_ || kind == _Tok.keyword;

/// Inline highlighted expression widget (read-only).
///
/// Size flows through `BxpSize` so editing a step in the central
/// `BxpTextScheme` propagates here unchanged. The optional `sizePx`
/// escape hatch exists for callers that need raw px (e.g. the editor
/// box at 13 px which is between sizeMd and sizeXl).
///
/// When `hoverContext` is true, individual tokens become hoverable: column
/// references resolve to the matching field value in the currently-selected
/// row, `$var` references resolve to the var's evaluated value, and function
/// names resolve to their signature/description from `docFunctions`. Default
/// false to keep config-tree leaves cheap and non-interactive.
class ExprHighlight extends StatelessWidget {
  final String text;
  final BxpSize size;
  final double? sizePx;
  final bool hoverContext;

  const ExprHighlight({
    super.key,
    required this.text,
    this.size = BxpSize.md,
    this.sizePx,
    this.hoverContext = false,
  });

  @override
  Widget build(BuildContext context) {
    final sets = _liveSets(context);
    final t = context.bxpTheme;
    final store = context.watch<TraceStore>();
    final ts = store.textScheme;
    final spans = _tokenize(text, sets);
    final px = sizePx ?? resolveBxpSize(ts, size);

    if (!hoverContext) {
      // Fast path: single RichText, no tooltip wrappers — used by the
      // config tree's `_ExprLeaf` where every keystroke triggers a full
      // tree rebuild and per-token MouseRegions would add real overhead.
      return RichText(
        text: TextSpan(
          style: TextStyle(
            fontFamily: ts.fontFamily,
            fontFamilyFallback: ts.fontFamilyFallback,
            fontSize: px,
            letterSpacing: ts.trackBody,
          ),
          children: spans
              .map(
                (s) => TextSpan(
                  text: s.text,
                  style: TextStyle(
                    color: s.kind == _Tok.ws ? null : _colorFor(s.kind, t),
                    fontWeight: _boldFor(s.kind)
                        ? ts.weightBold
                        : ts.weightRegular,
                  ),
                ),
              )
              .toList(),
        ),
      );
    }

    // Hover path: one widget per token so each can have its own
    // MouseRegion/Tooltip. Wrap with zero spacing visually mimics a
    // single line of RichText for short expressions.
    final row = (store.selectedRowId != null && store.traceModel != null)
        ? store.traceModel!.rows[store.selectedRowId!]
        : null;
    final file = (row != null) ? store.traceModel!.files[row.fileId] : null;
    final headers = file?.headers ?? const <String>[];
    final docFunctions = store.docFunctions;
    // Lazily kick off the per-call expression trace. The first hover-enabled
    // render for this (row, expr) pair queues a `bxp-fmt --expr-trace` spawn;
    // when the result lands the store fires notifyListeners and we rebuild
    // with populated `calls` — so the function-token tooltip can switch from
    // signature-only to signature + evaluated value.
    final hasFn = spans.any((s) => s.kind == _Tok.function_);
    if (row != null && hasFn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        store.requestExprCallTrace(row.id, text);
      });
    }
    final calls = (row != null)
        ? store.exprCallTraces(row.id, text) ?? const <ExprCallTrace>[]
        : const <ExprCallTrace>[];

    final baseStyle = TextStyle(
      fontFamily: ts.fontFamily,
      fontFamilyFallback: ts.fontFamilyFallback,
      fontSize: px,
      letterSpacing: ts.trackBody,
    );

    final children = <Widget>[];
    int offset = 0;
    for (final s in spans) {
      final start = offset;
      final end = offset + s.text.length;
      offset = end;
      final tip = _tooltipFor(s, start, end, row, headers, docFunctions, calls);
      final tokenWidget = Text(
        s.text,
        style: TextStyle(
          color: s.kind == _Tok.ws ? null : _colorFor(s.kind, t),
          fontWeight: _boldFor(s.kind) ? ts.weightBold : ts.weightRegular,
        ),
        softWrap: false,
      );
      if (tip == null) {
        children.add(tokenWidget);
        continue;
      }
      children.add(Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 250),
        child: MouseRegion(
          cursor: SystemMouseCursors.help,
          child: tokenWidget,
        ),
      ));
    }
    return DefaultTextStyle.merge(
      style: baseStyle,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      ),
    );
  }
}

/// Compose a tooltip string for the given token. Returns null when there is
/// nothing useful to surface (literals, operators, punctuation, whitespace).
/// Caller renders the tooltip via Flutter's built-in `Tooltip`.
String? _tooltipFor(
  _Span s,
  int srcStart,
  int srcEnd,
  RowModel? row,
  List<String> headers,
  List<Map<String, dynamic>> docFunctions,
  List<ExprCallTrace> calls,
) {
  switch (s.kind) {
    case _Tok.column:
      // `[fieldName]` — strip brackets and look up the value in the row.
      if (row == null || s.text.length < 2) return null;
      final raw = s.text.substring(1, s.text.length - 1);
      // Numeric `[n]` (1-based column index) — show the field at that slot.
      final asIdx = int.tryParse(raw);
      if (asIdx != null && asIdx >= 1 && asIdx <= row.fields.length) {
        return '[$asIdx] = "${row.fields[asIdx - 1]}"';
      }
      final hi = headers.indexOf(raw);
      if (hi >= 0 && hi < row.fields.length) {
        return '[$raw] = "${row.fields[hi]}"';
      }
      return '[$raw] (not in headers)';
    case _Tok.variable:
      if (row == null) return null;
      final entry = row.vars
          .where((v) => v.name == s.text)
          .toList()
          .reversed
          .firstOrNull;
      if (entry == null) return '${s.text} (not evaluated for this row)';
      if (entry.kind == 'error') {
        return '${s.text} → ⚠ ${entry.error ?? "error"}';
      }
      return '${s.text} → "${entry.value ?? ""}"';
    case _Tok.function_:
      String? sig;
      String? desc;
      for (final f in docFunctions) {
        if (f['name'] == s.text) {
          sig = f['signature']?.toString();
          desc = f['description']?.toString();
          break;
        }
      }
      // Pick the call whose name token starts at this span's offset. Two
      // calls of the same fn at different offsets don't collide.
      ExprCallTrace? call;
      for (final c in calls) {
        if (c.fn == s.text && c.srcStart == srcStart) {
          call = c;
          break;
        }
      }
      final parts = <String>[];
      parts.add(sig ?? s.text);
      if (call != null) parts.add('→ "${call.value}"');
      if (desc != null && desc.isNotEmpty) parts.add(desc);
      return parts.join('\n\n');
    case _Tok.string:
    case _Tok.number:
    case _Tok.op:
    case _Tok.punct:
    case _Tok.keyword:
    case _Tok.ident:
    case _Tok.ws:
      return null;
  }
}

class ExprTextEditingController extends TextEditingController {
  /// Raw px — the editor TextField sits at 13 (between sizeMd 12 and
  /// sizeXl 16), an off-scale outlier accepted as the expression-editor
  /// look. If the project later adopts a 6-step scale the value should
  /// migrate to the new `BxpSize` token.
  final double fontSize;
  ExprTextEditingController({super.text, this.fontSize = 13});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final sets = _liveSets(context);
    final t = context.bxpTheme;
    final ts = context.watch<TraceStore>().textScheme;
    final spans = _tokenize(text, sets);
    return TextSpan(
      style: (style ?? const TextStyle()).copyWith(
        fontFamily: ts.fontFamily,
        fontFamilyFallback: ts.fontFamilyFallback,
        fontSize: fontSize,
        letterSpacing: ts.trackBody,
      ),
      children: spans
          .map(
            (s) => TextSpan(
              text: s.text,
              style: TextStyle(
                color: s.kind == _Tok.ws ? null : _colorFor(s.kind, t),
                fontWeight: _boldFor(s.kind)
                    ? ts.weightBold
                    : ts.weightRegular,
              ),
            ),
          )
          .toList(),
    );
  }
}
