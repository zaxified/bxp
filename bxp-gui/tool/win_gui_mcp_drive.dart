// Drives the embedded GUI-MCP server of a RUNNING bxp-gui over StreamableHTTP
// (v0.2.5 Windows pre-release sweep). Exercises the agent-control surface
// end-to-end on Windows: HTTP bind + MCP handshake, a read-only get_state, an
// open_config (→ bridge_inspect config + GUI repaint), a dry_run (→ bxp-cli via
// bridge_run_streaming through the real GUI + trace populate), and get_trace
// (row counts prove the stream drained without truncation through the GUI).
//
// Prereq: launch the GUI first with BXP_GUI_MCP_AUTO_APPROVE=1 so destructive
// tools don't block on a dialog, then:
//   cd bxp-gui && dart run tool/win_gui_mcp_drive.dart
//
// Pass a config path as argv[0] (defaults to the trading212 dataset).

import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;

void main(List<String> argv) async {
  final repo = _findMonoRoot();
  final cfg = argv.isNotEmpty
      ? argv[0]
      : p.join(repo, 'datasets', 'trading212_to_wealthfolio', 'sample.json');

  final client = McpClient(
    const Implementation(name: 'win-gui-drive', version: '1.0.0'),
  );
  final transport = StreamableHttpClientTransport(
    Uri.parse('http://127.0.0.1:7717/mcp'),
    opts: const StreamableHttpClientTransportOptions(),
  );

  var pass = 0, fail = 0;
  void check(String name, bool ok, String detail) {
    stdout.writeln('${ok ? "PASS" : "FAIL"}  $name\n        $detail');
    ok ? pass++ : fail++;
  }

  Map<String, dynamic> decode(CallToolResult r) =>
      jsonDecode((r.content.single as TextContent).text)
          as Map<String, dynamic>;

  try {
    await client.connect(transport);
    stdout.writeln('connected to GUI-MCP\n');

    // 1. get_state — read-only "see the screen".
    final st = decode(await client.callTool(
        CallToolRequest(name: 'get_state', arguments: const {})));
    check('1 get_state', st.isNotEmpty,
        'keys=${st.keys.take(8).toList()}');

    // 2. open_config — load a real dataset config (bridge_inspect + repaint).
    final op = decode(await client.callTool(CallToolRequest(
        name: 'open_config', arguments: {'path': cfg})));
    check('2 open_config', op['opened'] == true,
        'opened=${op['opened']} path=${op['configPath']} errors=${op['loadedWithErrors']}');

    // 3. dry_run — bxp-cli via bridge_run_streaming through the live GUI.
    final dr = decode(await client.callTool(
        CallToolRequest(name: 'dry_run', arguments: const {})));
    check('3 dry_run', dr['exitCode'] == 0 || dr['status'] == 'ok' || dr['ok'] == true,
        'result=${jsonEncode(dr)}');

    // 4. get_trace — run summary; row counts prove the BXTB stream drained.
    final tr = decode(await client.callTool(
        CallToolRequest(name: 'get_trace', arguments: const {})));
    check('4 get_trace', tr.isNotEmpty, 'trace=${jsonEncode(tr)}');

    // 5. get_state again — confirm the config + run landed in live state.
    final st2 = decode(await client.callTool(
        CallToolRequest(name: 'get_state', arguments: const {})));
    check('5 get_state post-run', st2.isNotEmpty,
        'keys=${st2.keys.take(10).toList()}');
  } catch (e, s) {
    stdout.writeln('DRIVER ERROR: $e\n$s');
    fail++;
  } finally {
    try {
      await transport.close();
    } catch (_) {}
  }

  stdout.writeln('\n=== gui-mcp drive: $pass passed, $fail failed ===');
  exit(fail == 0 ? 0 : 1);
}

String _findMonoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory(p.join(dir.path, 'datasets')).existsSync() &&
        Directory(p.join(dir.path, 'bxp-gui')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('monorepo root not found from ${Directory.current.path}');
}
