import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'dev_trace.dart';

/// Thrown when an incoming HTTP request body exceeds the accumulation cap
/// (see `GuiMcpServer._kMaxRequestBodyBytes`). Surfaced to the caller as a
/// `413 Request Entity Too Large` instead of an unbounded read.
class _RequestBodyTooLarge implements Exception {}

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

  /// Counter bumped on every APPLIED config mutation; unchanged when the
  /// store silently refuses one (required/duplicate key, out-of-range move).
  /// The structural tools compare it before/after so they never report
  /// success on a no-op.
  int get editRevision;

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

  /// Insert a child into the container at [path] — the same action as the
  /// tree insert. For an object container pass [newKey]; for an array pass
  /// `null` (append) or an [atIndex] position. [value] is the entry value.
  void insertConfigNode(List<String> path, String? newKey, dynamic value,
      {int? atIndex});

  /// Rename the object key at [path] to [newKey] — the same action as the
  /// tree rename.
  void renameConfigKey(List<String> path, String newKey);

  /// Reorder the entry at [path] by [delta] (+1 down / -1 up) — the same
  /// action as the tree move.
  void moveConfigNode(List<String> path, int delta);

  /// Conversion template ids declared in the loaded config.
  List<String> get availableTemplates;

  /// Set the active conversion template dry/full runs target — the same as
  /// the GUI's template selector. Empty string = run all templates.
  void setActiveTemplate(String id);

  /// Project one input row of the most recent run to JSON: source fields,
  /// variable evaluations, rule decisions, and output rows. Lazy-loads the
  /// row's detail on demand. Null when no run trace exists.
  Future<Map<String, dynamic>?> rowDetail({required int fileRow, String? file});

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

  /// Bring the CONFIG panel to the front (mirrors clicking the CONFIG tab).
  void showConfigPanel();

  /// Bring the RUNNER panel to the front (mirrors clicking the RUNNER tab).
  void showRunnerPanel();

  /// Expand ancestors of [path], scroll it into view, and highlight it —
  /// so an agent edit/delete is visible where it happens.
  void revealConfigNode(List<String> path);
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

/// One gui-mcp tool, catalogued. The 15 tools live as a browsable
/// `List<GuiToolDoc>` (name + arg schema + annotations + handler) instead of
/// 15 inline `registerTool` calls — the same "catalogue, don't inline" shape
/// as `FnDoc` / `FieldDoc` / `ShortcutDoc`. [GuiMcpServer._buildServer]
/// registers each entry in a loop, so nothing hand-maintains a parallel list.
///
/// Built per server instance rather than as a `const`: every [callback] closes
/// over instance state (`_host`, `_record`, the `_json` / `_error` / confirm
/// helpers), so the catalogue cannot be static.
class GuiToolDoc {
  /// MCP tool id — the wire name an agent calls (and the `tools/list` name).
  final String name;

  /// Agent-facing description surfaced in `tools/list`.
  final String description;

  /// JSON-Schema for the tool's arguments object.
  final JsonObject inputSchema;

  /// Behaviour hints (title, read-only / open-world) shown in `tools/list`.
  final ToolAnnotations annotations;

  /// Handler invoked on a `tools/call`.
  final ToolFunction callback;

  const GuiToolDoc(
    this.name, {
    required this.description,
    required this.inputSchema,
    required this.annotations,
    required this.callback,
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
  GuiMcpServer(this._host, {required AgentConfirmFn confirm, bool autoApprove = false})
      : _confirm = confirm,
        _autoApprove = autoApprove;

  final GuiMcpHost _host;
  final AgentConfirmFn _confirm;

  bool _autoApprove;

  /// True when destructive-action confirmation dialogs are auto-approved
  /// without prompting. Seeded from `BXP_GUI_MCP_AUTO_APPROVE` at startup and
  /// overlaid with the persisted `bxp-gui.mcpAutoApprove` pref (the inspector
  /// toggle) once prefs load — so it is the single live source of truth for
  /// both the confirm gate ([_confirmAction]) and the report below. Surfaced
  /// in `/health` + `get_state` (and the red status-bar chip) so a driving
  /// agent — and a watching user — can see the gate is off.
  bool get autoApprove => _autoApprove;
  set autoApprove(bool value) {
    if (_autoApprove == value) return;
    _autoApprove = value;
    notifyListeners();
  }

  /// Confirm gate for a destructive tool: short-circuits to `true` (no prompt)
  /// when [autoApprove] is on, otherwise defers to the injected [_confirm]
  /// dialog. One place so every destructive tool honours the toggle.
  Future<bool> _confirmAction(String title, String detail) async {
    if (_autoApprove) return true;
    return _confirm(title, detail);
  }

  /// Path the MCP endpoint is served from.
  static const String mcpPath = '/mcp';
  static const int _activityCap = 200;

  /// Reported in the MCP `Implementation` handshake and the `/health` probe.
  /// Cached from [PackageInfo] in [start] so it tracks the real app version
  /// (pubspec → Runner resource) instead of drifting from a hand-bumped
  /// literal every release. Stays `'unknown'` only if the platform channel
  /// fails before the first bind — better to report unknown than to lie.
  String _version = 'unknown';
  bool _versionLoaded = false;

  /// Populate [_version] from [PackageInfo] once. Awaited in [start] before
  /// the socket binds, so both `/health` and the MCP handshake (which can
  /// only fire after the server is listening) read the resolved value.
  Future<void> _ensureVersionLoaded() async {
    if (_versionLoaded) return;
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) _version = info.version;
    } catch (e) {
      devTrace('mcp.version.error', {'error': '$e'});
    }
    _versionLoaded = true;
  }

  /// Default loopback host the control server binds to.
  static const String kDefaultMcpHost = '127.0.0.1';

  /// Default TCP port. Fixed (not OS-assigned) so an external agent can
  /// reach the server on a known endpoint without a discovery file; the
  /// user can change host + port in the settings inspector.
  static const int kDefaultMcpPort = 7717;

  HttpServer? _http;
  StreamSubscription<HttpRequest>? _sub;
  final Map<String, StreamableHTTPServerTransport> _transports = {};

  // Desired bind config (the actual bound port is read back via [port]).
  String _bindHost = kDefaultMcpHost;
  int _bindPort = kDefaultMcpPort;
  // Empty = accept every Origin (default; webview agents must keep working).
  List<String> _originAllowlist = const [];

  final List<AgentActivityEntry> _activity = [];
  String? _lastError;

  bool get isRunning => _http != null;
  int? get port => _http?.port;

  /// The host the server is (or will next be) bound to.
  String get configuredHost => _bindHost;

  /// The port the server is (or will next be) bound to.
  int get configuredPort => _bindPort;

  /// Origins allowed when non-empty; empty (default) accepts all.
  List<String> get originAllowlist => List.unmodifiable(_originAllowlist);

  /// True while at least one agent session is connected.
  bool get agentConnected => _transports.isNotEmpty;

  /// Last bind/serve failure, surfaced in the inspector. Null when healthy.
  String? get lastError => _lastError;

  /// Most-recent-first view of the activity log.
  List<AgentActivityEntry> get activity => List.unmodifiable(_activity);

  /// Clear the agent activity log (the inspector's "Clear" action).
  void clearActivity() {
    if (_activity.isEmpty) return;
    _activity.clear();
    notifyListeners();
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────

  /// Bind the loopback HTTP server and start serving MCP. [port] `0` lets
  /// the OS assign a free port (read back via [port]). A bind failure is
  /// NOT fatal — it is recorded in [lastError] and surfaced in the inspector
  /// (unlike the bridge library, the GUI is fully usable without the agent
  /// server).
  Future<void> start(
      {String? host, int? port, List<String>? originAllowlist}) async {
    if (isRunning) return;
    if (host != null) _bindHost = host;
    if (port != null) _bindPort = port;
    if (originAllowlist != null) _originAllowlist = List.of(originAllowlist);
    _lastError = null;
    await _ensureVersionLoaded();
    try {
      final http = await HttpServer.bind(_resolveBindAddress(_bindHost), _bindPort);
      _http = http;
      _sub = http.listen(
        _handleRequest,
        onError: (Object e) => devTrace('mcp.http.error', {'error': '$e'}),
      );
      devTrace('mcp.start', {'host': _bindHost, 'port': http.port});
    } catch (e) {
      _lastError = '$e';
      _http = null;
      devTrace('mcp.start.error', {'error': '$e'});
    }
    notifyListeners();
  }

  /// Stop, then re-bind with new settings. Used by the inspector's Apply
  /// action; idempotent on the stop side.
  Future<void> restart(
      {String? host, int? port, List<String>? originAllowlist}) async {
    await stop();
    await start(host: host, port: port, originAllowlist: originAllowlist);
  }

  /// Parse [host] to a bind address, falling back to loopback for a
  /// hostname (e.g. `localhost`) or an unparseable value. An IP literal
  /// like `0.0.0.0` binds all interfaces (the user's explicit choice).
  static InternetAddress _resolveBindAddress(String host) {
    if (host == 'localhost' || host.isEmpty) {
      return InternetAddress.loopbackIPv4;
    }
    return InternetAddress.tryParse(host) ?? InternetAddress.loopbackIPv4;
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
    final path = req.uri.path;
    // Unauthenticated health probe — lets an agent confirm it reached the
    // right server (and whether a config is open) before the MCP handshake.
    if (req.method == 'GET' && (path == '/health' || path == '/')) {
      await _handleHealth(req);
      return;
    }
    if (path != mcpPath) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    if (!_originAllowed(req)) {
      req.response.statusCode = HttpStatus.forbidden;
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

  /// Origin policy. An empty allowlist (the default) accepts every request —
  /// webview-based agents send the page's `Origin` and must keep working;
  /// the loopback bind is the baseline protection. When the user configures
  /// an allowlist (typically after binding to a network interface), a
  /// present `Origin` must be on it; a missing `Origin` (native MCP agents)
  /// is always allowed.
  ///
  /// SECURITY TRADEOFF: with the permissive default, a malicious web page the
  /// user visits can `fetch()` this endpoint and execute the additive/edit
  /// tools server-side (CORS blocks the page from *reading* the reply, not the
  /// action). Destructive tools stay confirm-gated — UNLESS `autoApprove` is
  /// persisted on, in which case permissive-origin + auto-approve = fully
  /// unauthenticated local-web control (the red status chip is the only
  /// signal). To lock this down, set an `Origin` allowlist (or bind loopback
  /// only and keep auto-approve off). Defaulting to deny-browser-origins would
  /// break webview agents that send an `Origin`, so the safe default is left
  /// to the user's configuration.
  bool _originAllowed(HttpRequest req) {
    if (_originAllowlist.isEmpty) return true;
    final origin = req.headers.value('origin');
    if (origin == null) return true;
    return _originAllowlist.contains(origin);
  }

  Future<void> _handleHealth(HttpRequest req) async {
    if (!_originAllowed(req)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final body = jsonEncode({
      'name': 'bxp-gui',
      'version': _version,
      'config_path': _host.configPath,
      'config_loaded': _host.configPath.isNotEmpty,
      'loaded_with_errors': _host.configLoadHadErrors,
      'dirty': _host.isDirty,
      'agent_connected': agentConnected,
      'auto_approve': autoApprove,
    });
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.set(HttpHeaders.contentTypeHeader, 'application/json')
      ..write(body);
    await req.response.close();
  }

  StreamableHTTPServerTransport? _transportFor(HttpRequest req) {
    final sid = req.headers.value('mcp-session-id');
    return sid == null ? null : _transports[sid];
  }

  Future<void> _handlePost(HttpRequest req) async {
    final List<int> raw;
    try {
      raw = await _collectBytes(req);
    } on _RequestBodyTooLarge {
      // Bound the accumulation before any session/initialize work — an
      // unauthenticated POST (permissive-origin default) must not be able to
      // stream a multi-GB body into memory. MCP requests are tiny.
      req.response.statusCode = HttpStatus.requestEntityTooLarge;
      await req.response.close();
      return;
    }
    final body = jsonDecode(utf8.decode(raw));
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

  /// Upper bound on an accumulated request body. MCP JSON-RPC requests are
  /// kilobytes at most; this caps a hostile/runaway POST well below OOM range.
  static const int _kMaxRequestBodyBytes = 8 * 1024 * 1024;

  static Future<List<int>> _collectBytes(HttpRequest req) {
    final out = <int>[];
    final done = Completer<List<int>>();
    late final StreamSubscription<List<int>> sub;
    sub = req.listen(
      (chunk) {
        if (out.length + chunk.length > _kMaxRequestBodyBytes) {
          sub.cancel();
          if (!done.isCompleted) done.completeError(_RequestBodyTooLarge());
          return;
        }
        out.addAll(chunk);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(out);
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      cancelOnError: true,
    );
    return done.future;
  }

  // ── Tool catalog ──────────────────────────────────────────────────────

  McpServer _buildServer() {
    final server = McpServer(
      Implementation(name: 'bxp-gui', version: _version),
    );
    for (final tool in _toolCatalog()) {
      server.registerTool(
        tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
        annotations: tool.annotations,
        callback: tool.callback,
      );
    }
    return server;
  }

  /// The gui-mcp tool catalogue — one [GuiToolDoc] per agent-callable tool, in
  /// `tools/list` order. Built per-instance because each callback closes over
  /// this server's `_host` / `_record` / state helpers; [_buildServer]
  /// registers every entry in a loop, so there is no parallel hand-kept list.
  List<GuiToolDoc> _toolCatalog() {
    final tools = <GuiToolDoc>[];

    // get_state — read-only "see the screen" tool. The single biggest
    // value: the agent reads the live config/run/diagnostic state without
    // any screenshot.
    tools.add(GuiToolDoc(
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
    ));

    // edit_node — mutate a scalar leaf through the SAME action the UI uses.
    // Live + undoable; the tree repaints because editConfigNode notifies.
    tools.add(GuiToolDoc(
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
        _host.showConfigPanel();
        _host.editConfigNode(path, value);
        _host.revealConfigNode(path);
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
    ));

    // save — critical action: writes to disk. Gated by a user confirm
    // dialog. The tool BLOCKS until the user clicks; cancel/no-UI returns a
    // {rejected} result rather than hanging.
    tools.add(GuiToolDoc(
      'save',
      description:
          'Save the edited config back to disk (atomic + validated). Asks '
          'the user to confirm before writing. No-op when there are no '
          'unsaved changes.',
      inputSchema: JsonSchema.object(properties: const {}, required: const []),
      annotations: const ToolAnnotations(title: 'Save config'),
      callback: (args, extra) async {
        _host.showConfigPanel();
        if (!_host.isDirty) {
          _record('save', 'no unsaved changes', 'ok');
          return _json({'saved': false, 'reason': 'no unsaved changes'});
        }
        final approved = await _confirmAction(
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
    ));

    // open_config — load a config file from disk (replaces the current one).
    tools.add(GuiToolDoc(
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
        _host.showConfigPanel();
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
    ));

    // reload — re-read the active config from disk (drops unsaved edits).
    tools.add(GuiToolDoc(
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
        _host.showConfigPanel();
        await _host.loadConfig();
        final err = _host.configError;
        _record('reload', _host.configPath, err == null ? 'ok' : 'error');
        return _json({
          'reloaded': err == null,
          'loadedWithErrors': _host.configLoadHadErrors,
          'error': ?err,
        });
      },
    ));

    // dry_run — run bxp-cli without writing output files.
    tools.add(GuiToolDoc(
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
        _host.showRunnerPanel();
        await _host.runDryRun();
        return _runResult('dry_run');
      },
    ));

    // full_run — critical: writes output files. Confirmed.
    tools.add(GuiToolDoc(
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
        final approved = await _confirmAction(
          'Agent wants to run the full conversion',
          'The agent is requesting a full run of ${_host.configPath}, which '
              'writes output files to disk.',
        );
        if (!approved) {
          _record('full_run', _host.configPath, 'rejected');
          return _json({'ran': false, 'rejected': true});
        }
        _host.showRunnerPanel();
        await _host.runFullRun();
        return _runResult('full_run');
      },
    ));

    // delete_node — critical: removes a config entry. Confirmed.
    tools.add(GuiToolDoc(
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
        // Reveal the target before asking, so the user sees what the agent
        // is about to delete while the confirm dialog is up.
        _host.showConfigPanel();
        _host.revealConfigNode(path);
        final approved = await _confirmAction(
          'Agent wants to delete a config node',
          'The agent is requesting to delete `${path.join('.')}`.',
        );
        if (!approved) {
          _record('delete_node', path.join('.'), 'rejected');
          return _json({'deleted': false, 'rejected': true});
        }
        final rev0 = _host.editRevision;
        _host.deleteConfigNode(path);
        final changed = _host.editRevision != rev0;
        _record('delete_node', path.join('.'), changed ? 'ok' : 'error');
        return _json({
          'deleted': changed,
          'path': path,
          'isDirty': _host.isDirty,
          if (!changed)
            'reason': 'The store refused the delete — the node is likely a '
                'schema-required key, or the path did not resolve.',
        });
      },
    ));

    // insert_node — add a child to a container via the SAME action the UI
    // uses. Additive (not destructive), so no confirm — like edit_node.
    tools.add(GuiToolDoc(
      'insert_node',
      description:
          'Insert a new entry into a container in the loaded config. `path` '
          'is the keys/indices to the CONTAINER (object or array); pass `[]` '
          'for the root object. For an object container pass `key` (the new '
          'property name); for an array omit `key` to append or pass `index` '
          'for the position. `value` is the new entry (scalar, object, or '
          'array). Routed through the same live, undoable insert the UI uses. '
          'Blocked when the config was loaded with errors.',
      inputSchema: JsonSchema.object(
        properties: {
          'path': JsonSchema.array(
            items: JsonSchema.string(),
            description: 'Keys/indices to the container ([] = root object).',
          ),
          'key': JsonSchema.string(
            description: 'New property name (object containers only).',
          ),
          'value': JsonSchema.fromJson(const {
            'description': 'New entry value (scalar / object / array).',
          }),
          'index': JsonSchema.fromJson(const {
            'type': 'integer',
            'description': 'Insertion position (array containers; optional).',
          }),
        },
        required: const ['path', 'value'],
      ),
      annotations: const ToolAnnotations(title: 'Insert config node'),
      callback: (args, extra) async {
        final rawPath = args['path'];
        if (rawPath is! List) {
          _record('insert_node', '$rawPath', 'error');
          return _error('`path` must be an array of keys/indices.');
        }
        final path = rawPath.map((e) => '$e').toList();
        if (_host.configLoadHadErrors) {
          _record('insert_node', path.join('.'), 'blocked');
          return _error(
              'Inserts are blocked: the config was loaded with errors. '
              'Fix the load errors first.');
        }
        final key = args['key'] is String ? args['key'] as String : null;
        final value = args['value'];
        final index = args['index'] is num ? (args['index'] as num).toInt() : null;
        _host.showConfigPanel();
        final rev0 = _host.editRevision;
        _host.insertConfigNode(path, key, value, atIndex: index);
        final changed = _host.editRevision != rev0;
        // Reveal the inserted child where its path is known (object case).
        if (changed) {
          _host.revealConfigNode(key != null ? [...path, key] : path);
        }
        _record(
          'insert_node',
          '${path.join('.')}${key != null ? '.$key' : '[]'} = ${jsonEncode(value)}',
          changed ? 'ok' : 'error',
        );
        return _json({
          'inserted': changed,
          'path': path,
          'key': ?key,
          'isDirty': _host.isDirty,
          if (!changed)
            'reason': 'The store refused the insert — the container did not '
                'resolve, an object key is missing/duplicate, or it was '
                'schema-rejected.',
        });
      },
    ));

    // rename_key — rename an object key via the SAME action the UI uses.
    tools.add(GuiToolDoc(
      'rename_key',
      description:
          'Rename the object key at `path` to `new_key` (the same action as '
          'the tree rename). `path` ends at the property being renamed. '
          'Blocked when the config was loaded with errors.',
      inputSchema: JsonSchema.object(
        properties: {
          'path': JsonSchema.array(
            items: JsonSchema.string(),
            description: 'Keys/indices from the config root to the property.',
          ),
          'new_key': JsonSchema.string(description: 'The new property name.'),
        },
        required: const ['path', 'new_key'],
      ),
      annotations: const ToolAnnotations(title: 'Rename config key'),
      callback: (args, extra) async {
        final rawPath = args['path'];
        final newKey = args['new_key'];
        if (rawPath is! List || rawPath.isEmpty) {
          _record('rename_key', '$rawPath', 'error');
          return _error('`path` must be a non-empty array of keys/indices.');
        }
        if (newKey is! String || newKey.isEmpty) {
          _record('rename_key', rawPath.join('.'), 'error');
          return _error('`new_key` must be a non-empty string.');
        }
        final path = rawPath.map((e) => '$e').toList();
        if (_host.configLoadHadErrors) {
          _record('rename_key', path.join('.'), 'blocked');
          return _error(
              'Renames are blocked: the config was loaded with errors. '
              'Fix the load errors first.');
        }
        _host.showConfigPanel();
        final rev0 = _host.editRevision;
        _host.renameConfigKey(path, newKey);
        final changed = _host.editRevision != rev0;
        final newPath = [...path.sublist(0, path.length - 1), newKey];
        if (changed) _host.revealConfigNode(newPath);
        _record('rename_key', '${path.join('.')} -> $newKey',
            changed ? 'ok' : 'error');
        return _json({
          'renamed': changed,
          'path': changed ? newPath : path,
          'isDirty': _host.isDirty,
          if (!changed)
            'reason': 'The store refused the rename — the new key may collide '
                'with a sibling, the parent is not an object, or the path did '
                'not resolve.',
        });
      },
    ));

    // move_node — reorder an entry among its siblings (non-destructive).
    tools.add(GuiToolDoc(
      'move_node',
      description:
          'Reorder the entry at `path` among its siblings by `delta` '
          '(+1 = down/later, -1 = up/earlier). Works for both object '
          'properties and array elements. Blocked when the config was loaded '
          'with errors.',
      inputSchema: JsonSchema.object(
        properties: {
          'path': JsonSchema.array(
            items: JsonSchema.string(),
            description: 'Keys/indices from the config root to the entry.',
          ),
          'delta': JsonSchema.fromJson(const {
            'type': 'integer',
            'description': 'Positions to move: +1 down, -1 up.',
          }),
        },
        required: const ['path', 'delta'],
      ),
      annotations: const ToolAnnotations(title: 'Move config node'),
      callback: (args, extra) async {
        final rawPath = args['path'];
        final rawDelta = args['delta'];
        if (rawPath is! List || rawPath.isEmpty) {
          _record('move_node', '$rawPath', 'error');
          return _error('`path` must be a non-empty array of keys/indices.');
        }
        if (rawDelta is! num || rawDelta == 0) {
          _record('move_node', rawPath.join('.'), 'error');
          return _error('`delta` must be a non-zero integer (+1 / -1).');
        }
        final path = rawPath.map((e) => '$e').toList();
        final delta = rawDelta.toInt();
        if (_host.configLoadHadErrors) {
          _record('move_node', path.join('.'), 'blocked');
          return _error(
              'Moves are blocked: the config was loaded with errors. '
              'Fix the load errors first.');
        }
        _host.showConfigPanel();
        final rev0 = _host.editRevision;
        _host.moveConfigNode(path, delta);
        final changed = _host.editRevision != rev0;
        if (changed) _host.revealConfigNode(path);
        _record('move_node', '${path.join('.')} delta=$delta',
            changed ? 'ok' : 'error');
        return _json({
          'moved': changed,
          'path': path,
          'isDirty': _host.isDirty,
          if (!changed)
            'reason': 'The store refused the move — already at the boundary, '
                'or the path did not resolve.',
        });
      },
    ));

    // set_template — choose which template dry/full runs target.
    tools.add(GuiToolDoc(
      'set_template',
      description:
          'Set the active conversion template that dry_run / full_run '
          'target. Pass an empty string to run ALL templates. Returns the '
          'available template ids so the agent can pick a valid one.',
      inputSchema: JsonSchema.object(
        properties: {
          'template': JsonSchema.string(
            description: 'Template id to activate, or "" for all templates.',
          ),
        },
        required: const ['template'],
      ),
      annotations: const ToolAnnotations(title: 'Set active template'),
      callback: (args, extra) async {
        final id = args['template'];
        if (id is! String) {
          _record('set_template', '$id', 'error');
          return _error('`template` must be a string ("" = all templates).');
        }
        final available = _host.availableTemplates;
        if (id.isNotEmpty && !available.contains(id)) {
          _record('set_template', id, 'error');
          return _error(
              'Unknown template "$id". Available: ${available.join(', ')}');
        }
        _host.setActiveTemplate(id);
        _record('set_template', id.isEmpty ? '(all templates)' : id, 'ok');
        return _json({
          'activeTemplate': _host.activeTemplate,
          'availableTemplates': available,
        });
      },
    ));

    // get_row_detail — drill into one input row of the most recent run.
    tools.add(GuiToolDoc(
      'get_row_detail',
      description:
          'Drill into one input row of the most recent run: its source '
          'field values, every input_schema/row_rules variable evaluation '
          '(value or error), the rule-match decisions, and any output rows '
          'produced. `file_row` is the 1-based source line number (as '
          'reported in the trace); `file` optionally disambiguates by path '
          'or template when the run spanned several files. Requires a prior '
          'dry_run / full_run.',
      inputSchema: JsonSchema.object(
        properties: {
          'file_row': JsonSchema.fromJson(const {
            'type': 'integer',
            'description': '1-based source line number to inspect.',
          }),
          'file': JsonSchema.string(
            description: 'Optional path or template id to disambiguate.',
          ),
        },
        required: const ['file_row'],
      ),
      annotations: const ToolAnnotations(
        title: 'Get row detail',
        readOnlyHint: true,
        openWorldHint: false,
      ),
      callback: (args, extra) async {
        final rawRow = args['file_row'];
        if (rawRow is! num) {
          _record('get_row_detail', '$rawRow', 'error');
          return _error('`file_row` must be an integer (1-based source line).');
        }
        final file = args['file'] is String ? args['file'] as String : null;
        final detail = await _host.rowDetail(fileRow: rawRow.toInt(), file: file);
        if (detail == null) {
          _record('get_row_detail', 'row $rawRow', 'error');
          return _error('No run trace available. Run dry_run or full_run first.');
        }
        _record('get_row_detail', 'row $rawRow',
            detail['found'] == true ? 'ok' : 'error');
        return _json(detail);
      },
    ));

    // get_trace — read-only summary of the most recent run's btrace data.
    tools.add(GuiToolDoc(
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
    ));

    // exit — critical: quits the app. Confirmed. The response is returned
    // before the process is torn down so the agent gets a clean reply.
    tools.add(GuiToolDoc(
      'exit',
      description: 'Quit the bxp-gui application. Asks the user to confirm.',
      inputSchema: JsonSchema.object(properties: const {}, required: const []),
      annotations: const ToolAnnotations(title: 'Exit app'),
      callback: (args, extra) async {
        final approved = await _confirmAction(
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
    ));

    return tools;
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
      'autoApprove': autoApprove,
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
