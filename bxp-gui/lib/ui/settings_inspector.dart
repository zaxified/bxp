import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:json5_ast/ast.dart';
import 'package:provider/provider.dart';

import '../services/bxp_process_client.dart';
import '../services/debug_settings.dart';
import '../services/desktop_integration_service.dart';
import '../services/diagnostic_log.dart';
import '../services/gui_mcp_server.dart';
import '../store/trace_store.dart';
import 'components/integrate_dialog.dart';
import 'layout_defaults.dart';
import 'platform_shortcuts.dart';
import 'theme/bxp_theme.dart';
import 'theme/bxp_text.dart';

/// Floating right-side drawer that mirrors [ThemeInspector] but surfaces
/// runtime / config / version state instead of theme tokens. Useful for
/// quickly checking which binaries the GUI resolved, what version each
/// component is at, and how the active config currently parses.
///
/// Toggled from [MainView] via Ctrl+Shift+S. Click backdrop or press
/// Escape to dismiss. Width is shared with [ThemeInspector] via
/// [LayoutDefaults.sidePanelFrac].
class SettingsInspector extends StatefulWidget {
  final VoidCallback onClose;
  const SettingsInspector({super.key, required this.onClose});

  @override
  State<SettingsInspector> createState() => _SettingsInspectorState();
}

class _SettingsInspectorState extends State<SettingsInspector> {
  @override
  void initState() {
    super.initState();
    // Same rationale as the global Ctrl+S/Z/Y handlers in MainView:
    // CallbackShortcuts only fires when the focused widget bubbles the key
    // event up. A drawer with nested SelectableText / Tables routinely sinks
    // focus into a child that does not bubble Escape, leaving the user
    // stuck without a keyboard dismiss. HardwareKeyboard sees every key
    // before focus routing, so Escape always closes the drawer.
    HardwareKeyboard.instance.addHandler(_handleKey);
    // Versions are probed lazily — this drawer is the only place they show.
    // Deferred to post-frame so `context.read` is safe from initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TraceStore>().ensureVersionsProbed();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    widget.onClose();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final width = MediaQuery.sizeOf(context).width *
        LayoutDefaults.sidePanelFrac;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            child: Container(color: t.dialogBarrier.withValues(alpha: 0.3)),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: width,
          child: Material(
            color: t.dialogBg,
            elevation: 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(onClose: widget.onClose),
                Expanded(child: _Body()),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onClose;
  const _Header({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: t.panelBg,
        border: Border(bottom: BorderSide(color: t.borderColor)),
      ),
      child: Row(
        children: [
          Text('RUNTIME INFO', style: BxpText.label(context)),
          const Spacer(),
          InkWell(
            onTap: onClose,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text('✕',
                  style: TextStyle(color: t.textMuted, fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final store = context.watch<TraceStore>();

    // Phase 5c-C2: walk the live AST for the template id list.
    // CommentLine peers in `conversion_templates` are skipped naturally
    // by `whereType<JsonProperty>`; FnDocs schema keys (`$action`, …)
    // never appear here — they live in output_schema, not template names.
    final templates = <String>[];
    final root = store.astRoot;
    if (root is JsonObject) {
      for (final p in root.properties.whereType<JsonProperty>()) {
        if (p.key != 'conversion_templates') continue;
        final v = p.value;
        if (v is! JsonObject) break;
        for (final tp in v.properties.whereType<JsonProperty>()) {
          templates.add(tp.key);
        }
        break;
      }
    }

    final cliPath = BxpProcessClient.findBin('bxp-cli');
    final cliEnv = Platform.environment['BXP_CLI_PATH'];
    // The MCP server ships beside bxp-cli in the desktop bundle (so an agent
    // can register it / its bxp_simulate tool can spawn bxp-cli). The GUI
    // never runs it, but surface its resolved path here so the user can find
    // the binary to wire into an MCP client.
    final mcpPath = BxpProcessClient.findBin('bxp-mcp');

    // Live trace counter — ticks ~10 Hz during a stream. Reading once at
    // build time would freeze; ValueListenableBuilder keeps just the
    // "trace lines" cell reactive without rebuilding the whole panel.
    return ValueListenableBuilder<int>(
      valueListenable: store.traceLinesCounter,
      builder: (context, traceLines, _) => _buildTable(
          context, store, templates, cliPath, cliEnv, mcpPath, traceLines),
    );
  }

  Widget _buildTable(
    BuildContext context,
    TraceStore store,
    List<String> templates,
    String? cliPath,
    String? cliEnv,
    String? mcpPath,
    int traceLines,
  ) {
    // Whole-panel sections list, each a (title, rows) group. Rendered
    // below as one `_SectionTable` per group, so the label column's
    // `IntrinsicColumnWidth` is computed per section (labels line up
    // within a section, not across sections — see the rationale on the
    // render loop further down).
    final sections = <(String, List<(String, String)>)>[
      ('Versions', [
        ('bxp-gui', store.bxpGuiVersion ?? '(unknown)'),
        ('bxp-cli', store.bxpCliVersion ?? '(unknown)'),
        ('bxp-mcp', store.bxpMcpVersion ?? '(unknown)'),
      ]),
      ('Binaries', [
        ('bxp-cli', cliPath ?? '(not found)'),
        if (cliEnv != null && cliEnv.isNotEmpty)
          (r'$BXP_CLI_PATH', cliEnv),
        ('bxp-mcp', mcpPath ?? '(not found)'),
      ]),
      ('Bridge', [
        // The bridge is the single backend on every platform now — every
        // stateless op (docs/config/expr/eval) runs in-process, and bxp-cli
        // dry-runs stream through it. A missing library is a fatal startup.
        ('version', BxpProcessClient.bridgeVersion ?? '(not loaded)'),
        ('lib', BxpProcessClient.bridgeDllPath ?? '(not found)'),
        ('lastDiag', BxpProcessClient.lastSubprocessDiag ?? '(none)'),
      ]),
      ('Config', [
        ('path', store.configPath.isEmpty ? '(none)' : store.configPath),
        ('dirty', store.isDirty.toString()),
        ('saving', store.isSaving.toString()),
        ('hasErrors', store.configHasErrors.toString()),
        ('hadErrors (load)', store.configLoadHadErrors.toString()),
        ('fsCheckSlow', store.fsCheckSlow.toString()),
        if (store.configError != null)
          ('error', store.configError!),
      ]),
      ('Templates (${templates.length})', [
        if (templates.isEmpty)
          ('—', '(none)')
        else
          for (final id in templates) ('•', id),
      ]),
      ('Run state', [
        ('status', store.status.name),
        ('lastExitCode', store.lastExitCode?.toString() ?? '(none)'),
        ('trace lines', traceLines.toString()),
        if (store.stderrText.isNotEmpty)
          ('stderr bytes', store.stderrText.length.toString()),
      ]),
      ('Theme', [
        ('preset', store.themePresetName),
      ]),
      // Rendered from the single ShortcutDoc catalog (platform_shortcuts.dart),
      // co-located with the command-modifier helper — no hand-list here.
      ('Keyboard shortcuts', [
        for (final s in shortcutCatalog()) (s.action, s.keys),
      ]),
    ];

    // Per-section Tables — each computes its own `IntrinsicColumnWidth` for
    // the label column. A single panel-wide Table tried earlier interleaved
    // section-title rows with data rows in the same grid, which made the
    // first row of every section look offset (the header occupied col0 only
    // while the data row below jumped back to a left-aligned name). Splitting
    // means column widths reset per section, so labels never line up across
    // sections — but they always line up within one, and the layout reads
    // top-to-bottom without surprises.
    final t = context.bxpTheme;
    final blocks = <Widget>[
      for (final (title, rows) in sections)
        _SectionTable(title: title, rows: rows),
      const _IntegrationSection(),
      const _AgentSection(),
      const _DebugSection(),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0)
              Divider(height: 20, thickness: 1, color: t.borderColor),
            blocks[i],
          ],
        ],
      ),
    );
  }
}

/// Master switch handler for the Diagnostic mode toggle. Confirms with
/// the user (because the action restarts the app), saves any pending
/// edits if the config is clean enough to save, flips the activation
/// marker file, then spawns a fresh detached instance of the binary
/// before exiting the current process.
///
/// In debug-mode dev runs (`flutter run`), `Platform.resolvedExecutable`
/// points at a tooling shim, not at our exe — restarting it would
/// either re-launch the wrong thing or fail silently. Detect that case
/// and just toggle the marker, leaving the user to do their own hot
/// restart.
Future<void> _toggleDiagnosticMode(BuildContext context, bool enable) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(enable
          ? 'Enable diagnostic mode?'
          : 'Disable diagnostic mode?'),
      content: Text(
        enable
            ? 'The app will restart so the diagnostic capture covers the '
                'engine boot path (Dart NDJSON, native Win32 messages, '
                'engine stderr cascade). Unsaved changes will be saved '
                'first if the config is valid.'
            : 'The app will restart to disable diagnostic capture. '
                'Unsaved changes will be saved first if the config is '
                'valid.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Restart'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  if (!context.mounted) return;

  final store = context.read<TraceStore>();
  if (store.isDirty &&
      !store.configHasErrors &&
      !store.configLoadHadErrors &&
      !store.isSaving) {
    await store.saveConfig();
  }

  await DiagnosticLog.setMarker(enable);

  // `Platform.resolvedExecutable` is reliable in release; in debug
  // (`flutter run`) it points at the dart/flutter tooling shim, which
  // we can detect by the kDebugMode flag. Skip the auto-restart there
  // — the marker still flips, the user can hot-restart manually.
  if (kDebugMode) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          enable
              ? 'Marker created. Restart the app to capture full '
                  'diagnostic from boot.'
              : 'Marker removed. Restart the app for a clean session.',
        ),
        duration: const Duration(seconds: 4),
      ));
    }
    return;
  }

  try {
    await Process.start(
      Platform.resolvedExecutable,
      const <String>[],
      mode: ProcessStartMode.detached,
    );
  } catch (_) {
    // Spawn failed — fall back to leaving the marker flipped and
    // surfacing a notice. User can restart manually.
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Could not relaunch automatically. '
          'Marker is ${enable ? "set" : "cleared"}; close and reopen '
          'the app to apply.',
        ),
        duration: const Duration(seconds: 5),
      ));
    }
    return;
  }
  exit(0);
}

/// Linux AppImage desktop-integration toggle. Lets the user install or
/// remove the `~/.local/share/applications/bxp-gui.desktop` entry and
/// hicolor icons after the fact. Renders empty on Windows / macOS /
/// non-AppImage builds, so the section header itself does not appear.
class _IntegrationSection extends StatefulWidget {
  const _IntegrationSection();

  @override
  State<_IntegrationSection> createState() => _IntegrationSectionState();
}

class _IntegrationSectionState extends State<_IntegrationSection> {
  final DesktopIntegrationService _svc = DesktopIntegrationService();
  bool _busy = false;

  Future<void> _onUninstall() async {
    setState(() => _busy = true);
    await _svc.uninstall();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _onInstall() async {
    final store = context.read<TraceStore>();
    setState(() => _busy = true);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => IntegrateDialog(integration: _svc, prefs: store.prefs),
    );
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_svc.isAvailable()) return const SizedBox.shrink();
    final t = context.bxpTheme;
    final integrated = _svc.isIntegrated();
    final desktopPath = _svc.describePaths().desktopFile;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('DESKTOP INTEGRATION', style: BxpText.label(context)),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SelectableText(
              integrated
                  ? 'Installed → $desktopPath'
                  : 'Not installed — BXP is not in the application menu.',
              style: BxpText.body(
                context,
                color: t.textMuted,
                size: BxpSize.xs,
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: integrated
                ? OutlinedButton(
                    onPressed: _busy ? null : _onUninstall,
                    child: const Text('Uninstall integration'),
                  )
                : FilledButton(
                    onPressed: _busy ? null : _onInstall,
                    child: const Text('Install desktop integration'),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Agent-control section — the master switch for the embedded GUI-MCP
/// server ([GuiMcpServer]), its live listening status, and a strip of the
/// most recent agent tool calls so the user can see what the agent did.
/// Default-on (persisted under `bxp-gui.mcp-enabled`); the switch reflects
/// the user's intent while the status line below reports the real socket
/// state (including a non-fatal bind error).
class _AgentSection extends StatefulWidget {
  const _AgentSection();

  @override
  State<_AgentSection> createState() => _AgentSectionState();
}

class _AgentSectionState extends State<_AgentSection> {
  static const String _prefKey = 'bxp-gui.mcp-enabled';
  static const String _hostKey = 'bxp-gui.mcpHost';
  static const String _portKey = 'bxp-gui.mcpPort';
  static const String _allowlistKey = 'bxp-gui.mcpOriginAllowlist';
  static const String _autoApproveKey = 'bxp-gui.mcpAutoApprove';
  bool _busy = false;

  final _hostCtl = TextEditingController();
  final _portCtl = TextEditingController();
  final _allowlistCtl = TextEditingController();
  bool _fieldsInit = false;

  @override
  void dispose() {
    _hostCtl.dispose();
    _portCtl.dispose();
    _allowlistCtl.dispose();
    super.dispose();
  }

  /// Prime the editable fields once from the server's resolved config
  /// (which has already folded in prefs/env at startup).
  void _initFields(GuiMcpServer mcp) {
    if (_fieldsInit) return;
    _fieldsInit = true;
    _hostCtl.text = mcp.configuredHost;
    _portCtl.text = mcp.configuredPort.toString();
    _allowlistCtl.text = mcp.originAllowlist.join(', ');
  }

  Future<void> _toggle(bool enable) async {
    if (_busy) return;
    setState(() => _busy = true);
    final mcp = context.read<GuiMcpServer>();
    await context.read<TraceStore>().prefs.setString(
          _prefKey,
          enable ? 'true' : 'false',
        );
    if (enable) {
      await mcp.start();
    } else {
      await mcp.stop();
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// Persist host/port/origin-allowlist and re-bind the server.
  Future<void> _applyEndpoint() async {
    if (_busy) return;
    final host = _hostCtl.text.trim().isEmpty
        ? GuiMcpServer.kDefaultMcpHost
        : _hostCtl.text.trim();
    final port =
        int.tryParse(_portCtl.text.trim()) ?? GuiMcpServer.kDefaultMcpPort;
    final allowlist = _allowlistCtl.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    setState(() => _busy = true);
    final mcp = context.read<GuiMcpServer>();
    final prefs = context.read<TraceStore>().prefs;
    await prefs.setString(_hostKey, host);
    await prefs.setInt(_portKey, port);
    await prefs.setStringList(_allowlistKey, allowlist);
    await mcp.restart(host: host, port: port, originAllowlist: allowlist);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// Persist + apply the dev auto-approve toggle. When on, the gui-mcp's
  /// destructive tools (`save` / `full_run` / `delete_node` / `exit`) run
  /// without the per-action confirm dialog — for agent-driven testing.
  Future<void> _setAutoApprove(bool enable) async {
    final mcp = context.read<GuiMcpServer>();
    await context.read<TraceStore>().prefs.setBool(_autoApproveKey, enable);
    mcp.autoApprove = enable;
  }

  static bool _isLoopback(String host) =>
      host == '127.0.0.1' || host == 'localhost' || host == '::1';

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final store = context.watch<TraceStore>();
    final mcp = context.watch<GuiMcpServer>();
    final enabled = store.prefs.getString(_prefKey) != 'false';
    _initFields(mcp);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('AGENT CONTROL', style: BxpText.label(context)),
          ),
          _DebugSwitchRow(
            label: 'Agent control (MCP server)',
            subtitle:
                'Lets a local AI agent read and edit the live config over '
                '127.0.0.1 (StreamableHTTP). Critical actions ask first.',
            value: enabled,
            onChanged: _toggle,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _statusLine(context, t, mcp),
          ),
          if (enabled) ...[
            const SizedBox(height: 10),
            _Subheader('Endpoint'),
            _card(t, _endpointEditor(context, t)),
            const SizedBox(height: 10),
            _DebugSwitchRow(
              label: 'Auto-approve agent actions (dev)',
              subtitle:
                  'Skip the confirm dialog for save / full run / delete / '
                  'exit so an agent can drive the GUI headlessly. Leave OFF '
                  'unless you are testing — destructive actions run unprompted.',
              value: mcp.autoApprove,
              onChanged: _setAutoApprove,
            ),
          ],
          if (mcp.activity.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _Subheader('Recent agent activity')),
                _miniAction(context, t, Icons.clear_all, 'Clear',
                    mcp.clearActivity),
              ],
            ),
            _card(
              t,
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 168),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final e in mcp.activity.take(50))
                        _activityRow(context, t, e),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Recessed framed group — gives the endpoint + activity blocks a visible
  /// surface so they read as panels, not loose widgets on the drawer bg.
  Widget _card(BxpTheme t, Widget child) => Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: t.surfaceBg,
          border: Border.all(color: t.borderColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );

  /// Small icon+label header action (e.g. the activity log "Clear").
  Widget _miniAction(BuildContext context, BxpTheme t, IconData icon,
          String label, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: t.textMuted),
              const SizedBox(width: 4),
              Text(label,
                  style: BxpText.body(context,
                      color: t.textMuted, size: BxpSize.xs)),
            ],
          ),
        ),
      );

  /// Outcome → (icon, colour). Distinguishes rejected/blocked from plain ok,
  /// which the old single-colour line could not.
  static (IconData, Color) _outcomeStyle(BxpTheme t, String outcome) {
    switch (outcome) {
      case 'error':
        return (Icons.error_outline, t.errorText);
      case 'rejected':
        return (Icons.cancel_outlined, t.warnText);
      case 'blocked':
        return (Icons.block, t.warnText);
      default:
        return (Icons.check_circle_outline, t.okText);
    }
  }

  /// Compact relative age: `now`, `5s`, `3m`, `2h`, else clock time.
  static String _relTime(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inSeconds < 1) return 'now';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(when.hour)}:${two(when.minute)}';
  }

  Widget _statusLine(BuildContext context, BxpTheme t, GuiMcpServer mcp) {
    if (mcp.lastError != null) {
      return SelectableText(
        'Error: ${mcp.lastError}',
        style: BxpText.body(context, color: t.errorText, size: BxpSize.xs),
      );
    }
    final muted = BxpText.body(context, color: t.textMuted, size: BxpSize.xs);
    if (!mcp.isRunning) return Text('Stopped', style: muted);
    final conn =
        mcp.agentConnected ? ' · agent connected' : ' · waiting for agent';
    return SelectableText(
      'Listening on ${mcp.configuredHost}:${mcp.port}$conn',
      style: muted,
    );
  }

  Widget _endpointEditor(BuildContext context, BxpTheme t) {
    final host = _hostCtl.text.trim();
    final showWarning = host.isNotEmpty && !_isLoopback(host);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _field(context, t, _hostCtl, 'Host',
                    onChanged: (_) => setState(() {})),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _field(context, t, _portCtl, 'Port',
                    keyboardType: TextInputType.number),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _field(context, t, _allowlistCtl, 'Origin allowlist',
              helper: 'comma-separated; empty = allow all'),
          if (showWarning)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Binding to a non-loopback address exposes an unauthenticated '
                'control surface on your network.',
                style:
                    BxpText.body(context, color: t.errorText, size: BxpSize.xs),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : _applyEndpoint,
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: t.textPrimary,
                backgroundColor: t.okBg,
              ),
              child: Text(
                _busy ? 'Applying…' : 'Apply & restart server',
                style: BxpText.body(context,
                    color: t.textPrimary, size: BxpSize.xs),
              ),
            ),
          ),
      ],
    );
  }

  Widget _field(
    BuildContext context,
    BxpTheme t,
    TextEditingController ctl,
    String label, {
    String? helper,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: ctl,
      keyboardType: keyboardType,
      onChanged: onChanged,
      style: BxpText.body(context, color: t.textPrimary, size: BxpSize.xs),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        labelStyle: BxpText.body(context,
            color: t.textSubtle, size: BxpSize.xs, weight: BxpWeight.semiBold),
        helperText: helper,
        helperStyle:
            BxpText.body(context, color: t.textMuted, size: BxpSize.xs),
        filled: true,
        fillColor: t.panelBg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(borderSide: BorderSide(color: t.borderColor)),
        enabledBorder:
            OutlineInputBorder(borderSide: BorderSide(color: t.borderColor)),
      ),
    );
  }

  Widget _activityRow(BuildContext context, BxpTheme t, AgentActivityEntry e) {
    final (icon, color) = _outcomeStyle(t, e.outcome);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 6),
            child: Icon(icon, size: 13, color: color),
          ),
          Expanded(
            child: RichText(
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: BxpText.body(context, color: t.textPrimary,
                    size: BxpSize.xs),
                children: [
                  TextSpan(text: e.tool, style: BxpText.body(context,
                      color: color, size: BxpSize.xs, weight: BxpWeight.semiBold)),
                  TextSpan(text: '  ${_relTime(e.time)}',
                      style: BxpText.body(context,
                          color: t.textSubtle, size: BxpSize.xs)),
                  if (e.summary.isNotEmpty)
                    TextSpan(text: '\n${e.summary}',
                        style: BxpText.body(context,
                            color: t.textMuted, size: BxpSize.xs)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Interactive Debug section — master "Diagnostic mode" switch (overlay
/// + file trace), per-feature regression knobs, and a stress button.
/// Lives at the bottom of the SettingsInspector body so the
/// table-driven info above stays free of Material inputs that don't fit
/// the IntrinsicColumnWidth grid.
class _DebugSection extends StatelessWidget {
  const _DebugSection();

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final s = context.watch<DebugSettings>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('DEBUG', style: BxpText.label(context)),
          ),
          // ── Master switch: overlay + file trace ─────────────────────
          //
          // Toggling the switch flips the persistent activation marker
          // and restarts the binary so the diagnostic capture covers
          // EVERY layer — Dart NDJSON, native Win32 messages, and the
          // engine stderr (D3D11/EGL cascade). Mid-session activation
          // would miss the engine boot path where most freeze triggers
          // originate, and end-users can't reliably set environment
          // variables, so the restart is the simplest sound flow.
          _DebugSwitchRow(
            label: 'Diagnostic mode',
            subtitle:
                'Writes NDJSON + native + engine logs to %APPDATA%\\'
                'bxp-gui\\diagnostic-*; shows the live counter overlay. '
                'Toggling restarts the app.',
            value: s.diagnosticTraceActive,
            onChanged: (v) => _toggleDiagnosticMode(context, v),
          ),
          if (s.diagnosticTraceActive && s.diagnosticTracePath != null)
            Padding(
              padding: const EdgeInsets.only(left: 56, top: 2, bottom: 4),
              child: SelectableText(
                s.diagnosticTracePath!,
                style: BxpText.body(context,
                    color: t.textMuted, size: BxpSize.xs),
              ),
            ),
          const SizedBox(height: 8),
          _Subheader('Tree feature toggles'),
          _DebugCheckRow(
            label: 'Tooltips on tree keys',
            subtitle: 'Material Tooltip wrapping each schema key',
            value: s.tooltipsInTree,
            onChanged: (v) => s.tooltipsInTree = v,
          ),
          _DebugCheckRow(
            label: 'Hover background highlight',
            subtitle: 'Per-row setState on mouse enter/exit',
            value: s.hoverBackground,
            onChanged: (v) => s.hoverBackground = v,
          ),
          _DebugCheckRow(
            label: 'Hover-driven action buttons',
            subtitle: '↑↓× appear when hovered (vs. never mounted)',
            value: s.hoverActionButtons,
            onChanged: (v) => s.hoverActionButtons = v,
          ),
          _DebugCheckRow(
            label: 'InkWell on expandable rows',
            subtitle: 'Material ripple + hover; off uses GestureDetector',
            value: s.useInkWell,
            onChanged: (v) => s.useInkWell = v,
          ),
          const SizedBox(height: 8),
          _Subheader('Pointer event filters'),
          _DebugCheckRow(
            label: 'Block middle mouse button',
            subtitle: 'Drop events whose button mask includes middle',
            value: s.blockMiddleButton,
            onChanged: (v) => s.blockMiddleButton = v,
          ),
          _DebugCheckRow(
            label: 'Block right mouse button',
            subtitle: 'Drop events whose button mask includes secondary',
            value: s.blockRightButton,
            onChanged: (v) => s.blockRightButton = v,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('Hover throttle:',
                      style: BxpText.body(context,
                          color: t.textPrimary, size: BxpSize.sm)),
                ),
                for (final hz in const [0, 60, 30, 15])
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(hz == 0 ? 'off' : '${hz}Hz'),
                      selected: s.pointerThrottleHz == hz,
                      onSelected: (_) => s.pointerThrottleHz = hz,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _Subheader('Render pipeline'),
          _DebugCheckRow(
            label: 'Disable $commandModifierLabel+/− zoom',
            subtitle:
                'Off (default): Transform.scale wraps the app, '
                '$commandModifierLabel+/− changes zoom. On: paint at native '
                'resolution, no scaling layer — used to isolate compositor cost.',
            value: s.bypassZoom,
            onChanged: (v) => s.bypassZoom = v,
          ),
          const SizedBox(height: 8),
          _Subheader('Stress test'),
          const _StressButton(),
        ],
      ),
    );
  }
}

class _Subheader extends StatelessWidget {
  final String label;
  const _Subheader(this.label);

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(
        label,
        style: BxpText.body(context,
            color: t.textMuted,
            size: BxpSize.xs,
            weight: BxpWeight.semiBold),
      ),
    );
  }
}

/// Compact inspector-style switch row. Avoids `SwitchListTile`'s built-in
/// padding so the row aligns with the existing 16 px outer pad without
/// double-indenting.
class _DebugSwitchRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _DebugSwitchRow({
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Switch(value: value, onChanged: onChanged),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: BxpText.body(context,
                          color: t.textPrimary,
                          size: BxpSize.sm,
                          weight: BxpWeight.semiBold)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle!,
                          style: BxpText.body(context,
                              color: t.textMuted, size: BxpSize.xs)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Same shape as [_DebugSwitchRow] but a Checkbox + label/subtitle.
class _DebugCheckRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _DebugCheckRow({
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 32,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: BxpText.body(context,
                            color: t.textPrimary, size: BxpSize.sm)),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(subtitle!,
                            style: BxpText.body(context,
                                color: t.textMuted, size: BxpSize.xs)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Rebuild tree 100×" stress button — was the only action in the
/// retired DebugPanelDialog. Drives `TraceStore.debugNotify` 100× with
/// 16 ms gaps so the framework actually schedules a frame each
/// iteration; back-to-back notifies otherwise collapse into a single
/// dirty-mark before any frame paints.
class _StressButton extends StatefulWidget {
  const _StressButton();

  @override
  State<_StressButton> createState() => _StressButtonState();
}

class _StressButtonState extends State<_StressButton> {
  bool _running = false;

  Future<void> _run() async {
    final store = context.read<TraceStore>();
    setState(() => _running = true);
    for (var i = 0; i < 100; i++) {
      store.debugNotify();
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (!mounted) return;
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ElevatedButton(
            onPressed: _running ? null : _run,
            child: Text(_running ? 'running…' : 'Rebuild tree 100×'),
          ),
          const SizedBox(height: 4),
          Text(
            'Watch the overlay (bottom-right): F/s drops while PE/s = 0 → '
            'render is fragile independent of mouse input.',
            style: BxpText.body(context,
                color: t.textMuted, size: BxpSize.xs),
          ),
        ],
      ),
    );
  }
}

class _SectionTable extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;
  const _SectionTable({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(title.toUpperCase(), style: BxpText.label(context)),
          ),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            // top-align so when a value wraps to multiple lines (long
            // path strings) the label sits on the first line instead of
            // floating to the cell's vertical center.
            defaultVerticalAlignment: TableCellVerticalAlignment.top,
            children: [
              for (final (name, value) in rows)
                TableRow(children: [
                  Padding(
                    // tight 1-px vertical padding only — no explicit `height`
                    // on the TextStyle. Font's intrinsic line height + this
                    // padding gives a clean ~1-line row; the earlier `height:
                    // 1.5` stacked on top of the scheme's own metrics was
                    // producing ~3-line gaps between adjacent rows.
                    padding: const EdgeInsets.fromLTRB(0, 1, 12, 1),
                    child: Text(
                      name,
                      style: BxpText.body(context,
                          color: t.textPrimary, size: BxpSize.sm),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: SelectableText(
                      value,
                      style: BxpText.body(context,
                          color: t.textMuted, size: BxpSize.sm),
                    ),
                  ),
                ]),
            ],
          ),
        ],
      ),
    );
  }
}
