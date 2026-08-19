import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import 'bxp_theme.dart';
import 'bxp_text_scheme.dart';

/// Semantic size token. Picks one of the five steps defined in the
/// active [BxpTextScheme] (`sizeXs`/`sizeSm`/`sizeMd`/`sizeLg`/`sizeXl`).
///
/// Callers should always pass a [BxpSize] rather than a raw `double`
/// — that way changing a step in the scheme propagates everywhere.
/// For genuine off-scale outliers (a 9 px chip badge, a 13 px code
/// editor) use the `sizePx:` escape hatch on [BxpText] methods, which
/// bypasses the scheme.
enum BxpSize { xs, sm, md, lg, xl }

/// Resolve a [BxpSize] token against an active [BxpTextScheme].
///
/// Public so widgets that build their own RichText / TextSpan trees
/// (notably [ExprHighlight]) can stay on the same single source of
/// truth as [BxpText.body] without each duplicating the switch.
double resolveBxpSize(BxpTextScheme s, BxpSize key) {
  switch (key) {
    case BxpSize.xs:
      return s.sizeXs;
    case BxpSize.sm:
      return s.sizeSm;
    case BxpSize.md:
      return s.sizeMd;
    case BxpSize.lg:
      return s.sizeLg;
    case BxpSize.xl:
      return s.sizeXl;
  }
}

/// Semantic weight token. Picks one of the five steps from the active
/// [BxpTextScheme]. Mirrors [BxpSize] — callers should pass a
/// [BxpWeight] rather than a raw [FontWeight] so editing
/// `weightSemiBold` from w600 to w500 propagates everywhere instead of
/// missing the 30+ inline `FontWeight.w600` / `FontWeight.bold`
/// callsites.
enum BxpWeight { light, regular, medium, semiBold, bold }

FontWeight resolveBxpWeight(BxpTextScheme s, BxpWeight key) {
  switch (key) {
    case BxpWeight.light:
      return s.weightLight;
    case BxpWeight.regular:
      return s.weightRegular;
    case BxpWeight.medium:
      return s.weightMedium;
    case BxpWeight.semiBold:
      return s.weightSemiBold;
    case BxpWeight.bold:
      return s.weightBold;
  }
}

/// Semantic variants built on top of the active [BxpTextScheme].
///
/// Every sans/prose `Text` in the app should go through these helper
/// methods — not build `TextStyle(fontSize: ...)` by hand. Changing the
/// font / size / letter-spacing then happens by editing a single constant
/// in [BxpTextScheme] and propagates across the whole app.
///
/// Color defaults are read from the active [BxpTheme] via `context.bxpTheme`,
/// so the same methods work for both light and dark themes without extra
/// parameters. A color override is possible via an explicit `color:`.
///
/// All app text (prose AND code-style cells/syntax) flows through this
/// helper — bxp-gui no longer maintains a separate mono typography
/// scheme. Roboto is the single shipped font.
class BxpText {
  BxpText._();

  static BxpTextScheme _scheme(BuildContext ctx) =>
      ctx.watch<TraceStore>().textScheme;

  /// Body text — data cells, list values, dialog content. Default
  /// is `BxpSize.md` / w400 / textPrimary.
  ///
  /// [size] picks one of the five steps from [BxpTextScheme]. For the
  /// rare off-scale outlier (chip badge, code editor) pass [sizePx]
  /// instead — it overrides [size] with a raw double. Avoid using
  /// `sizePx` when a scheme step would do, otherwise edits to the
  /// central scale skip that callsite.
  ///
  /// [height] / [decoration*] / [fontStyle] pass through unchanged so
  /// callers that previously reached for a per-call `TextStyle(...)`
  /// can stay on this single helper.
  static TextStyle body(
    BuildContext ctx, {
    Color? color,
    BxpWeight weight = BxpWeight.regular,
    BxpSize size = BxpSize.md,
    double? sizePx,
    double? height,
    TextDecoration? decoration,
    Color? decorationColor,
    TextDecorationStyle? decorationStyle,
    FontStyle? fontStyle,
  }) {
    final s = _scheme(ctx);
    final t = ctx.bxpTheme;
    return TextStyle(
      fontFamily: s.fontFamily,
      fontFamilyFallback: s.fontFamilyFallback,
      fontSize: sizePx ?? resolveBxpSize(s, size),
      fontWeight: resolveBxpWeight(s, weight),
      letterSpacing: s.trackBody,
      color: color ?? t.textPrimary,
      height: height,
      decoration: decoration,
      decorationColor: decorationColor,
      decorationStyle: decorationStyle,
      fontStyle: fontStyle,
    );
  }

  /// Muted secondary line — file list meta ("template · 12 rows · 3 err"),
  /// footer texts. Default `BxpSize.xs` / textMuted.
  static TextStyle muted(BuildContext ctx,
      {BxpSize size = BxpSize.xs, double? sizePx}) {
    final s = _scheme(ctx);
    final t = ctx.bxpTheme;
    return TextStyle(
      fontFamily: s.fontFamily,
      fontFamilyFallback: s.fontFamilyFallback,
      fontSize: sizePx ?? resolveBxpSize(s, size),
      fontWeight: s.weightRegular,
      letterSpacing: s.trackBody,
      color: t.textMuted,
    );
  }

  /// Subtle metadata — "5 errors · 12 written" status footers, between
  /// primary and muted. Default `BxpSize.md` / textSubtle.
  static TextStyle subtle(BuildContext ctx,
      {BxpSize size = BxpSize.md, double? sizePx}) {
    final s = _scheme(ctx);
    final t = ctx.bxpTheme;
    return TextStyle(
      fontFamily: s.fontFamily,
      fontFamilyFallback: s.fontFamilyFallback,
      fontSize: sizePx ?? resolveBxpSize(s, size),
      fontWeight: s.weightRegular,
      letterSpacing: s.trackBody,
      color: t.textSubtle,
    );
  }

  /// Small uppercase label — panel headers (ROWS IN, ROWS OUT), top tabs.
  /// 10 / w600 / 1.0 / theme.textSubtle.
  static TextStyle label(BuildContext ctx, {Color? color}) {
    final s = _scheme(ctx);
    final t = ctx.bxpTheme;
    return TextStyle(
      fontFamily: s.fontFamily,
      fontFamilyFallback: s.fontFamilyFallback,
      fontSize: s.sizeXs,
      fontWeight: s.weightSemiBold,
      letterSpacing: s.trackWide,
      color: color ?? t.textSubtle,
    );
  }

  /// Section heading inside content — RowDetail "Inputs" / "Variables" /
  /// "Outputs". 11 / w600 / 0 / theme.textPrimary.
  static TextStyle heading(BuildContext ctx, {Color? color}) {
    final s = _scheme(ctx);
    final t = ctx.bxpTheme;
    return TextStyle(
      fontFamily: s.fontFamily,
      fontFamilyFallback: s.fontFamilyFallback,
      fontSize: s.sizeSm,
      fontWeight: s.weightSemiBold,
      letterSpacing: s.trackNormal,
      color: color ?? t.textPrimary,
    );
  }

  /// Status chip text — "VALID" / "INVALID" / "CHECKING" / "IDLE".
  /// 11 / w500 / 0 / required color (semantic — caller picks ok/error).
  static TextStyle status(BuildContext ctx, {required Color color}) {
    final s = _scheme(ctx);
    return TextStyle(
      fontFamily: s.fontFamily,
      fontFamilyFallback: s.fontFamilyFallback,
      fontSize: s.sizeSm,
      fontWeight: s.weightMedium,
      letterSpacing: s.trackNormal,
      color: color,
    );
  }

  /// Italic empty-state message — "No files yet. Click Run Dry-Run.".
  /// Default `BxpSize.md` / italic / textMuted.
  static TextStyle italic(BuildContext ctx,
      {Color? color, BxpSize size = BxpSize.md, double? sizePx}) {
    final s = _scheme(ctx);
    final t = ctx.bxpTheme;
    return TextStyle(
      fontFamily: s.fontFamily,
      fontFamilyFallback: s.fontFamilyFallback,
      fontSize: sizePx ?? resolveBxpSize(s, size),
      fontStyle: FontStyle.italic,
      letterSpacing: s.trackBody,
      color: color ?? t.textMuted,
    );
  }

  /// Dialog/page title — OpenDialog top, settings sections.
  /// 14 / w600 / -0.2 / theme.textPrimary.
  static TextStyle title(BuildContext ctx, {Color? color}) {
    final s = _scheme(ctx);
    final t = ctx.bxpTheme;
    return TextStyle(
      fontFamily: s.fontFamily,
      fontFamilyFallback: s.fontFamilyFallback,
      fontSize: s.sizeLg,
      fontWeight: s.weightSemiBold,
      letterSpacing: s.trackTight,
      color: color ?? t.textPrimary,
    );
  }
}
