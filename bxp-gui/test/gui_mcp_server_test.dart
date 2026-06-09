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

  Map<String, Map<String, String>> errorsByPath = {};
  final List<(List<String>, dynamic)> edits = [];
  int saveCount = 0;

  @override
  Map<String, String> errorsAt(List<String> path) =>
      errorsByPath[path.join('.')] ?? const {};

  @override
  void editConfigNode(List<String> path, dynamic newValue) {
    edits.add((path, newValue));
    isDirty = true;
  }

  @override
  Future<void> saveConfig() async {
    saveCount++;
    isDirty = false;
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

  test('lists the three Phase-1 tools', () async {
    final tools = await client!.listTools();
    final names = tools.tools.map((t) => t.name).toSet();
    expect(names, containsAll(<String>{'get_state', 'edit_node', 'save'}));
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
}
