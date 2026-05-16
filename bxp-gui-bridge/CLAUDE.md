# CLAUDE.md — bxp-gui-bridge

Guidance for Claude Code when working with the bxp-gui-bridge package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-gui-bridge** — Zig shared library loaded at runtime by `bxp-gui`
via `dart:ffi` (`DynamicLibrary.open`). Two responsibilities:

1. **Subprocess proxy (Windows only)** — wraps every `bxp-cli` / `bxp-fmt`
   spawn the GUI needs. Dart's `Process.start` on Windows hits a
   deterministic ~8 KB cutoff when reading subprocess stdout
   (dart-lang/sdk#1727 + #51273), which kills `bxp-fmt --docs` (~30 KB)
   and `bxp-cli --trace` (megabytes). The bridge reads pipes from native
   code, sidestepping the dart:io C++ pipe path entirely. On Linux/macOS
   this role is dormant — `BxpProcessClient` calls `Process.start` directly.
2. **In-proc expression evaluator (all platforms)** — `bridge_eval_expr` /
   `bridge_eval_expr_trace` link `bxp-core/expr` directly into the GUI
   process so the expression playground and editor don't pay the ~50 ms
   `bxp-fmt --expr` spawn cost per keystroke. This path is cross-platform
   (Linux/macOS `.so`/`.dylib` ship and are loaded for eval even though
   the subprocess proxy is unused).

## Source layout

```text
bxp-gui-bridge/
  src/
    main.zig         ← all C-ABI exports + spawn helpers + streaming ctx
                       (~1.9 kLOC; includes inline test suites)
  test/
    test_helper.zig  ← stand-alone "re-exec target" binary (~140 LOC)
                       compiled by `zig build test` and pointed to via
                       `test_options.test_helper_path`. Behaviour is
                       fully controlled by argv switches so the test
                       suite is identical across Linux / macOS / Windows
                       (no reliance on `/bin/echo`, `/bin/sleep`, …).
  build.zig          ← Debug → ReleaseSafe rewrite (see below).
  build.zig.zon      ← depends on bxp-core (path dep ../bxp-core).
```

## Public C-ABI

All exports use the `.c` calling convention.

| Symbol                       | Purpose                                                       |
| ---------------------------- | ------------------------------------------------------------- |
| `bridge_version()`           | NUL-terminated semver string (matches `build.zig.zon`)        |
| `bridge_run(...)`            | One-shot: spawn, drain stdout/stderr to caller buffer, return |
| `bridge_run_streaming(...)`  | Streaming: per-batch stdout/stderr callbacks + exit callback  |
| `bridge_cancel(handle)`      | Cooperative cancel for a streaming handle                     |
| `bridge_ack(handle)`         | Backpressure ACK (releases one queue permit)                  |
| `bridge_free(ptr, len)`      | Return a `bridge_run` response buffer to the bridge allocator |
| `bridge_eval_expr(...)`      | In-proc: parse + evaluate one expression, return result/error |
| `bridge_eval_expr_trace(..)` | In-proc: same with NDJSON trace emission via callback         |

The Dart-side shim that calls these lives in
[`../bxp-gui/lib/services/bridge_client.dart`](../bxp-gui/lib/services/bridge_client.dart).
Any ABI break (signature change, new error code) requires bumping both
sides in the same commit — the bridge has no auto-versioned compatibility
shim, so a stale DLL against a new GUI silently misbehaves.

## Build

```bash
cd bxp-gui-bridge
zig build                           # → zig-out/lib/libbxp-gui-bridge.{so,dylib} or .dll
zig build test                      # FFI surface + streaming + cancel
zig build -Doptimize=ReleaseSmall   # production release flag
```

The library is consumed by bxp-gui in three places:

1. **Windows release** (`scripts/release-02-desktop.sh` Windows leg) —
   copied into the Flutter bundle next to `bxp-cli.exe` / `bxp-fmt.exe`.
2. **Linux/macOS release** — same bundle slot for the eval path.
3. **Dev tree** (`flutter run -d linux`) — the Flutter CMake hook copies
   whatever sits in `bxp-gui-bridge/zig-out/lib/`; **changing a `.so`
   does not survive `mcp__dart__hot_reload`** (`dlopen` mmaps the file
   at process start). Run `zig build` then `stop_app` + `launch_app`
   to pick up bridge changes.

## Why Debug → ReleaseSafe

Zig 0.15.2 Debug-mode codegen produces broken register allocation for
`mem.Allocator.remap` and `json.Scanner.next` on x86-64. Both surface
as a NULL deref at offset `0x30` when the bridge's reader thread and
`bridge_eval_expr_trace` run under realistic streaming load (137 K rows
from `bxp-cli --trace` against `DEV/bxp-cli.json`).

`build.zig` rewrites `.Debug` → `.ReleaseSafe` and leaves the explicit
`ReleaseSafe` / `ReleaseSmall` / `ReleaseFast` selections untouched.
ReleaseSafe keeps every runtime safety check (overflow, bounds,
null-deref asserts) — only the codegen path differs.

**Do not** revert to Debug to chase a debugger session: the bug
reproduces only under streaming load, which means a debugger run that
hits a breakpoint early will appear to "work" and you'll re-introduce
the SEGV silently. Bump to Zig 0.16.x first
([[feedback_zig_0_15_2_debug_codegen_bug]] / [[project_zig16_migration]]),
verify the corpus, then drop the rewrite.

## Platform notes

- **Windows** — single transport path. DLL probe failure at GUI startup
  is **fatal**; there is no `Process.start` fallback. `findBridgeLibrary()`
  in `bxp-gui/lib/services/bridge_client.dart` walks sibling → bundle →
  dev-tree slots; the synthetic startup error surfaces through the
  normal startup gate.
- **Linux/macOS** — subprocess proxy unused; only `bridge_eval_expr*` is
  called. The Dart side falls back gracefully to `bxp-fmt --expr` if the
  bridge can't be loaded at all (acceptable on these hosts because there
  is no pipe-truncation bug to mask).
- **Cross-platform consolidation** (subprocess proxy on Linux/macOS too)
  is on the v0.3.0 roadmap; the in-proc eval path is already cross-platform.

## Coding conventions

- All code comments and documentation in English.
- Zig 0.15.2 API — use the `zig` skill before writing new code.
- Tests use the `test_helper.zig` re-exec pattern — never call out to
  real OS binaries; the suite must be identical on every host
  ([[feedback_test_helper_subprocess]]).
