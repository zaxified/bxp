import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:bxp_gui/services/gui_mcp_server.dart';

/// In-memory [GuiMcpHost] so the server can be exercised end-to-end over
/// real HTTP without constructing a [TraceStore] (which would probe the
/// bridge library and touch the user's prefs file).
class _FakeHost implements GuiMcpHost {
  @override
  String configPath = '/tmp/example/bxp-cli.json';
  @override
  bool isDirty = false;
  @override
  bool configLoadHadErrors = false;
  @override
  bool configHasErrors = false;
  @override
  String runStatusName = 'idle';
  @override
  String runModeName = 'none';
  @override
  int? lastExitCode;
  @override
  String activeTemplate = '';
  @override
  String diagnosticBlob = '';
  @override
  String? configSaveError;
  @override
  String? configError;
  @override
  String? runError;

  /// When true, mutating methods become no-ops that do NOT bump
  /// [editRevision] — mimicking the store silently refusing a guarded edit
  /// (required/duplicate key, out-of-range move).
  bool refuseMutations = false;
  int _rev = 0;
  @override
  int get editRevision => _rev;

  Map<String, Map<String, String>> errorsByPath = {};
  final List<(List<String>, dynamic)> edits = [];
  final List<List<String>> deletes = [];
  final List<(List<String>, String?, dynamic, int?)> inserts = [];
  final List<(List<String>, String)> renames = [];
  final List<(List<String>, int)> moves = [];
  int saveCount = 0;
  int loadCount = 0;
  int dryRunCount = 0;
  int fullRunCount = 0;
  bool exitCalled = false;
  int configPanelShown = 0;
  int runnerPanelShown = 0;
  final List<List<String>> reveals = [];

  Map<String, dynamic>? trace;

  /// Canned reply for [validationSummary] — same shape TraceStore builds.
  Map<String, dynamic> validation = {
    'errors': 0,
    'warnings': 0,
    'info': 0,
    'findings': <Map<String, String>>[],
    'omitted': 0,
  };

  @override
  Map<String, dynamic> validationSummary() => validation;

  @override
  Map<String, String> errorsAt(List<String> path) =>
      errorsByPath[path.join('.')] ?? const {};

  @override
  Map<String, dynamic>? traceSummary() => trace;

  @override
  void editConfigNode(List<String> path, dynamic newValue) {
    edits.add((path, newValue));
    _rev++;
    isDirty = true;
  }

  @override
  void deleteConfigNode(List<String> path) {
    if (refuseMutations) return;
    deletes.add(path);
    _rev++;
    isDirty = true;
  }

  @override
  void insertConfigNode(List<String> path, String? newKey, dynamic value,
      {int? atIndex}) {
    if (refuseMutations) return;
    inserts.add((path, newKey, value, atIndex));
    _rev++;
    isDirty = true;
  }

  @override
  void renameConfigKey(List<String> path, String newKey) {
    if (refuseMutations) return;
    renames.add((path, newKey));
    _rev++;
    isDirty = true;
  }

  @override
  void moveConfigNode(List<String> path, int delta) {
    if (refuseMutations) return;
    moves.add((path, delta));
    _rev++;
    isDirty = true;
  }

  @override
  List<String> availableTemplates = ['alpha', 'beta'];

  @override
  void setActiveTemplate(String id) => activeTemplate = id;

  /// Canned detail returned by [rowDetail]; null mimics "no run trace yet".
  Map<String, dynamic>? rowDetailResult = {
    'found': true,
    'fileRow': 7,
    'fields': ['a', 'b'],
    'variables': [],
    'rules': [],
    'outputs': [],
  };
  final List<(int, String?)> rowDetailCalls = [];

  @override
  Future<Map<String, dynamic>?> rowDetail(
      {required int fileRow, String? file}) async {
    rowDetailCalls.add((fileRow, file));
    return rowDetailResult;
  }

  @override
  Future<void> saveConfig() async {
    saveCount++;
    isDirty = false;
  }

  @override
  void setConfigPath(String path) => configPath = path;

  @override
  Future<void> loadConfig() async {
    loadCount++;
    isDirty = false;
  }

  @override
  Future<void> runDryRun() async {
    dryRunCount++;
    runStatusName = 'done';
    lastExitCode = 0;
  }

  @override
  Future<void> runFullRun() async {
    fullRunCount++;
    runStatusName = 'done';
    lastExitCode = 0;
  }

  @override
  Future<void> exitApp() async {
    exitCalled = true;
  }

  @override
  void showConfigPanel() => configPanelShown++;

  @override
  void showRunnerPanel() => runnerPanelShown++;

  @override
  void revealConfigNode(List<String> path) => reveals.add(path);
}

/// Decodes the single TextContent JSON payload from a tool result.
Map<String, dynamic> _decode(CallToolResult result) {
  final item = result.content.single;
  return jsonDecode((item as TextContent).text) as Map<String, dynamic>;
}

void main() {
  // Seed PackageInfo so the server reports a known version instead of falling
  // back to 'unknown' (the plugin channel is absent in unit tests). This sets
  // a static cache directly — no widget binding, which would install Flutter's
  // HttpOverrides and break the real-HTTP server the tests bind. Locks in that
  // /health + the MCP handshake read the real app version, not a literal.
  PackageInfo.setMockInitialValues(
    appName: 'bxp-gui',
    packageName: 'app.bxp.gui',
    version: '9.9.9',
    buildNumber: '0',
    buildSignature: '',
  );

  late _FakeHost host;
  late GuiMcpServer server;
  late bool allowSave;
  McpClient? client;
  StreamableHttpClientTransport? transport;

  Future<McpClient> connect() async {
    final c = McpClient(
      const Implementation(name: 'test-client', version: '1.0.0'),
    );
    transport = StreamableHttpClientTransport(
      Uri.parse('http://127.0.0.1:${server.port}${GuiMcpServer.mcpPath}'),
      opts: const StreamableHttpClientTransportOptions(),
    );
    await c.connect(transport!);
    return c;
  }

  setUp(() async {
    host = _FakeHost();
    allowSave = true;
    server = GuiMcpServer(host, confirm: (_, _) async => allowSave);
    await server.start(port: 0); // ephemeral port (avoid the fixed default)
    expect(server.isRunning, isTrue);
    expect(server.port, isNotNull);
    client = await connect();
  });

  tearDown(() async {
    try {
      await transport?.close();
    } catch (_) {}
    await server.stop();
    expect(server.isRunning, isFalse);
  });

  test('lists the full tool set', () async {
    final tools = await client!.listTools();
    final names = tools.tools.map((t) => t.name).toSet();
    expect(
      names,
      containsAll(<String>{
        'get_state',
        'edit_node',
        'save',
        'open_config',
        'reload',
        'dry_run',
        'full_run',
        'delete_node',
        'exit',
        'get_trace',
        'insert_node',
        'rename_key',
        'move_node',
        'set_template',
        'get_row_detail',
      }),
    );
  });

  test('get_trace returns the run summary, null before any run', () async {
    final before = await client!.callTool(
      CallToolRequest(name: 'get_trace', arguments: const {}),
    );
    expect(_decode(before)['trace'], isNull);

    host.trace = {
      'fromBtrace': true,
      'exitCode': 0,
      'fileCount': 1,
      'totalRowsTraced': 42,
      'files': [
        {'template': 't', 'path': '/in.csv', 'rowsDeclared': 42, 'rowsTraced': 42},
      ],
      'issues': <String>[],
    };
    final after = await client!.callTool(
      CallToolRequest(name: 'get_trace', arguments: const {}),
    );
    final trace = _decode(after)['trace'] as Map<String, dynamic>;
    expect(trace['fileCount'], 1);
    expect(trace['totalRowsTraced'], 42);
    expect((trace['files'] as List).single['path'], '/in.csv');
  });

  test('get_state returns the live state shape + logs activity', () async {
    host
      ..configPath = '/cfg/x.json'
      ..isDirty = true
      ..runStatusName = 'done'
      ..lastExitCode = 0
      ..diagnosticBlob = '[error] a.b: boom\n[warn]  c: heads up';

    final result = await client!.callTool(
      CallToolRequest(name: 'get_state', arguments: const {}),
    );
    final state = _decode(result);

    expect(state['configPath'], '/cfg/x.json');
    expect(state['isDirty'], true);
    expect(state['status'], 'done');
    expect(state['lastExitCode'], 0);
    expect(state['diagnostics'], hasLength(2));

    expect(server.activity, isNotEmpty);
    expect(server.activity.first.tool, 'get_state');
    expect(server.activity.first.outcome, 'ok');
  });

  test('edit_node routes through the host edit action', () async {
    final result = await client!.callTool(
      CallToolRequest(
        name: 'edit_node',
        arguments: const {
          'path': ['brokers', '0', 'name'],
          'value': 'Acme',
        },
      ),
    );
    final out = _decode(result);

    expect(out['isDirty'], true);
    expect(out['errorsAtPath'], isEmpty);
    expect(host.edits.single.$1, ['brokers', '0', 'name']);
    expect(host.edits.single.$2, 'Acme');
    expect(server.activity.first.tool, 'edit_node');
    // Visibility: jumps to the CONFIG panel and reveals the edited node.
    expect(host.configPanelShown, greaterThan(0));
    expect(host.reveals.single, ['brokers', '0', 'name']);
  });

  test('edit_node is blocked when the config loaded with errors', () async {
    host.configLoadHadErrors = true;
    final result = await client!.callTool(
      CallToolRequest(
        name: 'edit_node',
        arguments: const {
          'path': ['x'],
          'value': 1,
        },
      ),
    );
    expect(result.isError, isTrue);
    expect(host.edits, isEmpty);
    expect(server.activity.first.outcome, 'blocked');
  });

  test('save asks to confirm: rejected when the user declines', () async {
    host.isDirty = true;
    allowSave = false;
    final result = await client!.callTool(
      CallToolRequest(name: 'save', arguments: const {}),
    );
    final out = _decode(result);

    expect(out['saved'], false);
    expect(out['rejected'], true);
    expect(host.saveCount, 0);
    expect(server.activity.first.outcome, 'rejected');
  });

  test('save persists when the user confirms', () async {
    host.isDirty = true;
    allowSave = true;
    final result = await client!.callTool(
      CallToolRequest(name: 'save', arguments: const {}),
    );
    final out = _decode(result);

    expect(out['saved'], true);
    expect(host.saveCount, 1);
    expect(server.activity.first.outcome, 'ok');
  });

  test('save is refused while the config has validation errors', () async {
    host
      ..isDirty = true
      ..configHasErrors = true
      ..validation = {
        'errors': 1,
        'warnings': 0,
        'info': 0,
        'findings': [
          {
            'severity': 'error',
            'path': 'conversion_templates.demo.date_filter_from_filename',
            'message': "date_filter_from_filename requires '\$date'",
          },
        ],
        'omitted': 0,
      };
    allowSave = true; // would approve — the gate must fire before the dialog
    final result = await client!.callTool(
      CallToolRequest(name: 'save', arguments: const {}),
    );
    final out = _decode(result);

    expect(out['saved'], false);
    expect(out['reason'], contains('validation errors'));
    expect((out['validation'] as Map)['errors'], 1);
    expect(host.saveCount, 0, reason: 'the write must never be attempted');
    expect(server.activity.first.outcome, 'blocked');
  });

  test('get_state carries the bounded validation summary', () async {
    host.validation = {
      'errors': 2,
      'warnings': 1,
      'info': 0,
      'findings': [
        {'severity': 'error', 'path': 'a.b', 'message': 'boom'},
      ],
      'omitted': 1,
    };
    final result = await client!.callTool(
      CallToolRequest(name: 'get_state', arguments: const {}),
    );
    final v = _decode(result)['validation'] as Map<String, dynamic>;
    expect(v['errors'], 2);
    expect(v['warnings'], 1);
    expect(v['omitted'], 1);
    expect((v['findings'] as List).single, {
      'severity': 'error',
      'path': 'a.b',
      'message': 'boom',
    });
  });

  test('autoApprove getter reflects the setter', () {
    final s = GuiMcpServer(_FakeHost(), confirm: (_, _) async => false);
    expect(s.autoApprove, isFalse);
    s.autoApprove = true;
    expect(s.autoApprove, isTrue);
  });

  test('autoApprove skips the confirm gate for destructive tools', () async {
    // Dedicated server whose confirm fn always REJECTS — so a successful
    // save proves the auto-approve short-circuit ran instead of the dialog.
    final aaHost = _FakeHost()..isDirty = true;
    final aaServer = GuiMcpServer(
      aaHost,
      confirm: (_, _) async => false,
      autoApprove: true,
    );
    await aaServer.start(port: 0);
    final aaClient = McpClient(
      const Implementation(name: 'test-client-aa', version: '1.0.0'),
    );
    final aaTransport = StreamableHttpClientTransport(
      Uri.parse('http://127.0.0.1:${aaServer.port}${GuiMcpServer.mcpPath}'),
      opts: const StreamableHttpClientTransportOptions(),
    );
    await aaClient.connect(aaTransport);
    try {
      final result = await aaClient.callTool(
        CallToolRequest(name: 'save', arguments: const {}),
      );
      final out = _decode(result);
      expect(out['saved'], true); // confirm would reject; auto-approve wins
      expect(aaHost.saveCount, 1);
    } finally {
      await aaTransport.close();
      await aaServer.stop();
    }
  });

  test('open_config sets the path and loads it', () async {
    final result = await client!.callTool(
      CallToolRequest(
        name: 'open_config',
        arguments: const {'path': '/cfg/new.json'},
      ),
    );
    final out = _decode(result);

    expect(out['opened'], true);
    expect(out['configPath'], '/cfg/new.json');
    expect(host.configPath, '/cfg/new.json');
    expect(host.loadCount, 1);
  });

  test('dry_run reports status + exit code', () async {
    final result = await client!.callTool(
      CallToolRequest(name: 'dry_run', arguments: const {}),
    );
    final out = _decode(result);

    expect(out['status'], 'done');
    expect(out['exitCode'], 0);
    expect(host.dryRunCount, 1);
    expect(server.activity.first.tool, 'dry_run');
    // Visibility: jumps to the RUNNER panel for the run.
    expect(host.runnerPanelShown, greaterThan(0));
  });

  test('full_run is confirm-gated', () async {
    allowSave = false; // confirm fn returns false → rejected
    final rejected = await client!.callTool(
      CallToolRequest(name: 'full_run', arguments: const {}),
    );
    expect(_decode(rejected)['rejected'], true);
    expect(host.fullRunCount, 0);

    allowSave = true;
    final ran = await client!.callTool(
      CallToolRequest(name: 'full_run', arguments: const {}),
    );
    expect(_decode(ran)['status'], 'done');
    expect(host.fullRunCount, 1);
  });

  test('delete_node confirms and is blocked on load errors', () async {
    // Blocked when the config loaded with errors (before any confirm).
    host.configLoadHadErrors = true;
    final blocked = await client!.callTool(
      CallToolRequest(
        name: 'delete_node',
        arguments: const {
          'path': ['x'],
        },
      ),
    );
    expect(blocked.isError, isTrue);
    expect(host.deletes, isEmpty);

    // Confirmed delete on a clean config.
    host.configLoadHadErrors = false;
    allowSave = true;
    final ok = await client!.callTool(
      CallToolRequest(
        name: 'delete_node',
        arguments: const {
          'path': ['brokers', '0'],
        },
      ),
    );
    expect(_decode(ok)['deleted'], true);
    expect(host.deletes.single, ['brokers', '0']);
    // Visibility: revealed the target on the CONFIG panel before deleting.
    expect(host.configPanelShown, greaterThan(0));
    expect(host.reveals.last, ['brokers', '0']);
  });

  test('exit confirms then defers teardown', () async {
    allowSave = true;
    final result = await client!.callTool(
      CallToolRequest(name: 'exit', arguments: const {}),
    );
    expect(_decode(result)['exiting'], true);
    expect(host.exitCalled, isFalse); // deferred
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(host.exitCalled, isTrue);
  });

  test('insert_node routes through the host insert action', () async {
    final result = await client!.callTool(
      CallToolRequest(
        name: 'insert_node',
        arguments: const {
          'path': ['conversion_templates'],
          'key': 'new_tmpl',
          'value': {'id': 'x'},
        },
      ),
    );
    final out = _decode(result);
    expect(out['inserted'], true);
    expect(out['key'], 'new_tmpl');
    expect(host.inserts.single.$1, ['conversion_templates']);
    expect(host.inserts.single.$2, 'new_tmpl');
    // Visibility: jumps to the CONFIG panel and reveals the inserted child.
    expect(host.configPanelShown, greaterThan(0));
    expect(host.reveals.last, ['conversion_templates', 'new_tmpl']);
  });

  test('rename_key routes through the host rename action', () async {
    final result = await client!.callTool(
      CallToolRequest(
        name: 'rename_key',
        arguments: const {
          'path': ['brokers', 'old'],
          'new_key': 'fresh',
        },
      ),
    );
    final out = _decode(result);
    expect(out['renamed'], true);
    expect(out['path'], ['brokers', 'fresh']);
    expect(host.renames.single.$1, ['brokers', 'old']);
    expect(host.renames.single.$2, 'fresh');
  });

  test('move_node routes through the host move action', () async {
    final result = await client!.callTool(
      CallToolRequest(
        name: 'move_node',
        arguments: const {
          'path': ['brokers', '0', 'rules', '2'],
          'delta': -1,
        },
      ),
    );
    final out = _decode(result);
    expect(out['moved'], true);
    expect(host.moves.single.$1, ['brokers', '0', 'rules', '2']);
    expect(host.moves.single.$2, -1);
  });

  test('structural tools are blocked when the config loaded with errors',
      () async {
    host.configLoadHadErrors = true;
    final cases = <String, Map<String, dynamic>>{
      'insert_node': {
        'path': ['x'],
        'value': 1,
      },
      'rename_key': {
        'path': ['x'],
        'new_key': 'y',
      },
      'move_node': {
        'path': ['x'],
        'delta': 1,
      },
    };
    for (final entry in cases.entries) {
      final r = await client!.callTool(
        CallToolRequest(name: entry.key, arguments: entry.value),
      );
      expect(r.isError, isTrue, reason: entry.key);
    }
    expect(host.inserts, isEmpty);
    expect(host.renames, isEmpty);
    expect(host.moves, isEmpty);
  });

  test('structural tools report failure when the store silently refuses',
      () async {
    // The store guard no-ops (e.g. deleting a schema-required key) without a
    // load error — the tools must detect the unchanged editRevision and
    // report {<verb>:false, reason}, not a false success.
    host.refuseMutations = true;

    final del = await client!.callTool(CallToolRequest(
        name: 'delete_node', arguments: const {
      'path': ['conversion_templates', 'x', 'data_dir']
    }));
    final delOut = _decode(del);
    expect(delOut['deleted'], false);
    expect(delOut['reason'], isNotNull);

    final ins = await client!.callTool(CallToolRequest(
        name: 'insert_node',
        arguments: const {'path': ['a'], 'key': 'b', 'value': 1}));
    expect(_decode(ins)['inserted'], false);

    final ren = await client!.callTool(CallToolRequest(
        name: 'rename_key',
        arguments: const {'path': ['a', 'b'], 'new_key': 'c'}));
    expect(_decode(ren)['renamed'], false);

    final mov = await client!.callTool(CallToolRequest(
        name: 'move_node', arguments: const {'path': ['a', 'b'], 'delta': 1}));
    expect(_decode(mov)['moved'], false);
  });

  test('/health reports server + live config state', () async {
    host.configPath = '/cfg/live.json';
    final hc = HttpClient();
    final req =
        await hc.getUrl(Uri.parse('http://127.0.0.1:${server.port}/health'));
    final resp = await req.close();
    expect(resp.statusCode, 200);
    final body = jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;
    hc.close();
    expect(body['name'], 'bxp-gui');
    // Reported from PackageInfo (mocked above), not a hand-bumped literal.
    expect(body['version'], '9.9.9');
    expect(body['config_path'], '/cfg/live.json');
    expect(body['config_loaded'], true);
    expect(body.containsKey('agent_connected'), isTrue);
  });

  test('origin allowlist: permissive by default, rejects once configured',
      () async {
    Future<int> hit(String origin) async {
      final hc = HttpClient();
      final req =
          await hc.getUrl(Uri.parse('http://127.0.0.1:${server.port}/health'));
      req.headers.set('origin', origin);
      final resp = await req.close();
      await resp.drain<void>();
      hc.close();
      return resp.statusCode;
    }

    // Empty allowlist (default): any Origin is accepted — webview agents.
    expect(await hit('http://evil.example'), 200);

    // With an allowlist, an off-list Origin is rejected; an on-list one ok.
    await server.restart(originAllowlist: ['http://good.example']);
    expect(await hit('http://evil.example'), 403);
    expect(await hit('http://good.example'), 200);
  });

  test('set_template activates a known template, rejects unknown', () async {
    final ok = await client!.callTool(
      CallToolRequest(name: 'set_template', arguments: const {'template': 'beta'}),
    );
    final out = _decode(ok);
    expect(out['activeTemplate'], 'beta');
    expect(out['availableTemplates'], ['alpha', 'beta']);
    expect(host.activeTemplate, 'beta');

    final bad = await client!.callTool(
      CallToolRequest(
          name: 'set_template', arguments: const {'template': 'nope'}),
    );
    expect(bad.isError, isTrue);
    // The rejected call did not change the active template.
    expect(host.activeTemplate, 'beta');
  });

  test('set_template with empty string selects all templates', () async {
    final r = await client!.callTool(
      CallToolRequest(name: 'set_template', arguments: const {'template': ''}),
    );
    expect(_decode(r)['activeTemplate'], '');
    expect(host.activeTemplate, '');
  });

  test('get_row_detail returns the row projection', () async {
    final r = await client!.callTool(
      CallToolRequest(
          name: 'get_row_detail', arguments: const {'file_row': 7}),
    );
    final out = _decode(r);
    expect(out['found'], true);
    expect(out['fileRow'], 7);
    expect(host.rowDetailCalls.single.$1, 7);
    expect(host.rowDetailCalls.single.$2, isNull);
  });

  test('get_row_detail errors when no run trace exists', () async {
    host.rowDetailResult = null;
    final r = await client!.callTool(
      CallToolRequest(
          name: 'get_row_detail', arguments: const {'file_row': 1}),
    );
    expect(r.isError, isTrue);
  });

  test('clearActivity empties the log', () async {
    await client!.callTool(
      CallToolRequest(name: 'get_state', arguments: const {}),
    );
    expect(server.activity, isNotEmpty);
    server.clearActivity();
    expect(server.activity, isEmpty);
  });
}
