import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'dev_trace.dart';

/// The slice of live-GUI state + actions the MCP tools operate on.
///
/// Kept as a narrow interface (rather than a direct dependency on the
/// 4k-line `TraceStore`) so this service stays in the `services/` layer
/// without importing `store/`, and so tests can drive the server against a
/// lightweight fake. The production adapter lives in `main.dart`, next to
/// where `TraceStore` is constructed. Every member maps 1:1 to the SAME
/// action the UI uses — parity is definitional.
abstract interface class GuiMcpHost {
  /// Path of the currently loaded config, or empty when none is open.
  String get configPath;

  /// Whether there are unsaved edits.
  bool get isDirty;

  /// Whether the config was loaded with errors (edits are blocked then).
  bool get configLoadHadErrors;

  /// Whether any live error diagnostic is currently attached.
  bool get configHasErrors;

  /// Run lifecycle status name (e.g. `idle` / `running` / `done` / `error`).
  String get runStatusName;

  /// Run mode name (e.g. `none` / `dry` / `full`).
  String get runModeName;

  /// Exit code of the last `bxp-cli` run, or null when none ran.
  int? get lastExitCode;

  /// Active template filter (empty = all templates).
  String get activeTemplate;

  /// All diagnostics stacked one-per-line (errors, warnings, info, stderr).
  String get diagnosticBlob;

  /// Save-time error from the most recent [saveConfig], or null on success.
  String? get configSaveError;

  /// Load-time error from the most recent [loadConfig], or null on success.
  String? get configError;

  /// Error from the most recent dry/full run, or null on success.
  String? get runError;

  /// Error diagnostics attached to the node at [path].
  Map<String, String> errorsAt(List<String> path);

  /// JSON-friendly summary of the most recent dry/full run's btrace data
  /// (per-file row counts + stats, totals, exit code, parse issues). Null
  /// when no run has happened yet.
  Map<String, dynamic>? traceSummary();

  /// Edit a scalar leaf — the same live, undoable action the UI uses.
  void editConfigNode(List<String> path, dynamic newValue);

  /// Delete the config entry at [path] — the same action as the tree delete.
  void deleteConfigNode(List<String> path);

  /// Persist the edited config to disk (atomic + validated).
  Future<void> saveConfig();

  /// Point the editor at [path] (does not load it; pair with [loadConfig]).
  void setConfigPath(String path);

  /// (Re)load the active config from disk.
  Future<void> loadConfig();

  /// Run the conversion in dry-run mode (no output files written).
  Future<void> runDryRun();

  /// Run the full conversion (writes output files).
  Future<void> runFullRun();

  /// Quit the application. Callers should flush their response first.
  Future<void> exitApp();
}

/// Asks the user to approve a critical agent action. Returns `true` when
/// the user confirms, `false` on cancel / dismiss / no UI context. Injected
/// by `main.dart` (which owns `bxpNavigatorKey`) so this service stays free
/// of any Flutter `material` import and is trivially stubbable in tests.
typedef AgentConfirmFn = Future<bool> Function(String title, String detail);

/// One visible entry in the agent activity log. Every MCP tool invocation
/// appends exactly one entry so the user can see, after the fact, what the
/// agent did to their session.
class AgentActivityEntry {
  final DateTime time;
  final String tool;
  final String summary;

  /// One of: `ok`, `rejected`, `blocked`, `error`.
  final String outcome;

  const AgentActivityEntry({
    required this.time,
    required this.tool,
    required this.summary,
    required this.outcome,
  });
}

/// Embedded MCP server that exposes **stateful control of the running GUI**
/// to an agent over localhost StreamableHTTP.
///
/// Distinct from the standalone `bxp-mcp` Zig server (stateless data tools
/// over stdio): this one lives inside the Flutter process because its tools
/// manipulate the live [TraceStore] / UI. Every tool is a thin wrapper over
/// the SAME action layer the UI uses (`editConfigNode`, `saveConfig`, …) —
/// so parity is definitional and state changes repaint the UI for free via
/// the store's `notifyListeners`.
///
/// Transport + security (first iteration): binds strictly to `127.0.0.1`,
/// no auth (a local process already runs with user privileges). Per-session
/// transports keyed by `mcp-session-id`, mirroring the mcp_dart streamable
/// HTTP server example.
class GuiMcpServer extends ChangeNotifier {
  GuiMcpServer(this._host, {required AgentConfirmFn confirm})
      : _confirm = confirm;

  final GuiMcpHost _host;
  final AgentConfirmFn _confirm;

  /// Path the MCP endpoint is served from.
  static const String mcpPath = '/mcp';
  static const int _activityCap = 200;

  HttpServer? _http;
  StreamSubscription<HttpRequest>? _sub;
  final Map<String, StreamableHTTPServerTransport> _transports = {};

  final List<AgentActivityEntry> _activity = [];
  String? _lastError;

  bool get isRunning => _http != null;
  int? get port => _http?.port;

  /// True while at least one agent session is connected.
  bool get agentConnected => _transports.isNotEmpty;

  /// Last bind/serve failure, surfaced in the inspector. Null when healthy.
  String? get lastError => _lastError;

  /// Most-recent-first view of the activity log.
  List<AgentActivityEntry> get activity => List.unmodifiable(_activity);

  // ── Lifecycle ─────────────────────────────────────────────────────────

  /// Bind the loopback HTTP server and start serving MCP. [port] `0` lets
  /// the OS assign a free port (read back via [port]). A bind failure is
  /// NOT fatal — it is recorded in [lastError] and surfaced in the inspector
  /// (unlike the bridge library, the GUI is fully usable without the agent
  /// server).
  Future<void> start({int port = 0}) async {
    if (isRunning) return;
    _lastError = null;
    try {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _http = http;
      _sub = http.listen(
        _handleRequest,
        onError: (Object e) => devTrace('mcp.http.error', {'error': '$e'}),
      );
      devTrace('mcp.start', {'port': http.port});
    } catch (e) {
      _lastError = '$e';
      _http = null;
      devTrace('mcp.start.error', {'error': '$e'});
    }
    notifyListeners();
  }

  /// Stop serving: cancel the accept loop, close every live session
  /// transport, and close the socket. Idempotent.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    for (final t in _transports.values) {
      try {
        await t.close();
      } catch (_) {/* best-effort */}
    }
    _transports.clear();
    try {
      await _http?.close(force: true);
    } catch (_) {/* best-effort */}
    _http = null;
    devTrace('mcp.stop', const {});
    notifyListeners();
  }

  @override
  void dispose() {
    // Fire-and-forget — dispose can't await; the socket close is best-effort.
    unawaited(stop());
    super.dispose();
  }

  // ── HTTP plumbing (per-session transports) ───────────────────────────

  Future<void> _handleRequest(HttpRequest req) async {
    if (req.uri.path != mcpPath) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    try {
      switch (req.method) {
        case 'POST':
          await _handlePost(req);
          break;
        case 'GET':
        case 'DELETE':
          final t = _transportFor(req);
          if (t == null) {
            await _badRequest(req, 'Invalid or missing session ID');
            return;
          }
          await t.handleRequest(req);
          break;
        default:
          req.response.statusCode = HttpStatus.methodNotAllowed;
          await req.response.close();
      }
    } catch (e) {
      devTrace('mcp.req.error', {'error': '$e'});
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {/* response may already be committed */}
    }
  }

  StreamableHTTPServerTransport? _transportFor(HttpRequest req) {
    final sid = req.headers.value('mcp-session-id');
    return sid == null ? null : _transports[sid];
  }

  Future<void> _handlePost(HttpRequest req) async {
    final body = jsonDecode(utf8.decode(await _collectBytes(req)));
    final sid = req.headers.value('mcp-session-id');

    if (sid != null && _transports.containsKey(sid)) {
      await _transports[sid]!.handleRequest(req, body);
      return;
    }
    if (sid == null && _isInitialize(body)) {
      late final StreamableHTTPServerTransport transport;
      transport = StreamableHTTPServerTransport(
        options: StreamableHTTPServerTransportOptions(
          sessionIdGenerator: () => generateUUID(),
          onsessioninitialized: (id) {
            _transports[id] = transport;
            notifyListeners(); // agentConnected may flip true
          },
        ),
      );
      transport.onclose = () {
        final id = transport.sessionId;
        if (id != null) _transports.remove(id);
        notifyListeners(); // agentConnected may flip false
      };
      // Each session gets its own McpServer (one transport per server in
      // mcp_dart); the tool closures all capture this service + the shared
      // store, so behaviour is identical across sessions.
      await _buildServer().connect(transport);
      await transport.handleRequest(req, body);
      return;
    }
    await _badRequest(
        req, 'No valid session ID provided or not an initialize request');
  }

  Future<void> _badRequest(HttpRequest req, String message) async {
    req.response
      ..statusCode = HttpStatus.badRequest
      ..headers.set(HttpHeaders.contentTypeHeader, 'application/json')
      ..write(jsonEncode({'error': message}));
    await req.response.close();
  }

  static bool _isInitialize(dynamic body) =>
      body is Map<String, dynamic> && body['method'] == 'initialize';

  static Future<List<int>> _collectBytes(HttpRequest req) {
    final out = <int>[];
    final done = Completer<List<int>>();
    req.listen(
      out.addAll,
      onDone: () => done.complete(out),
      onError: done.completeError,
      cancelOnError: true,
    );
    return done.future;
  }

  // ── Tool catalog ──────────────────────────────────────────────────────

  McpServer _buildServer() {
    final server = McpServer(
      const Implementation(name: 'bxp-gui', version: '0.2.4'),
    );

    // get_state — read-only "see the screen" tool. The single biggest
    // value: the agent reads the live config/run/diagnostic state without
    // any screenshot.
    server.registerTool(
      'get_state',
      description:
          'Read the live GUI state: loaded config path, unsaved-changes '
          'flag, run status, a diagnostics summary, and the active template. '
          'Use this to "see the screen" before acting.',
      inputSchema: JsonSchema.object(properties: const {}, required: const []),
      annotations: const ToolAnnotations(
        title: 'Get GUI state',
        readOnlyHint: true,
        openWorldHint: false,
      ),
      callback: (args, extra) async {
        final state = stateJson();
        _record('get_state',
            _host.configPath.isEmpty ? '(no config loaded)' : _host.configPath,
            'ok');
        return _json(state);
      },
    );

    // edit_node — mutate a scalar leaf through the SAME action the UI uses.
    // Live + undoable; the tree repaints because editConfigNode notifies.
    server.registerTool(
      'edit_node',
      description:
          'Edit a scalar leaf in the loaded config. `path` is the list of '
          'keys/indices from the config root to the leaf; `value` is the new '
          'scalar. Routed through the same live, undoable edit action the UI '
          'uses. Blocked when the config was loaded with errors.',
      inputSchema: JsonSchema.object(
        properties: {
          'path': JsonSchema.array(
            items: JsonSchema.string(),
            description: 'Keys/indices from the config root to the leaf.',
          ),
          'value': JsonSchema.fromJson(const {
            'description': 'New scalar value (string / number / boolean).',
          }),
        },
        required: const ['path', 'value'],
      ),
      annotations: const ToolAnnotations(title: 'Edit config node'),
      callback: (args, extra) async {
        final rawPath = args['path'];
        if (rawPath is! List || rawPath.isEmpty) {
          _record('edit_node', '$rawPath', 'error');
          return _error('`path` must be a non-empty array of keys/indices.');
        }
        final path = rawPath.map((e) => '$e').toList();
        final value = args['value'];
        if (_host.configLoadHadErrors) {
          _record('edit_node', path.join('.'), 'blocked');
          return _error(
              'Edits are blocked: the config was loaded with errors. '
              'Fix the load errors first.');
        }
        _host.editConfigNode(path, value);
        final errs = _host.errorsAt(path);
        _record('edit_node', '${path.join('.')} = ${jsonEncode(value)}',
            errs.isEmpty ? 'ok' : 'error');
        return _json({
          'edited': path,
          'value': value,
          'isDirty': _host.isDirty,
          'errorsAtPath': errs,
        });
      },
    );

    // save — critical action: writes to disk. Gated by a user confirm
    // dialog. The tool BLOCKS until the user clicks; cancel/no-UI returns a
    // {rejected} result rather than hanging.
    server.registerTool(
      'save',
      description:
          'Save the edited config back to disk (atomic + validated). Asks '
          'the user to confirm before writing. No-op when there are no '
          'unsaved changes.',
      inputSchema: JsonSchema.object(properties: const {}, required: const []),
      annotations: const ToolAnnotations(title: 'Save config'),
      callback: (args, extra) async {
        if (!_host.isDirty) {
          _record('save', 'no unsaved changes', 'ok');
          return _json({'saved': false, 'reason': 'no unsaved changes'});
        }
        final approved = await _confirm(
          'Agent wants to save the config',
          'The agent is requesting to write '
              '${_host.configPath.isEmpty ? "the config" : _host.configPath} '
              'to disk.',
        );
        if (!approved) {
          _record('save', _host.configPath, 'rejected');
          return _json({'saved': false, 'rejected': true});
        }
        await _host.saveConfig();
        final err = _host.configSaveError;
        _record('save', _host.configPath, err == null ? 'ok' : 'error');
        return _json({
          'saved': err == null,
          'error': ?err,
        });
      },
    );

    // open_config — load a config file from disk (replaces the current one).
    server.registerTool(
      'open_config',
      description:
          'Load a config file from disk into the editor, replacing the '
          'current one. `path` is an absolute filesystem path.',
      inputSchema: JsonSchema.object(
        properties: {
          'path': JsonSchema.string(
            description: 'Absolute path to the config file.',
          ),
        },
        required: const ['path'],
      ),
      annotations: const ToolAnnotations(title: 'Open config'),
      callback: (args, extra) async {
        final path = args['path'];
        if (path is! String || path.isEmpty) {
          _record('open_config', '$path', 'error');
          return _error('`path` must be a non-empty string.');
        }
        _host.setConfigPath(path);
        await _host.loadConfig();
        final err = _host.configError;
        _record('open_config', path, err == null ? 'ok' : 'error');
        return _json({
          'opened': err == null,
          'configPath': _host.configPath,
          'loadedWithErrors': _host.configLoadHadErrors,
          'error': ?err,
        });
      },
    );

    // reload — re-read the active config from disk (drops unsaved edits).
    server.registerTool(
      'reload',
      description:
          'Reload the active config from disk, discarding unsaved edits. '
          'Fails when no config is open.',
      inputSchema: JsonSchema.object(properties: const {}, required: const []),
      annotations: const ToolAnnotations(title: 'Reload config'),
      callback: (args, extra) async {
        if (_host.configPath.isEmpty) {
          _record('reload', '(none)', 'error');
          return _error('No config is open to reload.');
        }
        await _host.loadConfig();
        final err = _host.configError;
        _record('reload', _host.configPath, err == null ? 'ok' : 'error');
        return _json({
          'reloaded': err == null,
          'loadedWithErrors': _host.configLoadHadErrors,
          'error': ?err,
        });
      },
    );

    // dry_run — run bxp-cli without writing output files.
    server.registerTool(
      'dry_run',
      description:
          'Run the conversion in dry-run mode (no output files written). '
          'Returns the run status and exit code.',
      inputSchema: JsonSchema.object(properties: const {}, required: const []),
      annotations: const ToolAnnotations(title: 'Dry run'),
      callback: (args, extra) async {
        if (_host.configPath.isEmpty) {
          _record('dry_run', '(none)', 'error');
          return _error('No config is open to run.');
        }
        await _host.runDryRun();
        return _runResult('dry_run');
      },
    );

    // full_run — critical: writes output files. Confirmed.
    server.registerTool(
      'full_run',
      description:
          'Run the full conversion, writing output files to the configured '
          'data_dir. Asks the user to confirm first.',
      inputSchema: JsonSchema.object(properties: const {}, required: const []),
      annotations: const ToolAnnotations(title: 'Full run'),
      callback: (args, extra) async {
        if (_host.configPath.isEmpty) {
          _record('full_run', '(none)', 'error');
          return _error('No config is open to run.');
        }
        final approved = await _confirm(
          'Agent wants to run the full conversion',
          'The agent is requesting a full run of ${_host.configPath}, which '
              'writes output files to disk.',
        );
        if (!approved) {
          _record('full_run', _host.configPath, 'rejected');
          return _json({'ran': false, 'rejected': true});
        }
        await _host.runFullRun();
        return _runResult('full_run');
      },
    );

    // delete_node — critical: removes a config entry. Confirmed.
    server.registerTool(
      'delete_node',
      description:
          'Delete the config entry at `path` (the same action as the tree '
          'delete button). Asks the user to confirm. Blocked when the config '
          'was loaded with errors.',
      inputSchema: JsonSchema.object(
        properties: {
          'path': JsonSchema.array(
            items: JsonSchema.string(),
            description: 'Keys/indices from the config root to the entry.',
          ),
        },
        required: const ['path'],
      ),
      annotations: const ToolAnnotations(title: 'Delete config node'),
      callback: (args, extra) async {
        final rawPath = args['path'];
        if (rawPath is! List || rawPath.isEmpty) {
          _record('delete_node', '$rawPath', 'error');
          return _error('`path` must be a non-empty array of keys/indices.');
        }
        final path = rawPath.map((e) => '$e').toList();
        if (_host.configLoadHadErrors) {
          _record('delete_node', path.join('.'), 'blocked');
          return _error(
              'Deletes are blocked: the config was loaded with errors. '
              'Fix the load errors first.');
        }
        final approved = await _confirm(
          'Agent wants to delete a config node',
          'The agent is requesting to delete `${path.join('.')}`.',
        );
        if (!approved) {
          _record('delete_node', path.join('.'), 'rejected');
          return _json({'deleted': false, 'rejected': true});
        }
        _host.deleteConfigNode(path);
        _record('delete_node', path.join('.'), 'ok');
        return _json({'deleted': true, 'path': path, 'isDirty': _host.isDirty});
      },
    );

    // get_trace — read-only summary of the most recent run's btrace data.
    server.registerTool(
      'get_trace',
      description:
          'Summarise the most recent dry/full run captured via btrace: '
          'per-file row counts + file_end stats, total traced rows, exit '
          'code, and any parse issues. `trace` is null when no run has '
          'happened yet.',
      inputSchema: JsonSchema.object(properties: const {}, required: const []),
      annotations: const ToolAnnotations(
        title: 'Get run trace',
        readOnlyHint: true,
        openWorldHint: false,
      ),
      callback: (args, extra) async {
        final summary = _host.traceSummary();
        _record(
          'get_trace',
          summary == null ? '(no run)' : '${summary['fileCount']} file(s)',
          'ok',
        );
        return _json({'trace': summary});
      },
    );

    // exit — critical: quits the app. Confirmed. The response is returned
    // before the process is torn down so the agent gets a clean reply.
    server.registerTool(
      'exit',
      description: 'Quit the bxp-gui application. Asks the user to confirm.',
      inputSchema: JsonSchema.object(properties: const {}, required: const []),
      annotations: const ToolAnnotations(title: 'Exit app'),
      callback: (args, extra) async {
        final approved = await _confirm(
          'Agent wants to close the app',
          'The agent is requesting to quit bxp-gui.',
        );
        if (!approved) {
          _record('exit', '', 'rejected');
          return _json({'exiting': false, 'rejected': true});
        }
        _record('exit', '', 'ok');
        // Defer teardown so this response flushes to the agent first.
        unawaited(
            Future.delayed(const Duration(milliseconds: 250), _host.exitApp));
        return _json({'exiting': true});
      },
    );

    return server;
  }

  /// Shared shape for the dry/full run tools: status + exit code + error.
  CallToolResult _runResult(String tool) {
    final err = _host.runError;
    final ok = err == null && _host.runStatusName != 'error';
    _record(tool, _host.configPath, ok ? 'ok' : 'error');
    return _json({
      'status': _host.runStatusName,
      'exitCode': _host.lastExitCode,
      'runError': ?err,
    });
  }

  /// JSON snapshot of the live GUI state. Public so the test can assert its
  /// shape directly.
  Map<String, dynamic> stateJson() {
    final diag = _host.diagnosticBlob;
    return {
      'configPath': _host.configPath,
      'isDirty': _host.isDirty,
      'loadedWithErrors': _host.configLoadHadErrors,
      'hasErrors': _host.configHasErrors,
      'status': _host.runStatusName,
      'runMode': _host.runModeName,
      'lastExitCode': _host.lastExitCode,
      'activeTemplate': _host.activeTemplate,
      'diagnostics': diag.isEmpty ? const <String>[] : diag.split('\n'),
    };
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  void _record(String tool, String summary, String outcome) {
    _activity.insert(0,
        AgentActivityEntry(time: DateTime.now(), tool: tool, summary: summary, outcome: outcome));
    if (_activity.length > _activityCap) {
      _activity.removeRange(_activityCap, _activity.length);
    }
    notifyListeners();
  }

  static CallToolResult _json(Map<String, dynamic> data) =>
      CallToolResult.fromContent([TextContent(text: jsonEncode(data))]);

  static CallToolResult _error(String message) => CallToolResult(
        content: [TextContent(text: message)],
        isError: true,
      );
}
