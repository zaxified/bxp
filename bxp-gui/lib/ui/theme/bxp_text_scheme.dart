import 'package:material_ui/material_ui.dart';

/// Holds every "shape" parameter that any sans/prose Text uses in the
/// app — font family, size scale, weight scale, letter-spacing scale.
///
/// **Color is NOT part of this scheme** — colors live in [BxpTheme]
/// because they change with light/dark, while font metrics shouldn't.
///
/// The scheme is theme-INDEPENDENT (same font/sizes across light/dark
/// — fonts shouldn't flicker on theme change). bxp-gui ships exactly
/// one scheme (Roboto) so the class is effectively a constant; it
/// stays a class for future-proofing if a second font is ever added
/// back, and so call sites stay shape `ts.fontFamily` / `ts.sizeMd`
/// rather than imports of stand-alone constants.
///
/// Single source of truth for typography across the entire app —
/// code-style text (cell values, expression syntax, JSON tree keys)
/// reads through the same scheme as prose. There is no separate
/// mono/code scheme.
class BxpTextScheme {
  /// Family — `null` means Material default (Flutter ships Roboto, so
  /// it always renders without external installs).
  final String? fontFamily;
  final List<String>? fontFamilyFallback;

  // Size scale — used by [BxpText] named variants.
  final double sizeXs; // 10 — meta lines, badges
  final double sizeSm; // 11 — section headings, status chips
  final double sizeMd; // 12 — base body, data cells
  final double sizeLg; // 14 — dialog titles
  final double sizeXl; // 16 — page-level headings (rare)

  // Weight scale.
  final FontWeight weightLight; // w300
  final FontWeight weightRegular; // w400 — default body
  final FontWeight weightMedium; // w500 — emphasized values
  final FontWeight weightSemiBold; // w600 — section headings
  final FontWeight weightBold; // w700 — rare

  // Letter-spacing scale. trackBody = 0.7 was settled in iter-2 and
  // gives Roboto a slightly more open feel than its default tracking.
  final double trackTight; // -0.2 — large headings
  final double trackNormal; //  0   — code-adjacent
  final double trackBody; //  0.7 — body text (current default)
  final double trackWide; //  1.0 — uppercase labels

  const BxpTextScheme({
    this.fontFamily,
    this.fontFamilyFallback,
    this.sizeXs = 10,
    this.sizeSm = 11,
    this.sizeMd = 12,
    this.sizeLg = 14,
    this.sizeXl = 16,
    this.weightLight = FontWeight.w300,
    this.weightRegular = FontWeight.w400,
    this.weightMedium = FontWeight.w500,
    this.weightSemiBold = FontWeight.w600,
    this.weightBold = FontWeight.w700,
    this.trackTight = -0.2,
    this.trackNormal = 0,
    this.trackBody = 0.7,
    this.trackWide = 1.0,
  });
}

/// The (only) bundled scheme — Roboto. Material's reference font;
/// shipped as five static weight files (300/400/500/600/700) under
/// `bxp-gui/fonts/`. The explicit `fontFamily` is what makes
/// rendering identical on Windows/macOS/Linux; without it Flutter
/// would fall back to the platform's system sans (Segoe UI / SF Pro
/// / DejaVu) and metrics would diverge by platform.
const kBxpTextRoboto = BxpTextScheme(
  fontFamily: 'Roboto',
  fontFamilyFallback: ['sans-serif'],
);
