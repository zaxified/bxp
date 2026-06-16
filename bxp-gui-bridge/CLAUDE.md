# CLAUDE.md — bxp-gui-bridge

Guidance for Claude Code when working with the bxp-gui-bridge package.
For monorepo-level context see [`../CLAUDE.md`](../CLAUDE.md).

## Purpose

**bxp-gui-bridge** — Zig shared library loaded at runtime by `bxp-gui`
via `dart:ffi` (`DynamicLibrary.open`). Since the v0.3.0 proxy flip
(2026-06-09) it is the GUI's **single backend on every platform** — there
is no `bxp-fmt` spawn and no `Process.start` path. Three responsibilities,
all cross-platform:

1. **Subprocess proxy (all platforms)** — `bridge_run` / `bridge_run_streaming`
   wrap the `bxp-cli` spawns the GUI needs (dry-run / full-run `--trace=bin`,
   `--version`). Dart's `Process.start` on Windows hits a deterministic ~8 KB
   cutoff when reading subprocess stdout (dart-lang/sdk#1727 + #51273), which
   kills `bxp-cli --trace` (megabytes); the bridge reads pipes from native
   code, sidestepping the dart:io C++ pipe path entirely. Windows was the
   original mandatory case; the flip generalised it so Linux/macOS no longer
   keep a separate `Process.start` route.
2. **In-proc expression evaluator (all platforms)** — `bridge_eval_expr` /
   `bridge_eval_expr_trace` call the shared `bxp-core/inspect` core
   (`validateExpr` / `evalTrace` — the same logic behind the MCP
   `bxp_validate_expr` / `bxp_eval_trace` tools) directly in the GUI process,
   so the expression playground and editor don't pay a ~50 ms spawn cost per
   keystroke. The bridge only marshals to/from its fixed C-ABI out buffer; the
   eval/trace logic is no longer hand-rolled here.
3. **In-proc inspect ops (all platforms)** — `bridge_inspect` covers the rest
   of the stateless inspect surface (`docs` / `config` / `list_templates` /
   `fetch_template` / `eval_batch`), so the GUI runs an in-process
   `bxp-core/inspect` call with no subprocess. The bridge links
   `bxp-core/inspect` directly, so the GUI needs no separate validator binary.
   There is no subprocess fallback: a missing library is a fatal startup on
   every platform.

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
| `bridge_eval_expr_trace(..)` | In-proc: same with per-call NDJSON trace + terminal sentinel   |
| `bridge_inspect(...)`        | In-proc: stateless inspect ops (`docs` / `config` / `list_templates` / `fetch_template` / `eval_batch`) — JSON request envelope → result JSON in out buffer |
| `bridge_verify_minisign(...)`| In-proc: verify a minisign signature (`.minisig`) over a file (release `SHA256SUMS`) against a base64 public key — Ed25519 + Blake2b-512, zero-alloc; returns `0` authentic / non-zero refuse |

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
   copied into the Flutter bundle next to `bxp-cli.exe`.
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

- **All platforms** — single transport path since the v0.3.0 proxy flip
  (2026-06-09). Library probe failure at GUI startup is **fatal**; there is
  no `Process.start` and no `bxp-fmt` fallback anywhere. `findBridgeLibrary()`
  in `bxp-gui/lib/services/bridge_client.dart` walks sibling → bundle →
  dev-tree slots (`zig-out/lib/*.{so,dylib}` on POSIX, `zig-out/bin/*.dll` on
  Windows); the synthetic startup error surfaces through the normal startup
  gate. Both the subprocess proxy (`bridge_run` / `bridge_run_streaming` for
  `bxp-cli`) and the in-proc families (`bridge_eval_expr*` / `bridge_inspect`)
  are live on every host.
- **Windows bridge path verified (pre-release sweep).** The in-proc
  `bridge_inspect` family is load-bearing on Windows (no `bxp-fmt` fallback) and
  was exercised on real Windows hardware in the pre-release win-smoke + bridge
  test pass — alongside the always-live Linux verification and the proxy + eval
  families that are already mandatory on every host. Caveat:
  `bxp-gui/tool/win_bridge_smoke.dart` is **obsolete** — its large-payload
  scenarios proxied the now-deleted `bxp-fmt` through `bridge_run`; repoint them
  at `bxp-cli` before reusing that harness. `bxp-fmt` itself is gone; the console
  archive ships `bxp-mcp` as the agent-facing surface and `scripts/test.sh`
  drives `inspect` via bxp-mcp / the bridge.

## Coding conventions

- All code comments and documentation in English.
- Zig 0.15.2 API — use the `zig` skill before writing new code.
- Tests use the `test_helper.zig` re-exec pattern — never call out to
  real OS binaries; the suite must be identical on every host
  ([[feedback_test_helper_subprocess]]).

## Known non-issues (audit-acknowledged)

Residual 🔵 notes from the 2026-06-14 audit (the 🟡 `bridge_run` one-shot
ECHILD-intolerance is dead code — the only caller reroutes through
`bridge_run_streaming`). No 🔴/🟠.

- **`streamingStderrLoop` has no backpressure bound.** It dispatches every
  stderr chunk without the `queue_sema.wait()` gate that bounds stdout —
  intentional (bxp-cli stderr is low-volume warnings). A pathological stderr
  flood could accumulate unbounded in-flight heap buffers in Dart's port
  queue. Acceptable by design; on record so the assumption is explicit.
- **`bridge_verify_minisign` accepts legacy `"Ed"` alongside prehashed
  `"ED"`.** Not a downgrade vulnerability — both are full Ed25519 over the
  content, forging either needs the private key; CI emits prehashed `"ED"`
  only. Could tighten to prehashed-only to shrink the accepted surface, but no
  security impact today.
- **`trusted_comment` is capped at 2048 B** (`gbuf: [64 + 2048]u8`,
  length-checked before the memcpy → `bad_sig_file` if longer, no overflow). A
  legitimately long trusted comment would false-reject; the release pipeline
  controls the comment (short `timestamp:… file:… hashed`), so no practical
  impact.
