/// Phase 5a debug instrumentation: developer.log calls gated behind
/// `kDebugMode` so release builds carry no overhead.
///
/// Each trace event has:
///   - `name: 'bxp_gui'` — easy filtering in the IDE Debug Console / DevTools
///   - `level: 800` (INFO) — visible at default log level
///
/// Read from MCP via `mcp__dart__get_app_logs` once the app is running.
/// Filter by `name == 'bxp_gui'` to skip framework noise.
library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Emit a structured trace event. `event` is the action name
/// (e.g. 'loadConfig', 'op.move', 'saveConfig.fail'), `data` is an
/// optional map of key/value details (paths, lengths, error messages).
void devTrace(String event, [Map<String, Object?>? data]) {
  if (!kDebugMode) return;
  final payload = data == null ? event : '$event ${jsonEncode(data)}';
  developer.log(payload, name: 'bxp_gui', level: 800);
}
