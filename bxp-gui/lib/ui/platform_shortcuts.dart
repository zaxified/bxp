import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// True when the platform's command modifier is held — `Cmd` (Meta)
/// on macOS, `Ctrl` elsewhere. Use for app-level shortcuts (Save,
/// Undo, Open, Zoom, ...) so bindings match host conventions and
/// don't collide with `Ctrl+Up`/`Ctrl+Down` Mission Control on macOS.
bool isCommandModifierPressed() {
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return HardwareKeyboard.instance.isMetaPressed;
  }
  return HardwareKeyboard.instance.isControlPressed;
}

/// Display label for the command modifier — `Cmd` on macOS, `Ctrl`
/// elsewhere. Use in tooltips and shortcut help so the hint matches
/// the actual binding (see [isCommandModifierPressed]).
String get commandModifierLabel =>
    defaultTargetPlatform == TargetPlatform.macOS ? 'Cmd' : 'Ctrl';

/// One documented keyboard shortcut. Co-located with the command-modifier
/// helper; the single source the settings inspector renders. Keep in lockstep
/// with the `HardwareKeyboard` handlers (MainView et al.) that actually bind
/// these keys — this catalog documents them, it does not dispatch them.
class ShortcutDoc {
  final String action;
  final String keys;
  const ShortcutDoc(this.action, this.keys);
}

/// The app's keyboard-shortcut reference. Built with the host command modifier
/// ([commandModifierLabel]), so it is a function rather than a `const`.
List<ShortcutDoc> shortcutCatalog() {
  final mod = commandModifierLabel;
  return [
    ShortcutDoc('Save', '$mod+S'),
    ShortcutDoc('Reload from disk', '$mod+R'),
    ShortcutDoc('Undo / Redo', '$mod+Z / $mod+Y'),
    ShortcutDoc('Discard unsaved changes', '$mod+T'),
    ShortcutDoc('Validate', '$mod+E'),
    ShortcutDoc('Move focused node', '$mod+Shift+↑/↓'),
    ShortcutDoc('Delete focused node', '$mod+Shift+Del'),
    ShortcutDoc('Add child to focused node', '$mod+Shift+Insert'),
    ShortcutDoc('Rename map key (focused row)', 'double-click on the key chip'),
    ShortcutDoc('Open settings inspector', '$mod+Shift+S'),
    ShortcutDoc('Open theme inspector', '$mod+Shift+T'),
  ];
}
