<!-- GUI-ONLY:START -->
# Broker eXchange Parser (BXP Desktop)
<!-- GUI-ONLY:END -->
<!-- CLI-ONLY:START -->
# Broker eXchange Parser (BXP Console)
<!-- CLI-ONLY:END -->

A converter for broker export statements (CSV, XLSX, JSON) into
portfolio-tracker CSV formats using declarative JSON5 templates.
[Wealthfolio](https://wealthfolio.app/) and
[brycht.app](https://brycht.app/) are the two trackers with shipping
templates today; any other tracker is reachable by writing an
`output_schema` for it — no code changes. Everything runs locally; your
data never leaves the machine.

<!-- GUI-ONLY:START -->
The desktop bundle adds a graphical editor and dry-run debugger on top
of the same conversion engine, so you can edit templates and preview
their behaviour against your real broker exports without leaving the
app. Three binaries ship together:

- **`bxp-gui`** — the Flutter desktop application (this app).
- **`bxp-cli`** — the conversion engine. Produces the actual `.csvx`
  files. The GUI runs it (proxied through the bundled bridge library);
  you can also run it directly from a terminal.
- **`bxp-mcp`** — an MCP server (JSON-RPC over stdio) that exposes bxp's
  stateless surface to an AI agent — validate a config or expression,
  evaluate, list templates, read the docs — and runs a full conversion
  end-to-end via its `bxp_simulate` tool. Lets an assistant author and
  self-test a template without driving the GUI.

This readme is a **superset of the bxp-console readme**: everything in
the console package's documentation is included below, plus the GUI
workflow sections.
<!-- GUI-ONLY:END -->
<!-- CLI-ONLY:START -->
The console package ships two binaries that work together:

- **`bxp-cli`** — the conversion engine. Produces the actual `.csvx`
  files from your broker exports and the JSON5 templates.
- **`bxp-mcp`** — an MCP server (JSON-RPC over stdio) that exposes bxp's
  stateless surface to an AI agent — validate a config or expression,
  evaluate, list templates, read the docs — and runs a full conversion
  end-to-end via its `bxp_simulate` tool. Lets an assistant author and
  self-test a template without driving the GUI.
<!-- CLI-ONLY:END -->

---

<!-- GUI-ONLY:START -->
## Installation

Each release ships one artefact per platform, downloadable via stable
GitHub URLs that always point at the latest version.

### Linux

```bash
sudo apt install libfuse2t64   # libfuse2 on older distros
mkdir -p ~/.local/bin && cd ~/.local/bin
wget https://github.com/zaxified/bxp/releases/latest/download/bxp-desktop-linux-x86_64.AppImage
chmod +x bxp-desktop-linux-x86_64.AppImage
./bxp-desktop-linux-x86_64.AppImage   # first launch prompts to install menu + icons
```

The AppImage lives in `~/.local/bin/` (typically on `PATH`). User
preferences auto-save to `~/.local/share/bxp-gui/bxp-gui.json` on first
edit. The Linux AppImage is the only Linux distribution channel; `.deb`
and plain tarballs were retired in v0.2.3 to keep one update path. On
first launch the AppImage offers to write
`~/.local/share/applications/bxp-gui.desktop` plus `hicolor` icons so
the app shows up in the system menu — no `sudo` needed, reversible from
the Settings drawer.

### Windows

Download
[`bxp-desktop-windows-x86_64.exe`](https://github.com/zaxified/bxp/releases/latest/download/bxp-desktop-windows-x86_64.exe)
and run the NSIS installer. SmartScreen may warn — "More info" → "Run
anyway". The app installs to `C:\Program Files\bxp-gui\` with a Start
menu entry and desktop shortcut. User preferences live at
`%APPDATA%\bxp-gui\bxp-gui.json`.

### macOS (Apple Silicon)

Download
[`bxp-desktop-macos-arm64.dmg`](https://github.com/zaxified/bxp/releases/latest/download/bxp-desktop-macos-arm64.dmg),
open it, drag `bxp-gui.app` to `/Applications/`. First launch:
right-click `bxp-gui.app` → Open → Open (bypasses Gatekeeper once).
Subsequent launches go through Spotlight / Launchpad / Dock. User
preferences live at `~/Library/Application Support/bxp-gui/bxp-gui.json`.

---
<!-- GUI-ONLY:END -->

## Basic usage

<!-- GUI-ONLY:START -->
The GUI is the primary entry point; the bundled CLI binaries are also
runnable from a terminal for scripting or batch use.

### Three-step recipe (GUI)

1. **File → Open** (or `Ctrl+O`). Pick your `bxp-cli.json`.
2. Select a template in the toolbar dropdown, click `dry-run`. The
   bottom pane streams trace events for every input row.
3. Inspect the trace, fix any errors that appear inline in the tree,
   then click `full-run` to produce the `.csvx` files.

### Three-step recipe (terminal — when running bxp-cli directly)
<!-- GUI-ONLY:END -->
<!-- CLI-ONLY:START -->
### Three-step recipe
<!-- CLI-ONLY:END -->

1. Drop the broker's export file into the template's `data_dir`.
2. Run `./bxp-cli --template <id>`.
3. Pick up the generated `*.csvx` file next to the input — ready to
   import into the tracker the template targets (Wealthfolio for
   `*_to_wealthfolio`, brycht.app for `*_to_brychtapp`).

### Built-in templates

| Template ID | Broker |
| --- | --- |
| `revolutx_to_wealthfolio` | Revolut X (crypto) |
| `trading212_to_wealthfolio` | Trading 212 |
| `anycoin_to_wealthfolio` | Anycoin (crypto) |
| `xtb1_closed_to_wealthfolio` | XTB — closed positions (old) |
| `xtb1_cash_to_wealthfolio` | XTB — cash operations (old) |
| `xtb2_closed_to_wealthfolio` | XTB — closed positions (new) |
| `xtb2_cash_to_wealthfolio` | XTB — cash operations (new) |
| `trading212_to_brychtapp` | Trading 212 → brycht.app (tracker) |
| `xtb2_cash_to_brychtapp` | XTB — cash operations (new) → brycht.app (tracker) |
| `xtb2_closed_to_brychtapp` | XTB — closed positions (new) → brycht.app (tracker) |

<!-- GUI-ONLY:START -->
### Keyboard shortcuts

All shortcuts are global (work even while a side panel has focus),
except where noted.

| Combo | Action |
| --- | --- |
| `Ctrl+O` | Open config file picker |
| `Ctrl+S` | Save (writes the in-memory AST back to disk) |
| `Ctrl+R` | Reload config from disk (discard unsaved edits) |
| `Ctrl+Z` | Undo last edit (inside text fields: native typo-undo) |
| `Ctrl+Y` | Redo |
| `Ctrl+T` | Reset draft to the on-disk file |
| `Ctrl+E` | Validate the current draft (in-process, via the bundled bridge) |
| `Ctrl+Shift+S` | Toggle the settings / runtime inspector drawer |
| `Ctrl+Shift+T` | Toggle theme inspector |
| `Ctrl+Scroll` | Zoom the whole UI |
| `Ctrl+0` | Reset zoom |
| `Ctrl++` / `Ctrl+-` | Step zoom up / down |
| `Esc` | Close any open dialog or inspector |

The toolbar's `dry-run` and `full-run` buttons have no shortcuts —
clicking them is the only way to start a run, and clicking again while
a run is active cancels it (the label flips to `cancel`).
<!-- GUI-ONLY:END -->

### `bxp-cli` reference

All flags are optional. Without arguments, bxp-cli reads `bxp-cli.json`
from the current directory and processes every template in it.

| Flag | Argument | What it does |
| --- | --- | --- |
| `--config <file>` | path | Use a specific config file. Default: `./bxp-cli.json` in the current directory. |
| `--template <id>` | template id | Process only the named template. Without it, all templates run. |
| `--data <dir>` | directory path | Override the template's `data_dir`. Useful for testing with files in a different location. |
| `--debug` | — | Print rows no `row_rules` entry matched (when `row_rules_debug_missing: true`). JSON on stdout. |
| `--debug=json` | — | Emit one machine-readable JSON run summary on stdout (per-template + overall `files`/`rows_in`/`rows_out`/`warnings`/`errors`/`time_ms`, plus captured warning/error lines) instead of the human stdout + stderr output. For scripting / CI. Conflicts with `--trace` / `--quiet` / `--debug`. |
| `--quiet` | — | Suppress per-template summaries. Exit code still reflects success / warnings / failure. |
| `--fresh` | — | Skip files whose output already exists. Useful when re-running on a folder where some `.csvx` files are already produced. |
| `--check-fs=N` | seconds (0–60) | Run extra filesystem-existence checks (verifies `data_dir`, etc.). `N` is the deadline in seconds — `0` skips entirely (default). |
| `--version` | — | Print the binary version to stdout and exit. |
| `--help` | — | Print the built-in help to stdout and exit. |

```bash
./bxp-cli --help                                  # print usage
./bxp-cli                                         # process all templates from bxp-cli.json
./bxp-cli --template <id>                         # process a single template
./bxp-cli --template <id> --data ./my-data/       # override data_dir for that template
```

### `bxp-mcp` reference (for AI agents)

`bxp-mcp` is an MCP server (JSON-RPC 2.0 over stdio) that exposes bxp's
stateless surface as agent-callable tools — everything an assistant
needs to author and self-test a template without touching the GUI. It
ships next to `bxp-cli` so its `bxp_simulate` tool can spawn it.

Register it with an MCP-capable client (e.g. Claude Code, in
`~/.claude.json`):

```json
{ "mcpServers": { "bxp": { "command": "/abs/path/to/bxp-mcp", "args": [] } } }
```

…or drive it directly — one JSON-RPC object per line on stdin:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bxp_validate_expr","arguments":{"expr":"IF([Qty] > 0, '\''BUY'\'', '\''SELL'\'')"}}}' \
  | ./bxp-mcp
```

| Tool | Arguments | Purpose |
| --- | --- | --- |
| `bxp_validate` | `config` (JSON5 text) | Validate a config; returns annotated JSON with `$err_*` / `$warn_*` / `$info_*` / `$comm_*` siblings. |
| `bxp_validate_expr` | `expr` | Authoring-time check of one expression (syntax + semantics + static lint, e.g. a literal `SPLIT_PART(…, 0)`). `{ok:true}` or `{ok:false,error,detail,off,len}`. |
| `bxp_eval` | `expr`, `headers?`, `fields?` | Evaluate one expression against an optional row — what it *computes* (lenient runtime). `{ok,value}` or `{ok:false,…}`. |
| `bxp_eval_trace` | `expr`, `headers?`, `fields?` | Evaluate with a per-call NDJSON trace (one line per nested function call, then a `final` / `error` sentinel). |
| `bxp_eval_batch` | `headers`, `fields`, `exprs` | Evaluate many expressions against one row in a single call. |
| `bxp_list_templates` | `config` | List every template id declared in the config. |
| `bxp_fetch_template` | `config`, `id` | Return one template's raw JSON. |
| `bxp_docs` | — | Full function / config-schema catalog (the same source the GUI's autocomplete uses). |
| `bxp_simulate` | `config`, `template`, `csv` | Run a full conversion end-to-end against the supplied CSV; returns the output, a record-count diff, diagnostics, and a per-row trace. The strongest self-test — verifies `pre_pass` / `LOOKUP` / `row_rules` for real. |

A tool *failure* (e.g. a missing required argument) sets `isError:true`
on the JSON-RPC result; a domain `{"ok":false,…}` answer (an expression
error, a not-found template) is a valid result the agent should read,
not a failure. See `docs/mcp.md` for the full wire protocol.

<!-- GUI-ONLY:START -->
### `bxp-gui` reference

The GUI takes no command-line flags. It reads its preferences file (path
listed below) and remembers the last-opened config across launches.
<!-- GUI-ONLY:END -->

### Exit codes

| Binary | Code | Meaning |
| --- | --- | --- |
| bxp-cli | `0` | Success — all matched rows converted, no warnings. |
| bxp-cli | `1` | Fatal error — config invalid, file missing, expression failure. |
| bxp-cli | `2` | Completed with warnings — output written but at least one warning emitted (typo'd field, no input rows, …). |

`bxp-mcp` exits `0` in normal operation; per-tool outcomes ride on the
JSON-RPC response (the `isError` flag / a domain `{"ok":false}`), not the
process exit code.

### Where output goes

- **stdout** — bxp-cli per-template summaries and `--debug` JSON dumps.
  (bxp-mcp also writes its JSON-RPC responses to stdout, but that's the
  agent protocol channel, not something you pipe by hand.)
- **stderr** — fatal errors and warning text. Pipe `2>/dev/null` to
  silence warnings while still capturing exit code.

Don't pipe `2>&1` if you intend to feed stdout to another tool —
bxp-cli's streaming output assumes stdout and stderr stay separate.

---

<!-- GUI-ONLY:START -->
## User preferences

Settings (theme, recent files, custom places, zoom level) are stored in
a single visible JSON file:

| Platform | Path |
| --- | --- |
| Linux | `~/.local/share/bxp-gui/bxp-gui.json` |
| macOS | `~/Library/Application Support/bxp-gui/bxp-gui.json` |
| Windows | `%APPDATA%\bxp-gui\bxp-gui.json` |

Delete the file to reset everything to defaults.

---

## Auto-updates

The app polls `github.com/zaxified/bxp` for new releases 5 seconds
after launch and every 6 hours thereafter. When a newer version is
available a dialog offers a one-click update that downloads,
SHA256-verifies, and dispatches to the platform-native installer:

- **Windows** — silent NSIS reinstall, GUI relaunches automatically.
- **macOS** — DMG mount, copy to `/Applications/`, relaunch.
- **Linux AppImage** — atomic in-place replace + re-`exec()`.

The updater is skipped during development builds. Linux builds running
outside an AppImage (rare — only when someone runs `flutter run`
locally) and macOS Intel surface a "manual update required" message
with the release page URL.

---
<!-- GUI-ONLY:END -->

## Need a broker that isn't listed?

**Ask your AI assistant.** bxp-cli templates are plain JSON5 — a capable
AI (Claude, ChatGPT, …) can write one for you. **Two files are required
context:** this `readme.md` AND `bxp-cli.examples.json` (also at the
project's GitHub repository). The readme defines the language and the
target output spec; the examples.json carries working per-broker
patterns the AI is expected to pattern-match against. If the AI doesn't
have examples.json, it will refuse to guess.

Paste this prompt into your assistant, attach both files, then drop in
5 rows of your broker's raw CSV:

> *"I use BXP. Please read the **Advanced usage** section of `readme.md`
> and the comments in `bxp-cli.examples.json`. Here is a sample of my
> broker's export: `<paste 5 rows including the header>`. Add a new
> entry under `conversion_templates` in my `bxp-cli.json` that converts
> this to Wealthfolio CSV, following the same patterns as the existing
> templates. Follow the rules in the 'Rules for an AI assistant'
> section: self-test your output (validate the config, then run it
> against the sample rows — via the bxp-mcp tools if available, else
> `bxp-cli --debug`) before returning, return JSON5 with `//` comments
> explaining non-obvious decisions, and end your reply with a 'Things
> to check in bxp-gui' list for anything you couldn't fully verify."*

<!-- GUI-ONLY:START -->
After the AI proposes a template, paste it into the GUI's tree editor
(or directly into your `bxp-cli.json`) and run a dry-run. The GUI's
inline error chips will tell you exactly which expressions need fixing,
and the AI's "Things to check in bxp-gui" list tells you what to look
for next.
<!-- GUI-ONLY:END -->

---

## Advanced usage

This section is written so that a capable AI assistant can produce a
working broker template given only this file and `bxp-cli.examples.json`.
It is also useful as a human reference.

### Architecture in one paragraph

bxp-cli is a two-pass declarative data pipeline. Pass one (optional
`pre_pass`) scans all rows and builds a lookup table for cross-row
joins. Pass two iterates rows, evaluates `input_schema` expressions
into per-row `$variable`s, then routes each row through the ordered
`row_rules` list — the first matching rule decides the row's activity
type and whether it produces 0, 1, or N output rows. `output_schema`
then projects the final `$variable`s into CSV columns in a fixed order.
Input may be CSV, XLSX, or JSON; output is RFC 4180–compliant CSV or
JSON.

### `bxp-cli.json` layout

```json5
{
  ticker_maps: {
    // optional; named, reusable symbol remapping tables
    // map_name → { broker_symbol: yahoo_symbol, ... }
    // templates reference a map by name or define one inline
    anycoin:  { "BTC": "BTC-EUR" },
    revolutx: { "BTC": "BTC-USD" },
  },
  conversion_templates: {
    // required; map of template_id → template config (see skeleton below)
    mybroker_to_wealthfolio: { /* ... */ },
  },
}
```

All `data_dir` paths are resolved relative to the location of
`bxp-cli.json`.

### Blank template skeleton (copy, fill in, run)

```json5
mybroker_to_wealthfolio: {

  // required; path to input files, relative to bxp-cli.json
  data_dir:                  "mybroker_to_wealthfolio",

  // default "csv"; options: "csv", "json" (array-of-objects)
  file_type_in:              "csv",
  file_type_out:             "csv",

  // required; literal suffix filter (endsWith, NOT a glob), e.g. ".csv" / "_closed.csv"
  file_pattern_in:           ".csv",
  // required; suffix of output filename, replaces file_pattern_in
  file_pattern_out:          ".csvx",

  // input CSV parsing — match the broker's actual format
  csv_delimiter_in:          ",",       // ",", ";", "\t", "|", ...
  csv_decimal_separator_in:  ".",       // ".", ","
  csv_text_quote_in:         "double",  // "none" | "single" ' | "double" "

  // output CSV formatting
  csv_delimiter_out:         ",",
  csv_decimal_separator_out: ".",
  csv_text_quote_out:        "none",

  // default false; when true rows whose $date is outside the date range encoded
  // in the filename (YYYY-MM-DD_YYYY-MM-DD) are silently skipped. Requires $date.
  date_filter_from_filename: false,

  // default false; when true all input files also write to a merged
  // 1-{template_id}-combined{file_pattern_out} file in data_dir
  // combined_output:              false,

  // optional; either a name from top-level ticker_maps, or an inline object
  ticker_map:                { /* "BROKER-SYM": "YAHOO-SYM" */ },

  // optional; xlsx sheet extraction — omit for plain CSV input
  // xlsx_sheet: { name: "CLOSED POSITION", header_row: 13, output_suffix: "_closed" },

  // optional; first-pass lookup table for cross-row joins (e.g. paired trade rows)
  // pre_pass: {
  //   when:   "[Type] = 'trade payment'",    // which rows to collect
  //   key:    "[Order ID]",                  // expression used as lookup key
  //   values: {                              // plain field names (no $ prefix)
  //     amount:   "ABS([Amount])",
  //     currency: "[Currency]",
  //   },
  // },

  // required; $variable definitions evaluated once per input row.
  // [Column Name] = raw CSV field by header; [n] = field by 1-based index.
  input_schema: {
    $date:           "DATE_CONVERT([Date], 'DD/MM/YYYY hh:mm:ss', 'YYYY-MM-DD hh:mm:ss')",
    $ticker:         "TICKER([Symbol])",
    $quantity:       "[Quantity]",
    $unitprice:      "[Price]",
    $currency:       "[Currency]",
    $fee:            "[Fee]",
    $amount:         "[Total]",
    $account:        "",      // optional; e.g. "'MyBroker'", "[Account]"
    $fxRate:         "",      // optional
    $subtype:        "",      // optional
    $instrumentType: "",      // optional; e.g. "'Cryptocurrency'"
    $comment:        "",      // optional
  },

  // default false; unmatched rows are printed with --debug when true
  row_rules_debug_missing: true,

  // ordered list — first match wins. rows: [] = silent skip.
  // $action MUST be set here, never in input_schema.
  row_rules: [
    { when: "[Action] = 'Buy'",      rows: [ { $action: "'BUY'"  } ] },
    { when: "[Action] = 'Sell'",     rows: [ { $action: "'SELL'" } ] },
    { when: "[Action] = 'Deposit'",  rows: [ { $action: "'DEPOSIT'"  } ] },
    { when: "[Action] = 'Withdraw'", rows: [ { $action: "'WITHDRAWAL'" } ] },
    // ignored row types go here with rows: []
  ],

  // required; output CSV header → $variable. Controls columns and their order.
  output_schema: {
    date:           "$date",
    symbol:         "$ticker",
    quantity:       "$quantity",
    activityType:   "$action",
    unitPrice:      "$unitprice",
    currency:       "$currency",
    fee:            "$fee",
    amount:         "$amount",
    account:        "$account",
    fxRate:         "$fxRate",
    subtype:        "$subtype",
    instrumentType: "$instrumentType",
    comment:        "$comment",
  },
},
```

### Template field reference

| Field | Type | Required | Default | Purpose |
| --- | --- | --- | --- | --- |
| `data_dir` | string | yes | — | Directory with input files; relative to `bxp-cli.json` |
| `file_type_in` | string | no | `"csv"` | `"csv"` or `"json"` (array-of-objects) |
| `file_type_out` | string | no | `"csv"` | `"csv"` or `"json"` |
| `file_pattern_in` | string | yes | — | Suffix filter, e.g. `".csv"`, `"_closed.csv"` |
| `file_pattern_out` | string | no | append `x` | Replaces `file_pattern_in` in output filename |
| `csv_delimiter_in` | string | no | `","` | Field separator of input CSV |
| `csv_delimiter_out` | string | no | `","` | Field separator of output CSV |
| `csv_decimal_separator_in` | string | no | `"."` | Decimal separator in numeric fields (input) |
| `csv_decimal_separator_out` | string | no | `"."` | Decimal separator in numeric fields (output) |
| `csv_text_quote_in` | string | no | `"double"` | `"none"`, `"single"` (`'`), or `"double"` (`"`) |
| `csv_text_quote_out` | string | no | `"none"` | Same values as `csv_text_quote_in` |
| `csv_input_encoding` | string | no | `"utf-8"` | Encoding of the input CSV, transcoded to UTF-8 on read. `"utf-8"`, `"windows-1250"`, `"windows-1252"`, `"iso-8859-1"`, `"iso-8859-2"`, `"iso-8859-15"`. Use for legacy non-UTF-8 exports (e.g. Czech Excel `"windows-1250"`). CSV only |
| `csv_output_encoding` | string | no | `"utf-8"` | Encoding of the output CSV. Same values as `csv_input_encoding`; characters with no equivalent become `?`. CSV only |
| `csv_header_line` | number | no | `1` | 1-based line of the CSV header. `0` = headerless (first line is data, columns reachable only by `FIELDS(n)`); `N>1` skips `N-1` preamble lines. CSV input only |
| `date_filter_from_filename` | bool | no | `false` | Filter rows by `YYYY-MM-DD_YYYY-MM-DD` range in filename |
| `ticker_map` | string \| object | no | `{}` | Name from `ticker_maps`, or inline `{ "SYM": "YAHOO" }` |
| `xlsx_sheet` | object | no | — | `{ name, header_row, output_suffix }` — convert xlsx before CSV |
| `pre_pass` | object | no | — | `{ when, key, values }` — first-pass lookup table |
| `input_schema` | object | yes | — | `$variable` → expression, evaluated per row |
| `row_rules_debug_missing` | bool | no | `false` | Print unmatched rows with `--debug` |
| `row_rules` | array | yes | — | Ordered routing rules; first match wins |
| `output_schema` | object | yes | — | Output CSV header → `$variable`; defines column order |
| `combined_output` | bool | no | `false` | When `true`, all input files additionally write rows to one merged file `1-{template_id}-combined{file_pattern_out}` in `data_dir`, alongside the normal per-file outputs |

### Standard `$variable` reference

Output `$variable`s that bxp-cli's Wealthfolio templates set. The first
eight map 1:1 to Wealthfolio's import columns; the rest are optional.

| Variable | Meaning |
| --- | --- |
| `$date` | Transaction datetime, format `YYYY-MM-DD hh:mm:ss` |
| `$ticker` | Yahoo Finance ticker (after `TICKER()` mapping) |
| `$quantity` | Number of units |
| `$unitprice` | Price per unit |
| `$currency` | Currency code (`USD`, `EUR`, `CZK`, …) |
| `$fee` | Fee amount (empty if broker does not report one) |
| `$amount` | Total transaction value |
| `$action` | Activity type — **set only in `row_rules`**, never in `input_schema` |
| `$account` | Account tag (optional) |
| `$fxRate` | FX rate (optional) |
| `$subtype` | Wealthfolio subtype (optional) |
| `$instrumentType` | e.g. `'Cryptocurrency'` (optional) |
| `$comment` | Free-form comment (optional) |

Typical `$action` values for Wealthfolio: `'BUY'`, `'SELL'`, `'DEPOSIT'`,
`'WITHDRAWAL'`, `'DIVIDEND'`, `'TAX'`, `'INTEREST'`, `'FEE'`. An empty
`""` expression omits the variable from output.

### Expression language — full reference

Expressions are strings evaluated once per row. Operator precedence,
high → low:

```text
unary -    →    * /    →    & (concat)    →    + -    →    = != < > <= >=    →    NOT    →    AND    →    OR
```

#### Column and literal syntax

| Syntax | Description |
| --- | --- |
| `[ColumnName]` | Raw CSV field by header name (leading/trailing spaces trimmed) |
| `[n]` | Raw CSV field by 1-based column index |
| `'text'` | String literal |
| `123`, `-0.5` | Numeric literal |
| `&` | String concatenation (`'$CASH-' & [Currency]`) |
| `$variable` | Reference to a variable set earlier in `input_schema` |

Column header names may contain spaces, parentheses, currency symbols,
and other punctuation — `[Price ($)]`, `[Run Date]`, and
`[Stamp duty reserve tax]` are all valid references. The bracket
syntax preserves the header verbatim; only the closing `]` itself is
reserved.

**Built-in functions** (all names are case-insensitive)

| Function | Returns | Description |
| --- | --- | --- |
| `IF(cond, yes, no)` | any | Short-circuit conditional; only the selected branch is evaluated |
| `ABS(x)` | number | Absolute numeric value |
| `ROUND(x, n)` | number | Round `x` to `n` decimal places (negative `n` rounds tens/hundreds) |
| `FLOOR(x)` | number | Largest integer ≤ `x` |
| `CEILING(x)` | number | Smallest integer ≥ `x` |
| `TRIM(s)` | string | Strip leading/trailing whitespace |
| `REPLACE(s, old, new)` | string | Replace all occurrences of `old` with `new`; if `old` is empty, returns `s` |
| `SPLIT_PART(s, delim, n)` | string | Split `s` by `delim`, return 1-based nth part; `""` if out of range |
| `CONTAINS(s, sub)` | bool | `true` when `sub` is found inside `s` |
| `PRICE_VALUE(s)` | string | Strip currency symbol/code: `"24.00 CZK"` → `"24.00"`, `"$100"` → `"100"` |
| `PRICE_CURRENCY(s)` | string | Extract ISO currency: `"24.00 CZK"` → `"CZK"`, `"$100"` → `"USD"` |
| `TICKER(s)` | string | Map `s` through the template's `ticker_map`; pass through if not found |
| `DATE_CONVERT(s, from, to)` | string | Parse `s` using `from` format, emit using `to` format (tokens below) |
| `LOOKUP(key, 'field')` | string | Retrieve a value stored by `pre_pass` under `key` / `field` |
| `FIELDS(n)` | string | Same as `[n]` — raw field by 1-based index |
| `NOW()` | string | Current UTC datetime, format `YYYY-MM-DDTHH:MM:SSZ` |
| `RAND(n)` | string | `n` random digits (first 1–9, rest 0–9); `n` clamped to 1–65 |
| `COALESCE(a, b, ...)` | any | First non-empty argument (empty = whitespace-only string); falls back to last arg verbatim if all empty |
| `LEFT(s, n)` | string | First `n` bytes of `s` (`n` clamped to `[0, len]`; negative / non-finite → `""`) |
| `RIGHT(s, n)` | string | Last `n` bytes of `s` (same clamping) |
| `SUBSTR(s, start, len)` | string | `len` bytes from 1-based `start`; non-positive / non-finite `start` or `len` → `""` |
| `UPPER(s)` / `LOWER(s)` | string | Full-Unicode case conversion (`café`→`CAFÉ`, `ß`→`SS`, `я`→`Я`); unicameral scripts (CJK/Arabic/Hebrew) and invalid UTF-8 bytes pass through unchanged |
| `UNACCENT(s)` | string | Strip Latin diacritics (`café`→`cafe`, `ÀÉ`→`AE`, `ß`→`ss`, `ø`→`o`); Latin-scope like Postgres — non-Latin keeps its base script (`Ά`→`Α`), CJK/Arabic pass through, ligatures not folded |
| `LEN(s)` | number | Byte length of `s` (UTF-8 byte count, not codepoints); empty → `0` |
| `STARTS_WITH(s, prefix)` | bool | `true` when `s` begins with `prefix` (case-sensitive); empty `prefix` always matches |
| `ENDS_WITH(s, suffix)` | bool | `true` when `s` ends with `suffix` (case-sensitive); empty `suffix` always matches |
| `IN(value, v1, v2, ...)` | bool | `true` when `value` equals any of `v1, v2, …` — variadic equality OR-chain |
| `NULLIF(value, sentinel)` | any | `""` when `value` = `sentinel`, else `value`; collapses sentinels (`-9999`, `\N`, `N/A`) |
| `GREATEST(a, b, ...)` | number | Largest numeric value among args — per-row maximum, not cross-row aggregation |
| `LEAST(a, b, ...)` | number | Smallest numeric value among args — per-row minimum |

**Date arithmetic functions** — all take/return ISO `YYYY-MM-DD` strings; an empty date arg yields `""`, a malformed one errors. Pre-1970 dates fully supported.

| Function | Returns | Description |
| --- | --- | --- |
| `DATEADD(d, n)` | string | Add `n` calendar days to `d` (negative subtracts) |
| `DATEDIFF(d1, d2)` | number | Calendar days from `d2` to `d1` (positive when `d1` is later) |
| `WORKDAY(d, n)` | string | Add `n` business days to `d`, skipping Sat/Sun (negative subtracts); `n=0` returns `d`. No exchange-holiday awareness |
| `YEAR(d)` / `MONTH(d)` / `DAY(d)` | number | Year / month (1–12) / day-of-month (1–31) component of `d` |
| `WEEKDAY(d)` | number | ISO day-of-week (Mon=1 … Sun=7); weekend trade = `WEEKDAY([Date]) > 5` |
| `EOMONTH(d)` | string | Last calendar day of `d`'s month (month-end snapping) |
| `NTH_DOW(year, month, weekday, n)` | string | Date of the `n`-th `weekday` (Mon=1 … Sun=7) in `year`/`month`; negative `n` counts from month end (`-1` = last); `""` if it doesn't exist. EU DST = `NTH_DOW(YEAR(d), 3, 7, -1)` … `NTH_DOW(YEAR(d), 10, 7, -1)` |

#### Function semantics — common gotchas

- **`CONTAINS(s, sub)` is a substring match, not a prefix match.** It
  returns `true` whenever `sub` appears *anywhere* inside `s`, which
  means `CONTAINS('Sell to Buy', 'Buy')` is `true`. Brokers with
  prefix-based action codes (Schwab `MKT BUY` / `LMT BUY`, IBKR
  multi-word actions) need an exact or word-boundary check: prefer
  exact comparison (`[Action] = 'Buy'`), `SPLIT_PART([Action], ' ', 1) = 'Buy'`
  for the first word, or stack `CONTAINS` checks to exclude false
  matches (`CONTAINS([Action], 'Buy') AND NOT CONTAINS([Action], 'Sell')`
  is not yet expressible — use a more specific positive match instead).
- **`SPLIT_PART(s, delim, n)` is 1-based and returns `""` on out-of-range.**
  Out-of-range never errors — silent empty makes it safe to chain but
  hides off-by-one bugs. Trace the variable in `bxp-gui` if the output
  is empty unexpectedly.

#### Type coercions

- Empty string → `0` in a numeric context.
- Any non-empty string → `true` in a boolean context; empty string → `false`.
- Numeric strings are parsed on demand; `csv_decimal_separator_in` controls which decimal separator is accepted.
- American thousands-separated numbers (`1,234.56`, `-1,234,567`) are automatically parsed in arithmetic contexts; the original string is preserved when the field is passed through as-is to output.

#### Minimal examples

```text
'$CASH-' & [Currency]                                          → string concat
IF([Type] = 'Buy', 'BUY', IF([Type] = 'Sell', 'SELL', ''))     → nested conditional
[Action] = 'Buy' OR CONTAINS([Action], 'Buy to')               → match action variants
ROUND(ABS([Total]) / [Quantity], 4)                            → derived unit price
DATE_CONVERT([Date], 'DD/MM/YYYY hh:mm:ss', 'YYYY-MM-DD hh:mm:ss')
LOOKUP([Order ID], 'amount') / [Amount]                        → cross-row join via pre_pass
PRICE_VALUE([Price])                                           → strip currency symbol
SPLIT_PART([Comment], ' @ ', 2)                                → second part after " @ "
[Commission ($)] + [Fees ($)]                                  → sum two raw numeric columns
```

### Date format tokens

Both the `from` and `to` arguments of `DATE_CONVERT` use the same token
set. Any characters that are not tokens are matched literally.

| Token | Meaning | Example |
| --- | --- | --- |
| `YYYY` | 4-digit year | `2026` |
| `YY` | 2-digit year (00–69 → 2000s, 70–99 → 1970s) | `26` |
| `MM` | 2-digit month (01–12) | `03` |
| `M` | 1–2 digit month | `3` |
| `MMMM` | Full month name | `March` |
| `MMM` | 3-char month abbreviation | `Mar` |
| `DD` | 2-digit day | `07` |
| `D` | 1–2 digit day | `7` |
| `hh` | 2-digit hour, **24h** (00–23) | `14` |
| `h` | 1–2 digit hour, 24h | `14` |
| `ii` | 2-digit hour, **12h** (01–12) | `02` |
| `i` | 1–2 digit hour, 12h | `2` |
| `mm` | 2-digit minute | `05` |
| `m` | 1–2 digit minute | `5` |
| `ss` | 2-digit second | `09` |
| `s` | 1–2 digit second | `9` |
| `A` | AM/PM uppercase | `PM` |
| `a` | am/pm lowercase | `pm` |
| `EEEE` | Full day name | `Monday` |
| `EEE`/`EE`/`E` | Short day name | `Mon` |
| `e` | Day of week as number (1 = Mon … 7 = Sun) | `1` |
| `[text]` | Literal text (escaped inside format string) | `[T]` → `T` |
| `[*]` | Wildcard — skip until the next token | skips `Z`, timezone suffix, etc. |

#### Gotchas

- `mm` is minute; `MM` is month — easy to mix up.
- `MMM` expects exactly 3 characters; 4-character variants like `Sept`
  and `June` are pre-normalized automatically.
- Dates before 1970 are fully supported — birthdates, census, and
  archival dates convert losslessly.
- Components not present in the `from` format default to `1970-01-01 00:00:00`.

#### Worked date examples

```text
"26 Jun 2022, 16:02:36"       →  'DD MMM YYYY, hh:mm:ss'
"2024-02-23T06:20:20.182Z"    →  'YYYY-MM-DDThh:mm:ss[*]'   (skips .182Z)
"07/03/2026 14:05:00"         →  'DD/MM/YYYY hh:mm:ss'
"2026-01-05 05:20:18"         →  'YYYY-MM-DD hh:mm:ss'      (canonical output)
```

### `pre_pass` — cross-row joins

Use `pre_pass` when an input row needs data that lives on **another
row** (for example, Anycoin writes `trade payment` and `trade fill` as
two rows sharing an `Order ID`). bxp-cli makes a first pass over the
file, collects rows matching `when`, and stores `values` under `key`.
Then `input_schema` can read them via `LOOKUP(key, 'field')`.

```json5
pre_pass: {
  when:   "[Type] = 'trade payment'",      // which rows to collect
  key:    "[Order ID]",                    // expression used as the lookup key
  values: {
    amount:   "ABS([Amount])",             // accessed as LOOKUP(..., 'amount')
    currency: "[Currency]",                // accessed as LOOKUP(..., 'currency')
  },
},

input_schema: {
  $unitprice: "LOOKUP([Order ID], 'amount') / [Amount]",
  $currency:  "LOOKUP([Order ID], 'currency')",
},
```

Note: keys inside `values` are **plain field names**, not `$variables`,
and they are not visible to `row_rules` or `output_schema` directly —
only through `LOOKUP()`.

### Wealthfolio target spec

The output `.csvx` is consumed by Wealthfolio. The conventions below
are enforced by the existing built-in templates and are the canonical
reference for new templates — Wealthfolio itself does not ship a
machine-readable spec, so "what the existing templates do" is the
de-facto contract.

**Sign conventions.** All three numeric variables are always positive;
direction (buy vs sell, deposit vs withdrawal) is encoded in `$action`,
not in the sign of the amount.

| Variable | Convention |
| --- | --- |
| `$amount` | Always positive — wrap raw broker values in `ABS()` if your broker reports signed values. |
| `$quantity` | Always positive — `ABS()` if needed. |
| `$fee` | Always positive (a cost). `ABS()` if needed. |

**Activity-type vocabulary.** `$action` is set inside `row_rules`.
Eight values cover every event the built-in templates emit:

| Action | When |
| --- | --- |
| `'BUY'` | Buy / acquisition |
| `'SELL'` | Sell / disposal |
| `'DEPOSIT'` | Cash deposit into the account |
| `'WITHDRAWAL'` | Cash withdrawal |
| `'DIVIDEND'` | Dividend received |
| `'TAX'` | Tax withheld |
| `'INTEREST'` | Interest paid (e.g. on cash balance) |
| `'FEE'` | Fee charged (e.g. monthly account fee, ADR fee) |

Three additional values handle portfolio bookkeeping events that
Wealthfolio also imports:

| Action | When |
| --- | --- |
| `'TRANSFER_IN'` | Stock moved into the account from elsewhere (zero-cost arrival) |
| `'TRANSFER_OUT'` | Stock moved out of the account to elsewhere |
| `'SPLIT'` | Stock split — `$amount` carries the split ratio (e.g. `2` for 2-for-1) |

If your broker emits an event that doesn't fit any of these, prefer
`'INTEREST'` for income-like cash, `'FEE'` for cost-like cash, and skip
the row (`rows: []`) if you can't classify it cleanly.

**Non-trade row patterns.** Cash events (DEPOSIT, WITHDRAWAL, INTEREST,
FEE, and DIVIDEND on a balance without a ticker) don't have a
meaningful symbol or unit price. The existing templates demonstrate
two valid patterns — pick the one that matches your broker, do not
invent a third:

- **Centralised in `input_schema`** (Anycoin, Revolut X, XTB cash) —
  `IF([type] = 'cash', '$CASH-XXX', TICKER([Symbol]))` style branching
  at variable definition time. `row_rules` then only sets `$action`.
  Compact when most cash events take the same shape and the input has a
  single column that distinguishes cash from stock rows.
- **Per-rule overrides** (Trading 212) — `input_schema` defines
  defaults that work for the trade rows, then individual
  `row_rules[].rows[]` entries clear or override `$variables` per
  event type (e.g. `$quantity: ""`, `$unitprice: ""` for a deposit;
  three different `rows` for a currency conversion). Verbose but
  flexible when different cash events need different shapes or when
  one input row must produce multiple output rows.

**Required vs optional output columns.**

| Required | Optional |
| --- | --- |
| `date`, `symbol`, `quantity`, `activityType`, `unitPrice`, `currency`, `fee`, `amount` | `account`, `fxRate`, `subtype`, `instrumentType`, `comment` |

**Date format.** `$date` should be `YYYY-MM-DD hh:mm:ss`. Brokers that
report date-only (no time) result in `... 00:00:00` — that's accepted.

### Locale-aware number parsing (European brokers)

European brokers (Comdirect, DKB, Flatex, BoursoBank, Fineco, …)
typically export numbers with `.` as thousands separator and `,` as
decimal: `5.000,00` means five thousand. Setting
`csv_decimal_separator_in: ","` opts the template into EU parsing,
and field access converts both shapes automatically:

| Raw field value      | Converted     | Reason                                  |
| -------------------- | ------------- | --------------------------------------- |
| `75,00`              | `75.00`       | Plain decimal, comma swapped            |
| `1234,56`            | `1234.56`     | Plain decimal, comma swapped            |
| `1.234,56`           | `1234.56`     | EU thousands group + decimal            |
| `-1.234.567,89`      | `-1234567.89` | Multiple thousands groups               |
| `1.234`              | `1234`        | EU thousands without decimal            |
| `1.5`                | `1.5`         | `.` not followed by 3 digits → left raw |
| `N/A`, `hello,world` | unchanged     | Non-numeric, left raw                   |

Expressions receive numeric fields ready to feed into arithmetic; no
defensive `IF(CONTAINS(...), REPLACE(...), ...)` wrapper needed.

US-style brokers (Schwab, Fidelity, Trading 212) use `.` decimal +
optional `,` thousands — that path is handled automatically (see
"American thousands-separated numbers" in the type-coercion notes).

### Rules for an AI assistant adding a new broker

If you are an AI assistant reading this section to generate a new
template, follow these rules strictly:

1. **`bxp-cli.examples.json` is required context.** It contains twelve
   working templates with rich inline comments. **If you don't have it
   in your context, ask the user to provide it before generating any
   template — do not guess at non-trade row patterns, action vocabulary,
   or broker quirks.** Pattern-match against the closest existing
   template (simple stock broker → Revolut X; paired rows → Anycoin;
   xlsx source → XTB; brycht.app tracker-mode → trading212_to_brychtapp).
2. **Add, do not modify.** Insert a new entry under
   `conversion_templates` in the user's `bxp-cli.json`. Never rewrite
   existing templates unless the user explicitly asks.
3. **Match the real CSV format.** Look at the sample header and first
   data row the user provided. Set `csv_delimiter_in`,
   `csv_decimal_separator_in`, and `csv_text_quote_in` to match what
   the broker actually exports — do not guess.
4. **Put activity-type logic in `row_rules`, not `input_schema`.**
   `$action` must be assigned inside a `row_rules[].rows[]` entry
   (e.g. `$action: "'BUY'"`). The `input_schema` only extracts and
   transforms neutral values.
5. **Use `pre_pass` only for cross-row joins.** If one input row needs
   a value from another row (paired transaction legs, fee refunds,
   order/fill pairs), use `pre_pass` and `LOOKUP`. Otherwise omit it
   entirely.
6. **Prefer named `ticker_map`s.** If the broker's symbols overlap an
   existing named map (e.g. `xtb`, `trading212`), reference it by name.
   Otherwise define a small inline map.
7. **One-to-many rows.** When one input row must produce multiple
   output rows (currency conversion = FEE + WITHDRAWAL + DEPOSIT;
   dividend with tax; split fees), return multiple objects in the same
   `row_rules[].rows` array. Each object can override `$variables` for
   that specific output row.
8. **Match the broker's exact date shape.** Use `DATE_CONVERT` with
   date-format tokens that correspond to the input literally,
   character-by-character; use `[*]` to skip fractional seconds,
   trailing `Z`, or timezone suffixes.
9. **Prices with embedded currency.** For fields like `"$100.00"` or
   `"24.00 CZK"`, use `PRICE_VALUE()` for the number and
   `PRICE_CURRENCY()` for the ISO code.
10. **Empty values.** Set a `$variable` to `""` to leave that output
    column blank. Drop a column from `output_schema` entirely to
    remove it.
11. **Enable debug during development.** Set `row_rules_debug_missing:
    true` and run with `--debug` (CLI) or `dry-run` (GUI) so any
    unmatched rows surface.
12. **Self-test before returning.** See the **Self-testing the
    generated template** section below — predict each sample row's
    outcome, then verify with the bxp-mcp tools (`bxp_validate` for the
    config, `bxp_eval` / `bxp_eval_trace` for per-expression values,
    `bxp_simulate` to run it end-to-end), or with `bxp-cli --debug` when
    no MCP server is wired. Only return the template once the run is
    clean and the generated `.csvx` matches every prediction.

13. **Return a commented JSON5, not bare JSON.** JSON5 supports `//`
    comments — use them to explain non-obvious decisions: why a
    particular date-format token was chosen, why a `pre_pass` was
    needed, why a row type is skipped, why a workaround like the
    European number-parsing branch is present. The user reads your
    output as documentation; future-you (or another AI) reads it to
    extend the template later.

14. **Hand off the unfinished business in plain language.** When you
    leave gaps the user must verify or finish in the GUI (the
    template generation isn't always complete on the first pass —
    Wealthfolio import quirks, exotic rows you couldn't classify,
    broker-specific edge cases), end your reply with a numbered
    "things to check in bxp-gui" list. See **Handing off to the
    user** below for what each instruction should contain.

### Handing off to the user (GUI-driven debug)

The user is non-technical and is following your natural-language
instructions. After you return the JSON, append a section like this
when there's anything left to verify:

```text
## Things to check in bxp-gui

1. **Open** your `bxp-cli.json` (Ctrl+O), select the new template
   `<id>` in the toolbar dropdown, click **dry-run**.

2. **DIVIDEND rows** (3 in your sample): the right-hand trace will
   show `quantity = 0`, `unitPrice = (empty)`. Wealthfolio may or
   may not accept this — try importing the resulting `.csvx` and tell
   me if Wealthfolio rejects DIVIDEND rows. If yes, I'll switch the
   template to set `$quantity = 1` and `$unitprice = $amount` for
   DIVIDEND rows specifically.

3. **Cash event description** (FEE, DEPOSIT rows): the `comment`
   column reads `' ()'` (empty broker columns). If you'd prefer
   blank, click any FEE row → expression panel → change `$comment`
   to `IF([Wertpapier] = '', '', [Wertpapier] & ' (' & [WKN] & ')')`.

4. **Splits / mergers / transfers** (skipped per readme): I added
   `rows: []` for direction `in` / `out`. If your account had any
   splits in the sample period, those rows produce no output — open
   `--debug` (the Settings inspector → Last debug section) and tell
   me which lines were skipped. I'll add explicit `'SPLIT'` handling
   if Wealthfolio supports it.
```

Each instruction must be:

- **Action-led** ("Open …", "Click …", "Tell me …") — the user
  doesn't infer what to do from a description.
- **Targeted** — name the specific GUI control (Ctrl+O, dropdown,
  expression panel, Settings inspector). The desktop readme's
  "Keyboard shortcuts" and "Advanced GUI features" sections list
  every concrete location.
- **Round-trip** — end with what the user should report back so you
  can finish the template. Avoid open-ended "let me know if anything
  looks wrong"; ask for specific cell values, exit codes, or `.csvx`
  rows.

If everything is verifiably correct (every sample row predicted
exactly, no Wealthfolio-import gotchas you're aware of), say so
explicitly: *"This template should be complete. Run a dry-run and
import the `.csvx` into Wealthfolio; nothing else needs your
attention."*

### Self-testing the generated template

After producing the JSON5 entry, validate it works as intended before
returning to the user. Treat the steps like unit tests — predict the
expected result before running, then compare against actual output.
This is the same loop you would write in pytest or bash to assert
behaviour didn't drift after a code change.

The self-test surface depends on what you have wired:

- **With the bxp-mcp server** (the agent-facing path): use its tools —
  `bxp_validate`, `bxp_validate_expr` / `bxp_eval` / `bxp_eval_trace` /
  `bxp_eval_batch`, and `bxp_simulate` (a full end-to-end run). Each
  takes config / expression *text* as arguments, so you never touch the
  filesystem.
- **With only `bxp-cli`** (no MCP): use `bxp-cli --debug` and a real run.

**1. Schema + JSON5 syntax check.** Call `bxp_validate` with the config
text:

- Expect no `$err_*` / `$warn_*` keys for the new template's path in the
  returned annotated JSON.
- If `$err_*` appears, fix the indicated error before going further.

**2. Predict, then verify.**

For each sample row the user provided, write down beforehand:

- which `row_rules` entry should match (and therefore `$action`)
- what each `$variable` should evaluate to (`$date`, `$ticker`,
  `$amount`, …)
- how many output rows the input row should produce (0 / 1 / N)

**Step A — per-expression check.** Before wiring an expression into the
template, evaluate it on its own against one sample row and confirm the
value matches your prediction — the fastest authoring loop, no full run
needed. Call `bxp_eval_trace` (or `bxp_eval`) with the expression plus
`headers` / `fields` for the row, e.g.

```json
{"expr":"DATE_CONVERT([Time], 'YYYY-MM-DD hh:mm:ss', 'YYYY-MM-DD')",
 "headers":["Action","Time","Ticker"],
 "fields":["Market buy","2024-04-25 07:00:35","RIO"]}
```

`bxp_eval_trace` returns NDJSON; the `{"t":"final","value":...}` line is
the computed result. Use `bxp_validate_expr` to additionally catch
authoring-time mistakes the lenient runtime swallows (e.g. a literal
`SPLIT_PART(…, 0)`), and `bxp_eval_batch` to evaluate several `$variable`
expressions against the same row in one call.

**Step B — run it end-to-end.** With MCP, call `bxp_simulate` with the
config, the template id, and the sample CSV. It stages and runs the real
`bxp-cli` pipeline and returns the produced output, a record-count diff,
`bxp-cli`'s diagnostics, and a per-row `trace` (which rows were written /
filtered / errored, with input line numbers) — the strongest check,
because it exercises `pre_pass` / `LOOKUP` / `row_rules` for real.

Without MCP, run the template and surface unmatched rows + runtime
expression errors directly:

```bash
./bxp-cli --config bxp-cli.json --template <new_id> --debug
```

Output: human-readable summary + `[expr error] $var = "expr": NotANumber (...)`
lines for any expression that failed at runtime + JSON dumps of
unmatched rows when `row_rules_debug_missing: true` is set. This is the
fastest way to spot typos and locale-format bugs.

**Step C — confirm the final output.** With `bxp_simulate`, read the
returned `outputs[].csv` — it is the exact result the user will import,
so compare each row against your prediction. Without MCP, run the
template without `--debug` and read the generated `.csvx` directly:

```bash
./bxp-cli --config bxp-cli.json --template <new_id>
cat <data_dir>/<sample>.csvx
```

(`bxp-cli --trace` is a separate, binary BXTB frame stream meant for the
GUI's drill-down view — not human-readable in a terminal and not needed
for self-testing.)

<!-- GUI-ONLY:START -->
In the GUI, the equivalent of Step C is a **dry-run** — its trace panes
show the same per-row outcome interactively, no terminal needed.
<!-- GUI-ONLY:END -->

Iterate until step B is silent (zero `[expr error]`, zero unmatched
rows) and the `.csvx` from step C matches every prediction.

**3. Inspect the `.csvx` output.**

```bash
head -n 6 ../data/<new_id>/*.csvx
```

- Header row matches `output_schema` keys, in order.
- Spot-check at least one row of each `$action` type the template emits.

**4. If a prediction fails, diagnose by category.**

| Symptom | Likely cause |
| --- | --- |
| `$date` empty or wrong | Date format token mismatch (`MM` vs `mm`, missing `[*]` for timezone, etc.) |
| `[ColumnName]` resolves to empty | Column name typo / case mismatch / extra whitespace in source header |
| `$amount` differs by sign | Missed `ABS()` — see Wealthfolio target spec |
| `--debug` lists unmatched rows | Missing or wrong `row_rules` `when` condition |
| `$ticker` empty for cash event | Non-trade row pattern not applied — see Wealthfolio target spec |

Re-run from step 1 after each fix. Only return the template to the
user once every prediction matches and `--debug` output is empty.

### Output format

Wealthfolio-compatible CSV. Columns are controlled by `output_schema`;
the default Wealthfolio set is:

| Column | Value | Notes |
| --- | --- | --- |
| `date` | `$date` | `YYYY-MM-DD hh:mm:ss` |
| `symbol` | `$ticker` | Yahoo Finance ticker |
| `quantity` | `$quantity` | Number of units |
| `activityType` | `$action` | `BUY`, `SELL`, `DEPOSIT`, `DIVIDEND`, … |
| `unitPrice` | `$unitprice` | Price per unit |
| `currency` | `$currency` | ISO currency code |
| `fee` | `$fee` | Blank if not reported |
| `amount` | `$amount` | Total value |
| `account` | `$account` | Optional |
| `fxRate` | `$fxRate` | Optional |
| `subtype` | `$subtype` | Optional |
| `instrumentType` | `$instrumentType` | Optional |
| `comment` | `$comment` | Optional |

Output is RFC 4180–compliant with basic protection against spreadsheet
formula injection.

### brycht.app target

The shipping brycht.app templates (`trading212_to_brychtapp`,
`xtb2_cash_to_brychtapp`, `xtb2_closed_to_brychtapp`) target a different
column set than Wealthfolio: `date, type, ticker, quantity, price,
currency, fees, notes` (8 columns) instead of Wealthfolio's 13. Templates
default to `combined_output: true` so the tracker imports a single merged
file per template. brycht.app does not publish a separate machine-readable
spec — treat the existing brycht.app entries in `bxp-cli.examples.json`
as the canonical reference: each one carries inline JSON5 comments
documenting what each `$variable` represents and how `$type` maps to the
broker's source action.

When authoring a new `*_to_brychtapp` template, pattern-match against
`trading212_to_brychtapp` (simple stock broker) or `xtb2_cash_to_brychtapp`
(xlsx-sourced, paired cash/closed shape) rather than against the
Wealthfolio templates above — the `output_schema` shape and `$action`
vocabulary differ.

---

<!-- GUI-ONLY:START -->
## Advanced GUI features

These features are GUI-specific and have no terminal equivalent. They
exist to make authoring and debugging a template faster than editing
JSON5 by hand.

### Inline schema docs

Hover any field in the tree to see its description, type, default, and
which expressions it accepts. The catalog is the bundled docs catalog
(the GUI loads it in-process from the bridge library at startup) — the
same source of truth that drives autocomplete in the expression editor.
Add a built-in function to bxp-cli, run a clean rebuild, and the GUI
sees it automatically with no client-side changes.

### Expression playground

Click any expression cell — a panel opens on the right with:

- A live editor with syntax highlighting and per-keystroke validation.
- Autocomplete (Ctrl+Space) for built-in functions, `$variables`, and
  `[ColumnName]` references that exist in the loaded template.
- Token-level error underlines: a typo'd `[Quanity]` (instead of
  `[Quantity]`) gets a red underline on exactly the wrong token, with
  a did-you-mean tooltip.
- A **Variables** sub-panel that evaluates the expression against the
  current row in-process (via the bundled bridge) and lists every nested
  function call's intermediate value. Excellent for debugging "why did
  this expression return empty string?" cases.

### Add Field dialog

When an object's parent schema permits new keys, a `+` chip appears.
Clicking it opens a dialog showing only the keys that are valid here
(driven by `FieldDoc` schema metadata), with default values and
inserted templates pre-filled. No need to remember which fields go
where.

### Settings inspector (`Ctrl+Shift+S`)

A drawer slides in from the right with the GUI's complete internal
state:

- Loaded config path, raw bytes, AST root.
- Schema docs catalog (loaded in-process from the bundled bridge at startup).
- Op log (undo / redo history).
- Path-keyed validation errors / warnings / info.
- Run state (last exit code, stderr text, trace event count).

Use it when something looks weird and you want to confirm "is the GUI
seeing what I think it's seeing?".

### Cancel and watchdog

The run can be cancelled mid-stream by clicking the `cancel` button
(the run-button label flips). A 10-second internal idle watchdog also
fires SIGTERM if the bxp-cli child stops emitting events; if SIGTERM
doesn't take effect within 2 seconds, SIGKILL escalates. You'll never
end up with a zombie subprocess blocking the UI.

### Filesystem checks (slow paths)

By default config validation skips filesystem checks (existence of
`data_dir`, of input files) so loading is snappy. Triggering `Ctrl+E`
(Validate) re-runs validation with a `check-fs` deadline of 2 seconds to
add these checks. If a check times out, the GUI flips into a degraded mode for
the rest of the session: subsequent reloads omit the flag too. This
stops a network-mounted `data_dir` from making the editor feel
sluggish.

---

## Working with an AI assistant in the GUI

GUI-specific scenarios where an AI helps you go faster than the
template-authoring prompt above.

### Letting an agent drive the GUI (gui-mcp)

BXP Desktop runs a small **MCP control server** so a local AI agent can
read and edit the live config in the running app — the same actions you
take by hand, but driven step by step while you watch and approve. This is
the half of the workflow where, after an agent has drafted a config, the
two of you fine-tune the tricky expressions together inside the GUI.

- **Endpoint** — `http://127.0.0.1:7717/mcp` (StreamableHTTP). The host
  and port are editable under **Settings inspector → Agent control**
  (`Ctrl+Shift+S`), where you can also see the live listening address and a
  log of what the agent did.
- **Connecting** — the agent should launch BXP Desktop, poll
  `GET /health` on the endpoint until it returns `200` (the body reports
  whether a config is already open), then run the MCP `initialize`
  handshake and call `open_config` with the path it wrote.
- **Safety** — the server binds loopback only. Critical actions (`save`,
  `full_run`, `delete_node`, `exit`) pop a confirmation dialog you must
  accept. If you change the bind host to a network address, an optional
  Origin allowlist is available in the same panel.

Tools the agent can call:

| Tool | What it does |
| --- | --- |
| `get_state` | Read the live config path, dirty flag, run status, diagnostics |
| `open_config` / `reload` | Load (or re-read) a config file from disk |
| `edit_node` | Change a scalar leaf (e.g. an expression) |
| `insert_node` / `rename_key` / `move_node` | Add, rename, or reorder config entries |
| `delete_node` | Remove a config entry (asks first) |
| `set_template` | Choose which template runs target (empty = all) |
| `dry_run` / `full_run` | Run the conversion (full run asks first) |
| `get_trace` | Summarise the most recent run's per-row trace |
| `get_row_detail` | Drill into one input row: fields, variables, rules, outputs |
| `save` | Write the edited config back to disk (asks first) |
| `exit` | Quit the app (asks first) |

You stay in control throughout: every agent edit is revealed in the tree
where it happens, and nothing is written or run without your click.

### Help with the GUI itself

If you're stuck navigating bxp-gui — finding a feature, understanding
an error message, choosing between dry-run and full-run — paste this
readme into your assistant and ask:

> *"I use BXP Desktop. Please read the bundled `readme.md`. I'm trying
> to `<describe what you want to accomplish>`. The GUI is showing
> `<paste any error chip text or describe the screen>`. Which features
> should I use, and what keyboard shortcuts apply?"*

The assistant has the full keyboard shortcut table, advanced feature
descriptions, exit-code semantics, and bundled binary reference —
enough context to walk you through almost any GUI workflow.

### Debugging an expression that returns wrong values

Open the expression in the playground (right-rail panel). Click
**Variables** and pick a row that produces the wrong result. Copy the
NDJSON trace lines (Settings inspector → trace section) and the
expression text into your assistant:

> *"This BXP expression `<paste expression>` should produce
> `<expected>` for input row `<paste row from variables panel>` but
> instead produces `<actual>`. The per-call trace looks like
> `<paste NDJSON lines>`. What's wrong with the expression?"*

The trace makes the AI's job almost mechanical — every nested function
call's input and output is visible.

---

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Fatal error gate on launch | The `bxp-gui-bridge` library is missing from the bundle. Reinstall the desktop package. |
| `dry-run` button greyed out | No template selected, or the config has a load-time AST parse error (red banner in the tree). |
| Error chips on every field | Schema docs failed to load. Check the Settings inspector → Docs section for a load error from the bundled docs catalog. |
| `cancel` button stuck | The bxp-cli child didn't respond to SIGTERM. Wait 2 seconds — the watchdog escalates to SIGKILL automatically. |
| Slow first load on a new file | First invocation may include filesystem checks (`Ctrl+E`-driven). Subsequent loads skip them; you can force-skip by avoiding `Ctrl+E`. |
| Tree shows `$comm_<N>` keys | A bug — those keys should be hidden by the renderer. Open an issue with the offending file attached. |

---
<!-- GUI-ONLY:END -->

## Contributing and newer templates

The project is open-source. For the newest built-in templates,
community contributions, and issue tracking see the BXP GitHub
repository: <https://github.com/zaxified/bxp>.

Apache-2.0 licensed. See `LICENSE.md` in the source tree.
