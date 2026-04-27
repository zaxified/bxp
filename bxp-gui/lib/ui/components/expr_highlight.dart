import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
Set<String> _activeFunctions = const {};
Set<String> _activeKeywords = const {};

void _refreshLiveSets(BuildContext context) {
  final store = context.watch<TraceStore>();
  _activeFunctions = store.docFunctions
      .map((f) => f['name']?.toString() ?? '')
      .where((s) => s.isNotEmpty)
      .toSet();
  // Always keep boolean/null literals — they're tokenised as keywords for
  // highlighting even though the docs catalog only lists AND/OR.
  _activeKeywords = {
    'true', 'false', 'null',
    ...store.docKeywords
        .map((k) => k['name']?.toString() ?? '')
        .where((s) => s.isNotEmpty),
  };
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

List<_Span> _tokenize(String src) {
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
      final kind = _activeFunctions.contains(word)
          ? _Tok.function_
          : _activeKeywords.contains(word)
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
class ExprHighlight extends StatelessWidget {
  final String text;
  final BxpSize size;
  final double? sizePx;

  const ExprHighlight({
    super.key,
    required this.text,
    this.size = BxpSize.md,
    this.sizePx,
  });

  @override
  Widget build(BuildContext context) {
    _refreshLiveSets(context);
    final t = context.bxpTheme;
    final ts = context.watch<TraceStore>().textScheme;
    final spans = _tokenize(text);
    final px = sizePx ?? resolveBxpSize(ts, size);
    return RichText(
      text: TextSpan(
        // Family + letter-spacing flow from BxpTextScheme so editing
        // the central scheme propagates to every inline expression.
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
    _refreshLiveSets(context);
    final t = context.bxpTheme;
    final ts = context.watch<TraceStore>().textScheme;
    final spans = _tokenize(text);
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
