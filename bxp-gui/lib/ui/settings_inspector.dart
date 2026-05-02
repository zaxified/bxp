import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:json_ast_proto/ast.dart';
import 'package:provider/provider.dart';

import '../services/bxp_process_client.dart';
import '../store/trace_store.dart';
import 'layout_defaults.dart';
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
class SettingsInspector extends StatelessWidget {
  final VoidCallback onClose;
  const SettingsInspector({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = context.bxpTheme;
    final width = MediaQuery.sizeOf(context).width *
        LayoutDefaults.sidePanelFrac;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: onClose,
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
                    _Header(onClose: onClose),
                    Expanded(child: _Body()),
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

    final fmtPath = BxpProcessClient.findBin('bxp-fmt');
    final cliPath = BxpProcessClient.findBin('bxp-cli');
    final fmtEnv = Platform.environment['BXP_FMT_PATH'];
    final cliEnv = Platform.environment['BXP_CLI_PATH'];

    // Live trace counter — ticks ~10 Hz during a stream. Reading once at
    // build time would freeze; ValueListenableBuilder keeps just the
    // "trace lines" cell reactive without rebuilding the whole panel.
    return ValueListenableBuilder<int>(
      valueListenable: store.traceLinesCounter,
      builder: (context, traceLines, _) =>
          _buildTable(context, store, templates, fmtPath, cliPath, fmtEnv, cliEnv, traceLines),
    );
  }

  Widget _buildTable(
    BuildContext context,
    TraceStore store,
    List<String> templates,
    String? fmtPath,
    String? cliPath,
    String? fmtEnv,
    String? cliEnv,
    int traceLines,
  ) {
    // Whole-panel sections list. Built as flat (title, rows) groups so a
    // single Table at the bottom can compute one shared `IntrinsicColumnWidth`
    // for every label across every section — that way "lastExitCode" and
    // "$BXP_FMT_PATH" line up with "preset" and "dirty" in a single column,
    // which a per-section Table can't do.
    final sections = <(String, List<(String, String)>)>[
      ('Versions', [
        ('bxp-gui', store.bxpGuiVersion ?? '(unknown)'),
        ('bxp-fmt', store.bxpFmtVersion ?? '(unknown)'),
        ('bxp-cli', store.bxpCliVersion ?? '(unknown)'),
      ]),
      ('Binaries', [
        ('bxp-fmt', fmtPath ?? '(not found)'),
        ('bxp-cli', cliPath ?? '(not found)'),
        if (fmtEnv != null && fmtEnv.isNotEmpty)
          (r'$BXP_FMT_PATH', fmtEnv),
        if (cliEnv != null && cliEnv.isNotEmpty)
          (r'$BXP_CLI_PATH', cliEnv),
      ]),
      ('Config', [
        ('path', store.configPath.isEmpty ? '(none)' : store.configPath),
        ('dirty', store.isDirty.toString()),
        ('saving', store.isSaving.toString()),
        ('hasErrors (live)', store.configHasErrors.toString()),
        ('hadErrors (load)', store.configLoadHadErrors.toString()),
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
    ];

    // Per-section Tables — each computes its own `IntrinsicColumnWidth` for
    // the label column. A single panel-wide Table tried earlier interleaved
    // section-title rows with data rows in the same grid, which made the
    // first row of every section look offset (the header occupied col0 only
    // while the data row below jumped back to a left-aligned name). Splitting
    // means column widths reset per section, so labels never line up across
    // sections — but they always line up within one, and the layout reads
    // top-to-bottom without surprises.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (title, rows) in sections)
            _SectionTable(title: title, rows: rows),
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
