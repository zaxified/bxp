import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';

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

  Map<String, Map<String, String>> errorsByPath = {};
  final List<(List<String>, dynamic)> edits = [];
  final List<List<String>> deletes = [];
  int saveCount = 0;
  int loadCount = 0;
  int dryRunCount = 0;
  int fullRunCount = 0;
  bool exitCalled = false;

  Map<String, dynamic>? trace;

  @override
  Map<String, String> errorsAt(List<String> path) =>
      errorsByPath[path.join('.')] ?? const {};

  @override
  Map<String, dynamic>? traceSummary() => trace;

  @override
  void editConfigNode(List<String> path, dynamic newValue) {
    edits.add((path, newValue));
    isDirty = true;
  }

  @override
  void deleteConfigNode(List<String> path) {
    deletes.add(path);
    isDirty = true;
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
}

/// Decodes the single TextContent JSON payload from a tool result.
Map<String, dynamic> _decode(CallToolResult result) {
  final item = result.content.single;
  return jsonDecode((item as TextContent).text) as Map<String, dynamic>;
}

void main() {
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
    await server.start(); // ephemeral port
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
}
