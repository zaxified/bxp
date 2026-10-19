// Audit regressions for lib/services: prefs flush serialisation + corrupt-file
// backup, desktop Exec= quoting, gui-mcp session bookkeeping, updater caps.

import 'dart:convert';
import 'dart:io';

import 'package:bxp_gui/services/desktop_integration_service.dart';
import 'package:bxp_gui/services/gui_mcp_server.dart';
import 'package:bxp_gui/services/prefs_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Minimal host: only what /health and the handshake read.
class _Host implements GuiMcpHost {
  @override
  String get configPath => '';
  @override
  bool get configLoadHadErrors => false;
  @override
  bool get isDirty => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  PackageInfo.setMockInitialValues(
    appName: 'bxp-gui', packageName: 'x', version: '1.2.3', buildNumber: '0', buildSignature: '');

  group('prefs', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('audit-prefs-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('overlapping un-awaited setters all persist and never throw', () async {
      final p = PrefsService(dirOverride: dir.path);
      await p.load();
      final futures = [for (var i = 0; i < 25; i++) p.setInt('k$i', i)];
      await Future.wait(futures);
      final onDisk = jsonDecode(File('${dir.path}/bxp-gui.json').readAsStringSync()) as Map;
      for (var i = 0; i < 25; i++) {
        expect(onDisk['k$i'], i);
      }
      expect(File('${dir.path}/bxp-gui.json.tmp').existsSync(), isFalse);
    });

    test('corrupt prefs file is backed up before the next flush rewrites it', () async {
      File('${dir.path}/bxp-gui.json').writeAsStringSync('{"a": 1,, oops');
      final p = PrefsService(dirOverride: dir.path);
      await p.load();
      await p.setBool('b', true);
      expect(File('${dir.path}/bxp-gui.json.corrupt').readAsStringSync(), '{"a": 1,, oops');
    });

    test('getStringList drops non-string entries instead of failing later', () async {
      File('${dir.path}/bxp-gui.json').writeAsStringSync('{"r": ["a", 3, null, "b"]}');
      final p = PrefsService(dirOverride: dir.path);
      await p.load();
      expect(p.getStringList('r'), ['a', 'b']);
    });
  });

  group('desktop Exec quoting', () {
    test('plain path stays bare, spaced path is quoted, % doubled', () {
      expect(DesktopIntegrationService.execToken('/opt/bxp.AppImage'), '/opt/bxp.AppImage');
      expect(DesktopIntegrationService.execToken('/home/u/My Apps/bxp.AppImage'),
          '"/home/u/My Apps/bxp.AppImage"');
      expect(DesktopIntegrationService.execToken('/a/100%/b'), '/a/100%%/b');
      expect(DesktopIntegrationService.execToken(r'/a/$x b'), r'"/a/\\$x b"');
    });

    test('integrate + isIntegrated agree on a path with a space', () async {
      final home = Directory.systemTemp.createTempSync('audit-home-');
      final app = Directory.systemTemp.createTempSync('audit-app-');
      addTearDown(() {
        home.deleteSync(recursive: true);
        app.deleteSync(recursive: true);
      });
      final svc = DesktopIntegrationService(
        homeOverride: home.path,
        appImageOverride: '/x/My Apps/bxp.AppImage',
        appDirOverride: app.path,
      );
      await svc.integrate();
      expect(svc.isIntegrated(), isTrue);
      final content = File(svc.describePaths().desktopFile).readAsStringSync();
      expect(content, contains('Exec="/x/My Apps/bxp.AppImage" %F'));
    }, skip: !Platform.isLinux);
  });

  group('gui-mcp', () {
    late GuiMcpServer server;
    setUp(() async {
      server = GuiMcpServer(_Host(), confirm: (_, _) async => true);
      await server.start(port: 0);
    });
    tearDown(() => server.stop());

    Future<int> post(String body, {Map<String, String> headers = const {}}) async {
      final c = HttpClient();
      try {
        final req = await c.postUrl(Uri.parse('http://127.0.0.1:${server.port}/mcp'));
        req.headers.set('content-type', 'application/json');
        req.headers.set('accept', 'application/json, text/event-stream');
        headers.forEach(req.headers.set);
        req.write(body);
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      } finally {
        c.close(force: true);
      }
    }

    test('malformed JSON body is a 400, not a 500', () async {
      expect(await post('{not json'), HttpStatus.badRequest);
    });

    test('a closed session leaves _transports (agentConnected flips back)', () async {
      final client = McpClient(const Implementation(name: 't', version: '1'));
      final transport = StreamableHttpClientTransport(
        Uri.parse('http://127.0.0.1:${server.port}${GuiMcpServer.mcpPath}'),
        opts: const StreamableHttpClientTransportOptions(),
      );
      await client.connect(transport);
      expect(server.agentConnected, isTrue);
      final sid = transport.sessionId!;
      final c = HttpClient();
      final req = await c.deleteUrl(Uri.parse('http://127.0.0.1:${server.port}/mcp'));
      req.headers.set('mcp-session-id', sid);
      final res = await req.close();
      await res.drain<void>();
      c.close(force: true);
      for (var i = 0; i < 50 && server.agentConnected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(server.agentConnected, isFalse);
    });

    test('stop() with a live session completes and closes the socket', () async {
      final client = McpClient(const Implementation(name: 't', version: '1'));
      final transport = StreamableHttpClientTransport(
        Uri.parse('http://127.0.0.1:${server.port}${GuiMcpServer.mcpPath}'),
        opts: const StreamableHttpClientTransportOptions(),
      );
      await client.connect(transport);
      await server.stop();
      expect(server.isRunning, isFalse);
    });

    test('overlapping start() calls bind once', () async {
      final s2 = GuiMcpServer(_Host(), confirm: (_, _) async => true);
      addTearDown(s2.stop);
      await Future.wait([s2.start(port: 0), s2.start(port: 0)]);
      expect(s2.isRunning, isTrue);
      expect(s2.lastError, isNull);
    });
  });
}
