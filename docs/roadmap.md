# Roadmap

> [← docs/](README.md)

Forward-looking milestones. Hand-maintained — `CHANGELOG.md` is the
shipped history; this file is what's planned. Items move out of here
into a `CHANGELOG.md` entry when their PRs land + a release is cut.
`scripts/release-changelog.sh` generates the `CHANGELOG.md` entry
automatically from `git log` when cutting a release.

## v0.3.0

### Flip bridge proxy to default on Linux/macOS

Foundation shipped in v0.2.3: `bxp-gui-bridge.{so,dylib}` builds and
ships alongside `bxp-gui` on all three hosts; `bridge_eval_expr` /
`bridge_eval_expr_trace` already run in-process on every platform; the
subprocess proxy path (`bridge_run` / `bridge_run_streaming` for
spawning `bxp-cli` / `bxp-fmt`) compiles and works cross-platform
behind a `BXP_FORCE_BRIDGE_PROXY=1` smoke gate. Windows has used the
bridge proxy as its mandatory and only path since v0.2.2 to sidestep
dart-lang/sdk#1727 (Win pipe truncation) and engine-stderr capture
under `/SUBSYSTEM:WINDOWS`.

Plan for v0.3.0:

- Make the bridge proxy the default on Linux/macOS, removing the
  `Platform.isWindows` branches in
  [`bxp_process_client.dart`](../bxp-gui/lib/services/bxp_process_client.dart)
  and the `BXP_FORCE_BRIDGE_PROXY` opt-in.
- Drop the `Process.start` code path entirely once the bridge proxy
  has shipped in at least one production release on Linux/macOS with
  no regressions.
- Audit the per-host Flutter shells (`linux/`, `macos/`) for any
  remaining `Process.start`-specific assumptions before the flip.

## Later (no specific version)

### CI hardening

- `.github/workflows/ci.yml` — run `scripts/test.sh` on every PR. Today
  only the release workflow exists; PRs go untested by CI.
- Flutter `integration_test` smoke run inside CI (Xvfb on Linux runners,
  headless setup on Mac / Win).

### Windows runner image redirect (monitor 2026-05-13)

GitHub Actions is redirecting `windows-2025` → `windows-2025-vs2026`
on 2026-05-12, swapping Visual Studio 2025 for Visual Studio 2026 on
the `windows-latest` runner. The redirect is image-level so pinning
to `windows-2025` does not avoid it. After 2026-05-13 a
`workflow_dispatch` test of `release.yml` (e.g.
`gh workflow run release.yml -f version=v0.2.2-rc-test`) should be
run to confirm the Win build (Flutter MSVC, NSIS install) still
works on the new image. If something breaks, options are
(a) pin `runs-on: windows-2022` for the desktop-windows job,
(b) fix whatever the VS 2026 swap broke. Drop this entry once a
post-redirect release succeeds.

### Distribution polish

- Apple Developer ID notarisation for macOS `.app` (~$99/year).
  Eliminates the first-launch Gatekeeper warning.
- Windows Authenticode signing for the NSIS installer (~$200/year cert).
  Eliminates the SmartScreen warning.
- Linux `.rpm` package for Fedora / RHEL users — adds `rpmbuild` + spec
  file alongside the existing `.deb` and AppImage.
- Flatpak publishing on Flathub. Review process takes weeks; defer
  until app is more stable.
- AppImageUpdate (zsync delta downloads). Current Linux updater
  re-downloads the full AppImage; zsync would do binary deltas.

### bxp-cli

- `xlsx_sheet.name` validation under the `--check-fs` umbrella. Verify
  the named sheet exists inside the `.xlsx` file during the filesystem
  check phase.

### Real-world broker CSV quirks

Surfaced by readme-adequacy simulations against real broker formats
(Schwab brokerage, Lime.co via leppa/convert-to-wealthfolio). Each
quirk is a real broker-export pattern that the current bxp-cli template
language can't express cleanly; the workaround today is "tell the user
to pre-process the file" or "skip the affected rows".

- **CSV preamble / title line skipping.** Schwab's transactions CSV
  starts with `"Transactions for account XXXX-1234 as of …"` on line 1
  and the actual headers on line 2. bxp-cli has `xlsx_sheet.header_row`
  for xlsx but no equivalent for plain CSV. Add
  `csv_header_row: N` (default `1`) — skip the first `N-1` lines before
  treating line `N` as the header. Touches `csv.zig` (splitRecords
  offset) + `config.zig` (FieldDoc + load) + integration test.

- **Multi-CSV-in-one-file (blank-line separated).** Some brokers
  concatenate multiple sub-CSVs into a single `.csv`, separated by one
  or more empty lines, with each block having its own header row.
  Today bxp-cli would treat the second header as a data row and fail.
  Options: (a) add `csv_split_on_blank_line: true` flag — parser
  splits the file at empty-line boundaries and processes each block
  separately, or (b) treat blank line as end-of-stream and process
  only the first block (cheaper, less complete). Touches
  `csv.zig` + `config.zig` + `pipeline.zig`. Decide on (a) vs (b)
  based on the user's actual file.

- **Wealthfolio target spec vocabulary expansion (remaining).** The
  readme now documents `TRANSFER_IN`, `TRANSFER_OUT`, and `SPLIT`
  alongside the eight standard actions. Real Wealthfolio also accepts
  `CONVERSION_IN`, `CONVERSION_OUT`, and `ADJUSTMENT` — confirm against
  the import contract and add to the readme if the existing
  `WITHDRAWAL`/`DEPOSIT` mapping for currency conversion is too lossy.
  Pure docs change.

- **Description-based ticker extraction.** Lime.co's dividend rows have
  empty `Symbol` and the ticker is embedded in `Description`
  (`"Qualified Dividend APPLE INC 100"`). Today there's no clean way
  to extract the ticker. Two design options: (a) document
  `ticker_map` keyed by company name (`"APPLE INC": "AAPL"`) — works
  with the existing engine, just needs a readme tip; (b) add a
  `REGEX_EXTRACT(s, pattern)` built-in. (a) is cheap; (b) is a real
  feature.

- **Readme polish** — add an `OR` example to "Minimal examples"
  (`[Action] = 'Buy' OR CONTAINS([Action], 'Buy to')   → catch all buy
variants`). Tiny.

- **`csv_decimal_separator_in: ","` consistency.** Surfaced by
  Comdirect-style German locale simulation (2026-05-07). The current
  implementation pre-converts UNAMBIGUOUS comma-decimals at field-access
  time (`75,00` → `75.00` string) but leaves multi-`.`-multi-`,` values
  raw because it can't disambiguate. Expressions then receive a mix of
  pre-converted and raw strings, which forces template authors to write
  a defensive `IF(CONTAINS([X], ','), strip+swap, [X])` wrapper around
  every numeric expression. Fix options: (a) convert ALL comma-decimal
  fields consistently using a paired `csv_thousands_separator_in: "."`
  flag; (b) always normalise at field-access time using a smarter
  heuristic (last non-numeric char wins as decimal); (c) leave behaviour
  alone but add a built-in `PARSE_EU_NUMBER([X])` function that does the
  strip+swap+ABS in one call. Decide by feasibility: (c) is cheapest.

- **Mutually-exclusive `--trace` and `--debug` is awkward for self-test.**
  AI agents authoring a template need both: `--debug` for runtime expr
  errors and unmatched-row JSON; `--trace` for per-row event detail.
  Today they must run two passes. Could `--trace --debug` be allowed,
  with the debug JSON written to stderr (alongside warnings) so the
  NDJSON stream on stdout stays clean? Touches `bxp-cli/main.zig` arg
  validation + `Output` struct. Small change, big workflow win.

### Tooling

- Zig 0.16 migration. Currently pinned to 0.15.2; 0.16 shipped
  2026-04-15 with breaking I/O API changes (~100–150 LOC affected).
  Assessment in `project_zig16_migration` memory.

## Done

Historical milestones live in `CHANGELOG.md`. This section stays empty
on purpose — once a roadmap item ships, it moves to the changelog entry
for that release (generated by `scripts/release-changelog.sh`) and the
line here is deleted.
