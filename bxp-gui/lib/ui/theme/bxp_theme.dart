import 'package:flutter/material.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import 'bxp_theme_animator.dart';

/// A palette preset identifier. Stored in [TraceStore.theme].
enum BxpThemePreset {
  light,
  dark,
  slate,
  zinc,
  ftx,
}

/// Canonical palette tokens consumed by widgets.
///
/// Every visual element in the app reads its color from a named token
/// here — no widget should embed hardcoded `Color(0xFF...)` constants.
/// Adding a new theme = writing one [BxpTheme] literal; no widget
/// changes needed.
class BxpTheme {
  final BxpThemePreset preset;
  final String label; // displayed on TopBar
  final Brightness brightness;

  // ── Chrome ────────────────────────────────────────────────────────
  final Color surfaceBg; // deepest background (scaffold)
  final Color panelBg; // panels sitting on top of surfaceBg
  final Color borderColor; // dividers, borders

  // ── Text ──────────────────────────────────────────────────────────
  final Color textPrimary;
  final Color textMuted; // subdued labels
  final Color textSubtle; // secondary metadata
  final Color accentHighlight; // JSON keys, headers

  // ── Status surfaces ───────────────────────────────────────────────
  // Banner / badge backgrounds + borders + foreground text.
  final Color errorBg;
  final Color errorBorder;
  final Color errorText;
  final Color warnBg;
  final Color warnBorder;
  final Color warnText;
  final Color okBg;
  final Color okBorder;
  final Color okText;
  final Color infoBg;
  final Color infoBorder;
  final Color infoText;

  // ── Input chrome ──────────────────────────────────────────────────
  final Color inputFill;
  final Color inputBorder;
  final Color inputBorderFocused;
  final Color inputPlaceholder;

  // ── Interaction overlays ──────────────────────────────────────────
  final Color hoverOverlay;
  final Color activeOverlay;
  final Color selectionBg;
  final Color selectionText;
  final Color matchedRowTint; // alpha ~10% tint for matched rule rows

  // ── Scrollbar ─────────────────────────────────────────────────────
  final Color scrollbarThumb;
  final Color scrollbarThumbHover;

  // ── Dialog ────────────────────────────────────────────────────────
  final Color dialogBarrier;
  final Color dialogBg;
  final Color dialogShadow;

  // ── Syntax tokens (theme-aware) ───────────────────────────────────
  final Color codeColumn;
  final Color codeVariable;
  final Color codeKeyword;
  final Color codeFunction;
  final Color codeString;
  final Color codeNumber;
  final Color codeOperator;
  final Color codePunct;
  final Color codeIdent;
  final Color codeComment;

  // ── Data value colors (theme-aware) ───────────────────────────────
  final Color valueString;
  final Color valueNumber;
  final Color valueBool;
  final Color valueEmpty;
  final Color valueError;
  final Color valueWarn;
  final Color valueOk;

  // ── Material 3 seeds ──────────────────────────────────────────────
  final Color primarySeed;
  final Color secondarySeed;
  final Color tertiarySeed;
  final FlexTones Function(Brightness b) tones;

  const BxpTheme({
    required this.preset,
    required this.label,
    required this.brightness,
    required this.surfaceBg,
    required this.panelBg,
    required this.borderColor,
    required this.textPrimary,
    required this.textMuted,
    required this.textSubtle,
    required this.accentHighlight,
    required this.errorBg,
    required this.errorBorder,
    required this.errorText,
    required this.warnBg,
    required this.warnBorder,
    required this.warnText,
    required this.okBg,
    required this.okBorder,
    required this.okText,
    required this.infoBg,
    required this.infoBorder,
    required this.infoText,
    required this.inputFill,
    required this.inputBorder,
    required this.inputBorderFocused,
    required this.inputPlaceholder,
    required this.hoverOverlay,
    required this.activeOverlay,
    required this.selectionBg,
    required this.selectionText,
    required this.matchedRowTint,
    required this.scrollbarThumb,
    required this.scrollbarThumbHover,
    required this.dialogBarrier,
    required this.dialogBg,
    required this.dialogShadow,
    required this.codeColumn,
    required this.codeVariable,
    required this.codeKeyword,
    required this.codeFunction,
    required this.codeString,
    required this.codeNumber,
    required this.codeOperator,
    required this.codePunct,
    required this.codeIdent,
    required this.codeComment,
    required this.valueString,
    required this.valueNumber,
    required this.valueBool,
    required this.valueEmpty,
    required this.valueError,
    required this.valueWarn,
    required this.valueOk,
    required this.primarySeed,
    required this.secondarySeed,
    required this.tertiarySeed,
    required this.tones,
  });

  ColorScheme buildColorScheme() {
    return SeedColorScheme.fromSeeds(
      brightness: brightness,
      primaryKey: primarySeed,
      secondaryKey: secondarySeed,
      tertiaryKey: tertiarySeed,
      surfaceTint: Colors.transparent,
      tones: tones(brightness),
    );
  }

  /// Linear-interpolate every colour token between [a] (t=0) and [b]
  /// (t=1). Non-colour fields (brightness, preset, label, tones) snap
  /// to [b] — they're metadata that doesn't need to morph during the
  /// 200ms transition. Used by [BxpThemeAnimator] to cross-fade all
  /// app chrome when the user cycles themes.
  static BxpTheme lerp(BxpTheme a, BxpTheme b, double t) {
    Color c(Color x, Color y) => Color.lerp(x, y, t)!;
    return BxpTheme(
      preset: b.preset,
      label: b.label,
      brightness: b.brightness,
      surfaceBg: c(a.surfaceBg, b.surfaceBg),
      panelBg: c(a.panelBg, b.panelBg),
      borderColor: c(a.borderColor, b.borderColor),
      textPrimary: c(a.textPrimary, b.textPrimary),
      textMuted: c(a.textMuted, b.textMuted),
      textSubtle: c(a.textSubtle, b.textSubtle),
      accentHighlight: c(a.accentHighlight, b.accentHighlight),
      errorBg: c(a.errorBg, b.errorBg),
      errorBorder: c(a.errorBorder, b.errorBorder),
      errorText: c(a.errorText, b.errorText),
      warnBg: c(a.warnBg, b.warnBg),
      warnBorder: c(a.warnBorder, b.warnBorder),
      warnText: c(a.warnText, b.warnText),
      okBg: c(a.okBg, b.okBg),
      okBorder: c(a.okBorder, b.okBorder),
      okText: c(a.okText, b.okText),
      infoBg: c(a.infoBg, b.infoBg),
      infoBorder: c(a.infoBorder, b.infoBorder),
      infoText: c(a.infoText, b.infoText),
      inputFill: c(a.inputFill, b.inputFill),
      inputBorder: c(a.inputBorder, b.inputBorder),
      inputBorderFocused: c(a.inputBorderFocused, b.inputBorderFocused),
      inputPlaceholder: c(a.inputPlaceholder, b.inputPlaceholder),
      hoverOverlay: c(a.hoverOverlay, b.hoverOverlay),
      activeOverlay: c(a.activeOverlay, b.activeOverlay),
      selectionBg: c(a.selectionBg, b.selectionBg),
      selectionText: c(a.selectionText, b.selectionText),
      matchedRowTint: c(a.matchedRowTint, b.matchedRowTint),
      scrollbarThumb: c(a.scrollbarThumb, b.scrollbarThumb),
      scrollbarThumbHover: c(a.scrollbarThumbHover, b.scrollbarThumbHover),
      dialogBarrier: c(a.dialogBarrier, b.dialogBarrier),
      dialogBg: c(a.dialogBg, b.dialogBg),
      dialogShadow: c(a.dialogShadow, b.dialogShadow),
      codeColumn: c(a.codeColumn, b.codeColumn),
      codeVariable: c(a.codeVariable, b.codeVariable),
      codeKeyword: c(a.codeKeyword, b.codeKeyword),
      codeFunction: c(a.codeFunction, b.codeFunction),
      codeString: c(a.codeString, b.codeString),
      codeNumber: c(a.codeNumber, b.codeNumber),
      codeOperator: c(a.codeOperator, b.codeOperator),
      codePunct: c(a.codePunct, b.codePunct),
      codeIdent: c(a.codeIdent, b.codeIdent),
      codeComment: c(a.codeComment, b.codeComment),
      valueString: c(a.valueString, b.valueString),
      valueNumber: c(a.valueNumber, b.valueNumber),
      valueBool: c(a.valueBool, b.valueBool),
      valueEmpty: c(a.valueEmpty, b.valueEmpty),
      valueError: c(a.valueError, b.valueError),
      valueWarn: c(a.valueWarn, b.valueWarn),
      valueOk: c(a.valueOk, b.valueOk),
      primarySeed: c(a.primarySeed, b.primarySeed),
      secondarySeed: c(a.secondarySeed, b.secondarySeed),
      tertiarySeed: c(a.tertiarySeed, b.tertiarySeed),
      tones: b.tones,
    );
  }
}

extension BxpThemeHelpers on BxpTheme {
  /// Apply hover overlay on top of an arbitrary base (typically panelBg
  /// or borderColor). Returns the blended color so the result is opaque.
  Color withHover(Color base) => Color.alphaBlend(hoverOverlay, base);

  /// Apply active/pressed overlay.
  Color withActive(Color base) => Color.alphaBlend(activeOverlay, base);
}

// ── Preset catalogue ────────────────────────────────────────────────────────
//
// Slate + zinc retain the original dark palette + augment with all the
// new tokens (status surfaces, input chrome, syntax, etc.).
//
// FUTURE-TODO: load user-supplied themes from JSON files on disk.
// Every field on [BxpTheme] is either Color, Brightness, an enum-like
// preset id, or a label string — a `BxpTheme.fromJson(Map<String,dynamic>)`
// factory plus a `toJson()` helper would unlock:
//   1. Drop a `~/.config/bxp-gui/themes/myname.json` and have it appear
//      in the cycle without rebuilding the app.
//   2. Export the active preset for sharing / forking ("save as").
//   3. Theme marketplace later if there's demand.
// Schema is already JSON-friendly; only `tones` (a function pointer
// for FlexSeedScheme) needs a name → preset lookup. Keep this list of
// built-in presets as the fallback so corrupted/missing JSONs never
// brick the app.
//
// Until that lands, any new preset goes here as a `const BxpTheme(...)`
// literal and gets registered in [bxpThemes] + [bxpThemeOrder] below.

const _slate = BxpTheme(
  preset: BxpThemePreset.slate,
  label: 'SLATE',
  brightness: Brightness.dark,
  surfaceBg: Color(0xFF020617),
  panelBg: Color(0xFF0f172a),
  borderColor: Color(0xFF1e293b),
  textPrimary: Color(0xFFe2e8f0),
  textMuted: Color(0xFF64748b),
  textSubtle: Color(0xFF94a3b8),
  accentHighlight: Color(0xFFa5b4fc),
  errorBg: Color(0xFF7f1d1d),
  errorBorder: Color(0x99ef4444),
  errorText: Color(0xFFfca5a5),
  warnBg: Color(0xFF78350f),
  warnBorder: Color(0x99f59e0b),
  warnText: Color(0xFFfde68a),
  okBg: Color(0xFF064e3b),
  okBorder: Color(0x9910b981),
  okText: Color(0xFF6ee7b7),
  infoBg: Color(0xFF1e3a8a),
  infoBorder: Color(0x993b82f6),
  infoText: Color(0xFFbfdbfe),
  inputFill: Color(0xFF1e293b),
  inputBorder: Color(0xFF334155),
  inputBorderFocused: Color(0xFF94a3b8),
  inputPlaceholder: Color(0xFF64748b),
  hoverOverlay: Color(0x14ffffff),
  activeOverlay: Color(0x29ffffff),
  selectionBg: Color(0xFF1e293b),
  selectionText: Color(0xFF6ee7b7),
  matchedRowTint: Color(0x1A064e3b),
  scrollbarThumb: Color(0x66808080),
  scrollbarThumbHover: Color(0xAAB0B0B0),
  dialogBarrier: Color(0xAA000000),
  dialogBg: Color(0xFF0f172a),
  dialogShadow: Color(0x66000000),
  codeColumn: Color(0xFFfbbf24),
  codeVariable: Color(0xFFa5b4fc),
  codeKeyword: Color(0xFF60a5fa),
  codeFunction: Color(0xFFc4b5fd),
  codeString: Color(0xFF6ee7b7),
  codeNumber: Color(0xFFfcd34d),
  codeOperator: Color(0xFF94a3b8),
  codePunct: Color(0xFF64748b),
  codeIdent: Color(0xFFe2e8f0),
  codeComment: Color(0xFF6a9955),
  valueString: Color(0xFFcbd5e1),
  valueNumber: Color(0xFFfbbf24),
  valueBool: Color(0xFF38bdf8),
  valueEmpty: Color(0xFF475569),
  valueError: Color(0xFFf87171),
  valueWarn: Color(0xFFfbbf24),
  valueOk: Color(0xFF34d399),
  primarySeed: Color(0xFF6366f1),
  secondarySeed: Color(0xFF94a3b8),
  tertiarySeed: Color(0xFFc4b5fd),
  tones: FlexTones.ultraContrast,
);

const _zinc = BxpTheme(
  preset: BxpThemePreset.zinc,
  label: 'ZINC',
  brightness: Brightness.dark,
  surfaceBg: Color(0xFF09090b),
  panelBg: Color(0xFF18181b),
  borderColor: Color(0xFF27272a),
  textPrimary: Color(0xFFe4e4e7),
  textMuted: Color(0xFFa1a1aa),
  textSubtle: Color(0xFFa1a1aa),
  // Cyan accent (borrowed from the dark preset) — zinc's monochrome
  // palette would otherwise make accentHighlight a near-white gray,
  // which reads as washed out for cursors, headers, and primary
  // action buttons. Code-token greys stay pure (codeVariable et al.).
  accentHighlight: Color(0xFF4FC3F7),
  errorBg: Color(0xFF7f1d1d),
  errorBorder: Color(0x99ef4444),
  errorText: Color(0xFFfca5a5),
  warnBg: Color(0xFF78350f),
  warnBorder: Color(0x99f59e0b),
  warnText: Color(0xFFfde68a),
  okBg: Color(0xFF064e3b),
  okBorder: Color(0x9910b981),
  okText: Color(0xFF6ee7b7),
  infoBg: Color(0xFF1e3a8a),
  infoBorder: Color(0x993b82f6),
  infoText: Color(0xFFbfdbfe),
  inputFill: Color(0xFF27272a),
  inputBorder: Color(0xFF3f3f46),
  inputBorderFocused: Color(0xFFa1a1aa),
  inputPlaceholder: Color(0xFF71717a),
  hoverOverlay: Color(0x14ffffff),
  activeOverlay: Color(0x29ffffff),
  selectionBg: Color(0xFF27272a),
  selectionText: Color(0xFFe4e4e7),
  matchedRowTint: Color(0x1A404040),
  scrollbarThumb: Color(0x66808080),
  scrollbarThumbHover: Color(0xAAB0B0B0),
  dialogBarrier: Color(0xAA000000),
  dialogBg: Color(0xFF18181b),
  dialogShadow: Color(0x66000000),
  codeColumn: Color(0xFFfbbf24),
  codeVariable: Color(0xFFa5b4fc),
  codeKeyword: Color(0xFF60a5fa),
  codeFunction: Color(0xFFc4b5fd),
  codeString: Color(0xFF6ee7b7),
  codeNumber: Color(0xFFfcd34d),
  codeOperator: Color(0xFFa1a1aa),
  codePunct: Color(0xFF71717a),
  codeIdent: Color(0xFFe4e4e7),
  codeComment: Color(0xFF6a9955),
  valueString: Color(0xFFd4d4d8),
  valueNumber: Color(0xFFfbbf24),
  valueBool: Color(0xFF38bdf8),
  valueEmpty: Color(0xFF52525b),
  valueError: Color(0xFFf87171),
  valueWarn: Color(0xFFfbbf24),
  valueOk: Color(0xFF34d399),
  primarySeed: Color(0xFF18181b),
  secondarySeed: Color(0xFF71717a),
  tertiarySeed: Color(0xFFa1a1aa),
  tones: FlexTones.vividSurfaces,
);

// LIGHT — Visual Studio "Light Modern" (VS Code reference theme).
//
// Chrome palette ↔ light_modern.json:
//   surfaceBg       = editor.background      (#FFFFFF)
//   panelBg         = sideBar.background     (#F8F8F8) — slight off-white
//   borderColor     = sideBar.border         (#E5E5E5)
//   textPrimary     = activityBar.foreground (#1F1F1F)
//   textSubtle      = descriptionForeground  (#3B3B3B)
//   textMuted       = activityBar.inactive   (#616161 ≈ #6E6E6E)
//   accentHighlight = activityBar.activeBorder/focusBorder (#005FB8)
//   inputFill       = input.background       (#FFFFFF)
//   inputBorder     = input.border           (#CECECE)
//   inputBorderFocused = focusBorder         (#005FB8)
//   inputPlaceholder = input.placeholder     (#767676)
//   selectionBg     = list.activeSelection   (#E8E8E8)
//   selectionText   = list.activeSelectionFg (#000000)
//
// Syntax palette ↔ light_plus.json (extends light_vs.json):
//   codeKeyword   = #0000FF  (keyword, keyword.control, storage.type, constant.language)
//   codeString    = #A31515  (string, semanticTokenColors.stringLiteral)
//   codeNumber    = #098658  (constant.numeric, semanticTokenColors.numberLiteral)
//   codeFunction  = #795E26  (entity.name.function, semanticTokenColors.customLiteral)
//   codeVariable  = #001080  (variable, meta.definition.variable.name)
//   codeColumn    = #AF00DB  (light_plus "Control flow / Special keywords")
//   codeComment   = #008000  (comment)
//   codeIdent     = #3B3B3B  (editor.foreground in light_modern)
//   codeOperator  = #000000  (keyword.operator)
//   codePunct     = #3B3B3B  (default punctuation = editor.foreground)
//
// Data values match the syntax (number/bool tokens) where they cross
// over with code semantics; bare strings use editor.foreground so a
// row of CSV strings doesn't paint as Light Modern's dark-red string
// literal (#A31515 would be misleading — it signals "string token in
// source code", not "string content in a data cell").
const _light = BxpTheme(
  preset: BxpThemePreset.light,
  label: 'LIGHT',
  brightness: Brightness.light,
  surfaceBg: Color(0xFFFFFFFF),
  panelBg: Color(0xFFF8F8F8),
  borderColor: Color(0xFFE5E5E5),
  textPrimary: Color(0xFF1F1F1F),
  textMuted: Color(0xFF616161),
  textSubtle: Color(0xFF3B3B3B),
  accentHighlight: Color(0xFF005FB8),
  errorBg: Color(0xFFFEE2E2),
  errorBorder: Color(0xFFEF4444),
  errorText: Color(0xFFB91C1C),
  warnBg: Color(0xFFFEF3C7),
  warnBorder: Color(0xFFF59E0B),
  warnText: Color(0xFF92400E),
  okBg: Color(0xFFD1FAE5),
  okBorder: Color(0xFF10B981),
  okText: Color(0xFF065F46),
  infoBg: Color(0xFFDBEAFE),
  infoBorder: Color(0xFF005FB8),
  infoText: Color(0xFF1E40AF),
  inputFill: Color(0xFFFFFFFF),
  inputBorder: Color(0xFFCECECE),
  inputBorderFocused: Color(0xFF005FB8),
  inputPlaceholder: Color(0xFF767676),
  hoverOverlay: Color(0x0F000000),
  activeOverlay: Color(0x1F000000),
  selectionBg: Color(0xFFE8E8E8),
  selectionText: Color(0xFF000000),
  matchedRowTint: Color(0x141FAA59),
  scrollbarThumb: Color(0x66808080),
  scrollbarThumbHover: Color(0xAA606060),
  dialogBarrier: Color(0x66000000),
  dialogBg: Color(0xFFFFFFFF),
  dialogShadow: Color(0x33000000),
  codeColumn: Color(0xFFAF00DB),
  codeVariable: Color(0xFF001080),
  codeKeyword: Color(0xFF0000FF),
  codeFunction: Color(0xFF795E26),
  codeString: Color(0xFFA31515),
  codeNumber: Color(0xFF098658),
  codeOperator: Color(0xFF000000),
  codePunct: Color(0xFF3B3B3B),
  codeIdent: Color(0xFF3B3B3B),
  codeComment: Color(0xFF008000),
  valueString: Color(0xFF3B3B3B),
  valueNumber: Color(0xFF098658),
  valueBool: Color(0xFF0000FF),
  valueEmpty: Color(0xFFB0B0B0),
  valueError: Color(0xFFB91C1C),
  valueWarn: Color(0xFF92400E),
  valueOk: Color(0xFF065F46),
  primarySeed: Color(0xFF005FB8),
  secondarySeed: Color(0xFF616161),
  tertiarySeed: Color(0xFF795E26),
  tones: FlexTones.material,
);

// DARK — VS Code "Dark Modern" (Dark2026). Slightly warmer than slate,
// with VS Code's signature semantic syntax palette (keyword=#569CD6,
// string=#CE9178, number=#B5CEA8, function=#DCDCAA, variable=#9CDCFE).
const _dark = BxpTheme(
  preset: BxpThemePreset.dark,
  label: 'DARK',
  brightness: Brightness.dark,
  surfaceBg: Color(0xFF1F1F1F),
  panelBg: Color(0xFF181818),
  borderColor: Color(0xFF2B2B2B),
  textPrimary: Color(0xFFCCCCCC),
  textMuted: Color(0xFF6E7681),
  textSubtle: Color(0xFF8B949E),
  accentHighlight: Color(0xFF4FC3F7),
  errorBg: Color(0xFF5A1D1D),
  errorBorder: Color(0xFFF14C4C),
  errorText: Color(0xFFF87171),
  warnBg: Color(0xFF4D3800),
  warnBorder: Color(0xFFCCA700),
  warnText: Color(0xFFFFC107),
  okBg: Color(0xFF0E2F1F),
  okBorder: Color(0xFF4EC9B0),
  okText: Color(0xFF6EE7B7),
  infoBg: Color(0xFF1A2A40),
  infoBorder: Color(0xFF4FC3F7),
  infoText: Color(0xFF9CDCFE),
  inputFill: Color(0xFF313131),
  inputBorder: Color(0xFF3C3C3C),
  inputBorderFocused: Color(0xFF4FC3F7),
  inputPlaceholder: Color(0xFF6E7681),
  hoverOverlay: Color(0x14FFFFFF),
  activeOverlay: Color(0x29FFFFFF),
  selectionBg: Color(0xFF264F78),
  selectionText: Color(0xFFFFFFFF),
  matchedRowTint: Color(0x1A064E3B),
  scrollbarThumb: Color(0x66808080),
  scrollbarThumbHover: Color(0xAAB0B0B0),
  dialogBarrier: Color(0xAA000000),
  dialogBg: Color(0xFF252526),
  dialogShadow: Color(0x66000000),
  codeColumn: Color(0xFF4FC1FF),
  codeVariable: Color(0xFF9CDCFE),
  codeKeyword: Color(0xFF569CD6),
  codeFunction: Color(0xFFDCDCAA),
  codeString: Color(0xFFCE9178),
  codeNumber: Color(0xFFB5CEA8),
  codeOperator: Color(0xFFD4D4D4),
  codePunct: Color(0xFFD4D4D4),
  codeIdent: Color(0xFFD4D4D4),
  codeComment: Color(0xFF6A9955),
  valueString: Color(0xFFCE9178),
  valueNumber: Color(0xFFB5CEA8),
  valueBool: Color(0xFF569CD6),
  valueEmpty: Color(0xFF6E7681),
  valueError: Color(0xFFF87171),
  valueWarn: Color(0xFFFFC107),
  valueOk: Color(0xFF6EE7B7),
  primarySeed: Color(0xFF4FC3F7),
  secondarySeed: Color(0xFF6E7681),
  tertiarySeed: Color(0xFFDCDCAA),
  tones: FlexTones.ultraContrast,
);

// FTX Terminal — amber accent (#d97706) on near-black (#0a0a0a).
// Chrome palette ↔ ftx-terminal-color-theme.json:
//   surfaceBg          = editor.background / terminal.background  (#0a0a0a)
//   panelBg            = sideBar.background / editorWidget.bg     (#111111)
//   borderColor        = sideBar.border / editorGroup.border      (#202020)
//   textPrimary        = foreground                               (#e5e5e5)
//   textMuted          = disabledForeground                       (#5a5a5a)
//   textSubtle         = descriptionForeground                    (#808080)
//   accentHighlight    = activityBar.foreground / sideBarTitle.fg (#e19d06)
//   inputFill          = input.background                         (#0a0a0a)
//   inputBorder        = input.border / checkbox.border           (#2a2a2a)
//   inputBorderFocused = focusBorder / inputOption.activeBorder   (#d97706)
//   inputPlaceholder   = input.placeholderForeground              (#5a5a5a)
//   selectionBg        = list.activeSelectionBackground blend     (#1a1200)
//   selectionText      = list.activeSelectionForeground           (#e19d06)
// Syntax palette ↔ tokenColors / semanticTokenColors:
//   codeKeyword   = keyword                (#d97706)
//   codeString    = string                 (#e19d06)
//   codeNumber    = constant.numeric       (#16a34a)
//   codeFunction  = entity.name.function   (#22b8d6)
//   codeVariable  = variable               (#e5e5e5)
//   codeColumn    = amber accent highlight (#d97706)
//   codeComment   = comment                (#5a5a5a)
//   codeOperator  = keyword.operator       (#a0a0a0)
//   codePunct     = punctuation            (#a0a0a0)
//   codeIdent     = foreground             (#e5e5e5)
const _ftx = BxpTheme(
  preset: BxpThemePreset.ftx,
  label: 'FTX',
  brightness: Brightness.dark,
  surfaceBg: Color(0xFF0a0a08),
  panelBg: Color(0xFF1a1810),
  borderColor: Color(0xFF332e20),
  textPrimary: Color(0xFFf8f4e8),
  textMuted: Color(0xFFc08830),
  textSubtle: Color(0xFF9a7228),
  accentHighlight: Color(0xFFe19d06),
  errorBg: Color(0xFF3a0c0c),
  errorBorder: Color(0xFFdc2626),
  errorText: Color(0xFFffb4b4),
  warnBg: Color(0xFF3a2a0c),
  warnBorder: Color(0xFFd97706),
  warnText: Color(0xFFffd28a),
  okBg: Color(0xFF0d1f0d),
  okBorder: Color(0xFF16a34a),
  okText: Color(0xFF22c55e),
  infoBg: Color(0xFF0a2a33),
  infoBorder: Color(0xFF0891b1),
  infoText: Color(0xFFa0e6f0),
  inputFill: Color(0xFF0a0a0a),
  inputBorder: Color(0xFF2a2a2a),
  inputBorderFocused: Color(0xFFd97706),
  inputPlaceholder: Color(0xFF9a7a28),
  hoverOverlay: Color(0x14ffffff),
  activeOverlay: Color(0x29ffffff),
  selectionBg: Color(0xFF1a1200),
  selectionText: Color(0xFFe19d06),
  matchedRowTint: Color(0x1Ad97706),
  scrollbarThumb: Color(0x662a2a2a),
  scrollbarThumbHover: Color(0xFF3a3a3a),
  dialogBarrier: Color(0xAA000000),
  dialogBg: Color(0xFF111111),
  dialogShadow: Color(0x66000000),
  codeColumn: Color(0xFFd97706),
  codeVariable: Color(0xFFf0ece0),
  codeKeyword: Color(0xFFd97706),
  codeFunction: Color(0xFF22b8d6),
  codeString: Color(0xFFe19d06),
  codeNumber: Color(0xFF16a34a),
  codeOperator: Color(0xFFd0b878),
  codePunct: Color(0xFFb8986a),
  codeIdent: Color(0xFFf5f2e8),
  codeComment: Color(0xFF806820),
  valueString: Color(0xFFd4b870),
  valueNumber: Color(0xFF16a34a),
  valueBool: Color(0xFFd97706),
  valueEmpty: Color(0xFF5a5a5a),
  valueError: Color(0xFFdc2626),
  valueWarn: Color(0xFFe19d06),
  valueOk: Color(0xFF22c55e),
  primarySeed: Color(0xFFd97706),
  secondarySeed: Color(0xFFa0a0a0),
  tertiarySeed: Color(0xFF0891b1),
  tones: FlexTones.ultraContrast,
);

const Map<BxpThemePreset, BxpTheme> bxpThemes = {
  BxpThemePreset.light: _light,
  BxpThemePreset.dark: _dark,
  BxpThemePreset.slate: _slate,
  BxpThemePreset.zinc: _zinc,
  BxpThemePreset.ftx: _ftx,
};

// Cycle order — light first so a new user's first cycle hop lands on
// dark (the common preference) rather than legacy slate. Persistence
// fallback in `_byName` returns slate for unknown names (e.g. legacy
// `nord`/`solarizedDark`/`amoled` in SharedPreferences from before
// Phase 2), so existing users keep a working preset even if their
// stored name was dropped.
const List<BxpThemePreset> bxpThemeOrder = [
  BxpThemePreset.light,
  BxpThemePreset.dark,
  BxpThemePreset.slate,
  BxpThemePreset.zinc,
  BxpThemePreset.ftx,
];

BxpThemePreset nextPreset(BxpThemePreset p) {
  final i = bxpThemeOrder.indexOf(p);
  return bxpThemeOrder[(i + 1) % bxpThemeOrder.length];
}

/// Next preset name in the rotation, starting from [name]. Unknown names
/// fall back to slate → zinc rotation.
String nextPresetName(String name) {
  final current = bxpThemeOrder.firstWhere(
    (p) => p.name == name,
    orElse: () => BxpThemePreset.slate,
  );
  return nextPreset(current).name;
}

BxpTheme _byName(String name) {
  for (final p in bxpThemeOrder) {
    if (p.name == name) return bxpThemes[p]!;
  }
  return _slate;
}

BxpTheme themeByName(String name) => _byName(name);

// ── Context access ─────────────────────────────────────────────────────────

extension BxpThemeContext on BuildContext {
  /// Resolves the current theme.
  ///
  /// Prefers the interpolated theme from a parent [BxpThemeScope]
  /// (set up by [BxpThemeAnimator]) so descendants rebuild on each
  /// animation tick during a cross-fade. Falls back to the raw
  /// store-resolved theme when no animator is in scope — keeps unit
  /// tests and isolated widget previews working without ceremony.
  BxpTheme get bxpTheme {
    final scoped = BxpThemeScope.of(this);
    if (scoped != null) return scoped;
    final name = watch<TraceStore>().themePresetName;
    return _byName(name);
  }

  /// Non-rebuilding accessor (for callbacks / one-shot reads).
  BxpTheme get bxpThemeRead {
    final name = read<TraceStore>().themePresetName;
    return _byName(name);
  }
}
