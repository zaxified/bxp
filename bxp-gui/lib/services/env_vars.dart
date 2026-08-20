/// Catalogue of every `BXP_*` environment variable the desktop app reads.
///
/// One entry per variable, co-located here rather than at the read site, so the
/// user-facing reference page (`docs/reference/environment.md`, written by
/// `tools/dart-doc-gen`) and the call sites share one source. Call sites
/// reference `EnvVars.<name>.name` instead of repeating the string literal —
/// the same pattern `Prefs` uses for persisted preference keys.
///
/// Deliberately no `defaultValue` field: the gui-mcp host/port defaults already
/// have a single home in `GuiMcpServer.kDefaultMcpHost` / `kDefaultMcpPort`,
/// and every other variable is an override with no default of its own.
library;

/// One documented environment variable.
class EnvVarDoc {
  /// The variable name as it appears in the environment.
  final String name;

  /// Human-facing description — the reference page's row text.
  final String description;

  /// True for variables that only take effect in a build compiled with the
  /// `BXP_UPDATE_TEST` define. They are inert in a released binary, so the
  /// user-facing reference page skips them; they stay catalogued because the
  /// call sites still read them through this table.
  final bool devOnly;

  const EnvVarDoc(this.name, this.description, {this.devOnly = false});
}

/// The catalogue of every environment variable bxp-gui reads. Named entries so
/// call sites reference e.g. `EnvVars.cliPath.name`; [all] drives the generated
/// reference page.
abstract final class EnvVars {
  static const cliPath = EnvVarDoc(
    'BXP_CLI_PATH',
    'Absolute path to the `bxp-cli` binary the desktop app should run, '
        'instead of the one bundled beside it.',
  );

  static const examplesPath = EnvVarDoc(
    'BXP_EXAMPLES_PATH',
    'Absolute path to the `bxp-cli.examples.json` the desktop app offers '
        'templates from.',
  );

  static const diagnostic = EnvVarDoc(
    'BXP_DIAGNOSTIC',
    'Set to `1` to write a diagnostic trace (plus captured engine stderr) '
        'next to the preferences file — attach it when reporting a bug.',
  );

  static const guiMcpHost = EnvVarDoc(
    'BXP_GUI_MCP_HOST',
    'Bind host of the desktop app\'s agent-control server (default '
        '`127.0.0.1`). The saved preference wins over this.',
  );

  static const guiMcpPort = EnvVarDoc(
    'BXP_GUI_MCP_PORT',
    'Bind port of the desktop app\'s agent-control server (default `7717`). '
        'The saved preference wins over this.',
  );

  static const guiMcpAutoApprove = EnvVarDoc(
    'BXP_GUI_MCP_AUTO_APPROVE',
    'Seeds the auto-approve gate at startup, so an agent can drive a freshly '
        'launched app without a click. The persisted toggle is the one that '
        'survives across launches.',
  );

  static const updateApi = EnvVarDoc(
    'BXP_UPDATE_API',
    'Release-metadata endpoint the updater polls instead of GitHub.',
    devOnly: true,
  );

  static const updatePubkey = EnvVarDoc(
    'BXP_UPDATE_PUBKEY',
    'Minisign public key the updater verifies `SHA256SUMS` against.',
    devOnly: true,
  );

  /// Every variable in display order.
  static const List<EnvVarDoc> all = [
    cliPath,
    examplesPath,
    diagnostic,
    guiMcpHost,
    guiMcpPort,
    guiMcpAutoApprove,
    updateApi,
    updatePubkey,
  ];
}
