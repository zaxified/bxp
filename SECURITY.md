# Security policy

## Supported versions

bxp is pre-1.0 and ships from a single moving release line. Only the
**latest published release** (see the [releases page](https://github.com/zaxified/bxp/releases))
receives security fixes. There are no backports to earlier `v0.x` versions —
upgrade to the latest tag.

## Reporting a vulnerability

Please **do not open a public issue** for suspected security problems.

Use GitHub's private vulnerability reporting:

1. Go to <https://github.com/zaxified/bxp/security/advisories/new>
2. Describe the issue, including a minimal reproduction (config + sample
   input file, or a code snippet) and the affected version.

A reply usually arrives within 7 days. This is a personal-scale project,
so I cannot promise enterprise-grade response times, but realistic
turnaround for a confirmed issue is days to a couple of weeks depending
on severity and complexity.

After a fix is shipped, the corresponding GitHub Security Advisory is
published with credit (unless you ask to remain anonymous).

## In scope

The realistic attack surfaces in bxp are:

- **CSV / JSON5 / XLSX parsing** in `bxp-cli`, `bxp-fmt` and `bxp-core`
  when fed crafted input files (parser crashes, allocator exhaustion,
  path traversal in xlsx ZIP entries, etc.).
- **Expression evaluator** (`bxp-core/src/expr.zig`) — unchecked
  arithmetic, OOB reads driven by attacker-controlled config or input
  field values, panics in `@intFromFloat` / `@intCast`, etc.
- **In-app updater** (`bxp-gui/lib/services/updater_service.dart`) —
  the SHA256 verification path, archive extraction, and the .desktop /
  shortcut writer (path injection, symlink races).
- **FFI bridge** (`bxp-gui-bridge`) — memory safety across the
  Dart ↔ Zig C-ABI boundary.

If your finding lives in one of those areas and lets an attacker
crash, hang, escape an expected sandbox, or trick the updater into
installing an unverified binary, it counts.

## Out of scope

- Vulnerabilities that require a malicious local user with write
  access to the user's home directory or `bxp-gui.json` prefs file.
- Denial-of-service from intentionally huge input files when the user
  themselves chose to point bxp at them.
- Issues in upstream dependencies (Zig stdlib, Flutter, Dart) — please
  report those to the respective
  upstream. If bxp's usage actively turns a benign upstream bug into a
  security issue, that's in scope here.
- Findings from automated scanners without a working reproduction.
- Social-engineering scenarios that don't involve a bug in bxp itself.
