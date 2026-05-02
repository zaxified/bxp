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
void devTrace(String event, [Map<String, Object?>? data]) {
  if (!kDebugMode) return;
  final payload = data == null ? event : '$event ${jsonEncode(data)}';
  // ignore: avoid_print
  print('[bxp_gui] $payload');
}
