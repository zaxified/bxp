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
