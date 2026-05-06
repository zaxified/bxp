import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../store/trace_store.dart';
import 'bxp_theme.dart';
import 'bxp_text.dart';

/// Floating right-side drawer that lists every token in the active
/// [BxpTheme] with a colour swatch, name, and ARGB hex. Useful when
/// authoring a new preset — you see at a glance which token paints
/// which surface and whether two tokens accidentally collide.
///
/// Toggled from [MainView] via Ctrl+Shift+T. Click backdrop or press
/// Escape to dismiss.
class ThemeInspector extends StatelessWidget {
  final VoidCallback onClose;
  const ThemeInspector({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            // Tap-to-dismiss backdrop. Light enough not to obscure the
            // app you're inspecting against.
            Positioned.fill(
              child: GestureDetector(
                onTap: onClose,
                child: Container(color: t.dialogBarrier.withValues(alpha: 0.3)),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 360,
              child: Material(
                color: t.dialogBg,
                elevation: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(onClose: onClose),
                    Expanded(child: _TokenList()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onClose;
  const _Header({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();
    final t = context.bxpTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: t.panelBg,
        border: Border(bottom: BorderSide(color: t.borderColor)),
      ),
      child: Row(
        children: [
          Text('THEME INSPECTOR', style: BxpText.label(context)),
          const SizedBox(width: 8),
          Text('· ${store.themePresetName}',
              style: BxpText.body(context, color: t.textMuted, size: BxpSize.sm)),
          const Spacer(),
          InkWell(
            onTap: onClose,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text('✕',
                  style: TextStyle(color: t.textMuted, fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }
}

class _TokenList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Section('Brightness', [
            _TokenRow('brightness', _brightnessSwatch(t.brightness),
                t.brightness == Brightness.dark ? 'dark' : 'light'),
          ]),
          _Section('Chrome', [
            _ColorRow('surfaceBg', t.surfaceBg),
            _ColorRow('panelBg', t.panelBg),
            _ColorRow('borderColor', t.borderColor),
          ]),
          _Section('Text', [
            _ColorRow('textPrimary', t.textPrimary),
            _ColorRow('textMuted', t.textMuted),
            _ColorRow('textSubtle', t.textSubtle),
            _ColorRow('accentHighlight', t.accentHighlight),
          ]),
          _Section('Status — Error', [
            _ColorRow('errorBg', t.errorBg),
            _ColorRow('errorBorder', t.errorBorder),
            _ColorRow('errorText', t.errorText),
          ]),
          _Section('Status — Warn', [
            _ColorRow('warnBg', t.warnBg),
            _ColorRow('warnBorder', t.warnBorder),
            _ColorRow('warnText', t.warnText),
          ]),
          _Section('Status — OK', [
            _ColorRow('okBg', t.okBg),
            _ColorRow('okBorder', t.okBorder),
            _ColorRow('okText', t.okText),
          ]),
          _Section('Status — Info', [
            _ColorRow('infoBg', t.infoBg),
            _ColorRow('infoBorder', t.infoBorder),
            _ColorRow('infoText', t.infoText),
          ]),
          _Section('Input', [
            _ColorRow('inputFill', t.inputFill),
            _ColorRow('inputBorder', t.inputBorder),
            _ColorRow('inputBorderFocused', t.inputBorderFocused),
            _ColorRow('inputPlaceholder', t.inputPlaceholder),
          ]),
          _Section('Interaction', [
            _ColorRow('hoverOverlay', t.hoverOverlay),
            _ColorRow('activeOverlay', t.activeOverlay),
            _ColorRow('selectionBg', t.selectionBg),
            _ColorRow('selectionText', t.selectionText),
            _ColorRow('matchedRowTint', t.matchedRowTint),
          ]),
          _Section('Scrollbar', [
            _ColorRow('scrollbarThumb', t.scrollbarThumb),
            _ColorRow('scrollbarThumbHover', t.scrollbarThumbHover),
          ]),
          _Section('Dialog', [
            _ColorRow('dialogBarrier', t.dialogBarrier),
            _ColorRow('dialogBg', t.dialogBg),
            _ColorRow('dialogShadow', t.dialogShadow),
          ]),
          _Section('Syntax', [
            _ColorRow('codeColumn', t.codeColumn),
            _ColorRow('codeVariable', t.codeVariable),
            _ColorRow('codeKeyword', t.codeKeyword),
            _ColorRow('codeFunction', t.codeFunction),
            _ColorRow('codeString', t.codeString),
            _ColorRow('codeNumber', t.codeNumber),
            _ColorRow('codeOperator', t.codeOperator),
            _ColorRow('codePunct', t.codePunct),
            _ColorRow('codeIdent', t.codeIdent),
            _ColorRow('codeComment', t.codeComment),
          ]),
          _Section('Values', [
            _ColorRow('valueString', t.valueString),
            _ColorRow('valueNumber', t.valueNumber),
            _ColorRow('valueBool', t.valueBool),
            _ColorRow('valueEmpty', t.valueEmpty),
            _ColorRow('valueError', t.valueError),
            _ColorRow('valueWarn', t.valueWarn),
            _ColorRow('valueOk', t.valueOk),
          ]),
          _Section('Material seeds', [
            _ColorRow('primarySeed', t.primarySeed),
            _ColorRow('secondarySeed', t.secondarySeed),
            _ColorRow('tertiarySeed', t.tertiarySeed),
          ]),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section(this.title, this.children);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(title.toUpperCase(),
                style: BxpText.label(context)),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _ColorRow extends StatelessWidget {
  final String name;
  final Color color;
  const _ColorRow(this.name, this.color);

  String _hex(Color c) {
    // Color.value is deprecated in Flutter 3.27+ but still works; use
    // .toARGB32() when available. For broad compat, format the four
    // 8-bit channels.
    int ch(double v) => (v * 255).round() & 0xff;
    final a = ch(c.a);
    final r = ch(c.r);
    final g = ch(c.g);
    final b = ch(c.b);
    return '#${a.toRadixString(16).padLeft(2, '0')}'
        '${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => _TokenRow(name, color, _hex(color));
}

/// Small monochromatic swatch + token name + value column. Shared
/// layout between coloured tokens and metadata-style rows (brightness,
/// labels) so the inspector grid stays consistent regardless of value
/// kind. Pulls only typography from [BxpText] — the
/// swatch itself draws the actual token colour, no theme lookup.
class _TokenRow extends StatelessWidget {
  final String name;
  final Object swatchOrColor; // Color or Widget
  final String valueText;
  const _TokenRow(this.name, this.swatchOrColor, this.valueText);

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;

    final Widget swatch;
    if (swatchOrColor is Color) {
      swatch = Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: swatchOrColor as Color,
          border: Border.all(color: t.borderColor, width: 1),
        ),
      );
    } else {
      swatch = swatchOrColor as Widget;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          swatch,
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(name,
                style: BxpText.body(context,color: t.textPrimary, size: BxpSize.sm),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: SelectableText(valueText,
                style: BxpText.body(context,color: t.textMuted, size: BxpSize.xs),
                maxLines: 1),
          ),
        ],
      ),
    );
  }
}

/// Tiny moon/sun glyph for the brightness row — gives a quick visual
/// cue without needing the user to read "dark"/"light".
Widget _brightnessSwatch(Brightness b) {
  return SizedBox(
    width: 20,
    height: 20,
    child: Center(
      child: Text(
        b == Brightness.dark ? '🌙' : '☀',
        style: const TextStyle(fontSize: 14),
      ),
    ),
  );
}
