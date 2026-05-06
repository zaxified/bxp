/// Phase 5a debug instrumentation: print() to stdout, gated behind
/// `kDebugMode` so release builds carry no overhead.
///
/// `print()` (not `developer.log`) so the output reaches the flutter run
/// process stdout — that's what `mcp__dart__get_app_logs` captures.
/// Each line is prefixed `[bxp_gui]` for easy filtering.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Emit a structured trace event. `event` is the action name
/// (e.g. 'loadConfig', 'op.move', 'saveConfig.fail'), `data` is an
/// optional map of key/value details (paths, lengths, error messages).
///
/// Convention for `event` names: `<subsystem>.<verb>[.<outcome]`, e.g.
/// `astPatch.start`, `astPatch.ok`, `astPatch.parseFail`.
/// Uniform naming makes `grep '[bxp_gui] astPatch'` filtering effective.
void devTrace(String event, [Map<String, Object?>? data]) {
  if (!kDebugMode) return;
  String payload;
  if (data == null) {
    payload = event;
  } else {
    // jsonEncode can throw on cycles, non-encodable types, or recursive
    // toJson chains. devTrace is best-effort instrumentation and must
    // never break the calling code path.
    String encoded;
    try {
      encoded = jsonEncode(data);
    } catch (e) {
      encoded = '<unencodable: $e>';
    }
    payload = '$event $encoded';
  }
  // ignore: avoid_print
  print('[bxp_gui] $payload');
}
