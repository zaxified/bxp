import 'package:flutter/material.dart';

/// Holds every "shape" parameter that any sans/prose Text uses in the
/// app — font family, size scale, weight scale, letter-spacing scale.
///
/// **Color is NOT part of this scheme** — colors live in [BxpTheme]
/// because they change with light/dark, while font metrics shouldn't.
///
/// The scheme is theme-INDEPENDENT (same font/sizes across light/dark
/// — fonts shouldn't flicker on theme change), but it is itself a
/// class with named instances so swapping the entire app font is one
/// literal edit (`setTextScheme('inter')`) without touching widgets.
///
/// Single source of truth for typography across the entire app —
/// code-style text (cell values, expression syntax, JSON tree keys)
/// reads through the same scheme as prose. bxp-gui ships with Roboto
/// only; there is no separate mono/code scheme.
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

/// Default — Noto Sans. All sans schemes are bundled in `pubspec.yaml`
/// (`flutter.fonts:`); without an explicit `fontFamily` here Flutter
/// would fall back to the platform's system sans (Segoe UI / SF Pro /
/// DejaVu) and metrics would diverge by platform. Noto is the default
/// because the existing UI layout — fixed-width slots, label widths,
/// header padding — was tuned against Linux's pre-bundle build where
/// `fontFamily` was unset and the system fallback resolved to Noto;
/// pinning it as the bundled primary keeps that layout intact while
/// also rendering identically on Windows/macOS.
const kBxpTextNoto = BxpTextScheme(
  fontFamily: 'Noto Sans',
  fontFamilyFallback: ['Roboto', 'Inter', 'sans-serif'],
);

/// Alternative scheme — Roboto primary. Material's reference font;
/// slightly heavier and wider than Noto. Bundled as five static
/// weight files (Roboto's canonical distribution doesn't ship a
/// plain-weight variable, only Roboto Flex with axes we don't use).
const kBxpTextRoboto = BxpTextScheme(
  fontFamily: 'Roboto',
  fontFamilyFallback: ['Noto Sans', 'Inter', 'sans-serif'],
);

/// Alternative scheme — Inter primary. Modern neutral sans. Bundled
/// as one variable TTF; Flutter picks the right weight via OpenType
/// variations.
const kBxpTextInter = BxpTextScheme(
  fontFamily: 'Inter',
  fontFamilyFallback: ['Noto Sans', 'Roboto', 'sans-serif'],
);

/// Map name → scheme. Stored name persists in SharedPreferences as
/// `bxp-ui.textScheme` (mirrors `bxp-ui.codeFont` for the mono picker).
const Map<String, BxpTextScheme> bxpTextSchemes = {
  'noto': kBxpTextNoto,
  'roboto': kBxpTextRoboto,
  'inter': kBxpTextInter,
};
