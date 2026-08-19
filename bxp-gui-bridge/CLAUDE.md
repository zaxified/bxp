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
    main.zig         ← all C-ABI exports + the Dart-facing marshalling around
                       them (~2.0 kLOC; includes inline test suites). The
                       process machinery underneath — capped drain, streaming
                       reader threads, backpressure, reap — is `procrun`; what
                       stays here is the FFI contract: the handle registry,
                       the chunk copy Dart takes ownership of, and the
                       teardown ordering that keeps a buffer from orphaning in
                       Dart's port queue.
  test/
    test_helper.zig  ← stand-alone "re-exec target" binary (~140 LOC)
                       compiled by `zig build test` and pointed to via
                       `test_options.test_helper_path`. Behaviour is
                       fully controlled by argv switches so the test
                       suite is identical across Linux / macOS / Windows
                       (no reliance on `/bin/echo`, `/bin/sleep`, …).
  build.zig          ← links libc; passes the optimize mode through verbatim
                       (the old Debug → ReleaseSafe rewrite was dropped on Zig
                       0.16 — see below). Imports three modules from bxp-core:
                       `inspect` (its own) plus `minisign` and `procrun`
                       (re-exported from zig-libs, so the bridge shares
                       bxp-core's single pin).
  build.zig.zon      ← depends on bxp-core (path dep ../bxp-core). No fetch
                       deps of its own — zig-libs comes through bxp-core.
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
| `bridge_verify_minisign(...)`| In-proc: verify a minisign signature (`.minisig`) over a file (release `SHA256SUMS`) against a base64 public key — Ed25519 + Blake2b-512 via the zig-libs `minisign` module, no heap alloc; returns `0` authentic / non-zero refuse |

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

## Former Debug → ReleaseSafe rewrite (removed on Zig 0.16)

`build.zig` used to force `.Debug` → `.ReleaseSafe` because Zig 0.15.2's
Debug-mode x86-64 codegen produced broken register allocation for
`mem.Allocator.remap` / `json.Scanner.next` — a NULL deref at offset `0x30`
under realistic streaming load (137 K rows from `bxp-cli --trace`). That was a
backend defect; Zig 0.16's self-hosted x86 backend does not reproduce it, so
the rewrite is gone and Debug builds as Debug again. If a 0x30-class SEGV ever
resurfaces under streaming load, suspect a backend regression first — don't
silently reinstate the rewrite without reproducing under load (a debugger run
that breaks early will appear to "work").

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
  families that are already mandatory on every host. The live Windows transport
  probe is `bxp-gui/tool/win_bridge_stream_probe.dart` (large `bxp-cli` BXTB
  stream byte-identical + cancel mid-stream); in-proc `bridge_inspect` /
  expr-corpus are covered cross-platform by `flutter test`
  (`bridge_inspect_test.dart` / `expr_corpus_bridge_test.dart`). `bxp-fmt` is
  gone; the console archive ships `bxp-mcp` as the agent-facing surface and
  `scripts/test.sh` drives `inspect` via bxp-mcp / the bridge.

## Coding conventions

- All code comments and documentation in English.
- Zig 0.16.0 API — use the `zig` skill before writing new code.
- Tests use the `test_helper.zig` re-exec pattern — never call out to
  real OS binaries; the suite must be identical on every host
  ([[feedback_test_helper_subprocess]]).

## Known non-issues (audit-acknowledged)

Residual 🔵 notes from the 2026-06-14 audit. No 🔴/🟠. (The 🟡 `bridge_run`
one-shot ECHILD-intolerance was noted as moot because the only caller reroutes
through `bridge_run_streaming`; it is moot for a second reason now — both paths
reap through the same `waitTolerant`, which since the `procrun` migration is
the upstream reap core.)

- **Stderr has no backpressure bound.** `procrun` gates stdout on the
  permit semaphore (`stream_permits`, 32) and delivers stderr unthrottled —
  intentional, and the same shape this file used to implement by hand
  (bxp-cli stderr is low-volume warnings). A pathological stderr flood could
  accumulate unbounded in-flight heap buffers in Dart's port queue. Acceptable
  by design; on record so the assumption is explicit.
- ~~**`bridge_cancel` does not reach a child's own grandchildren.**~~
  **Fixed 2026-08-19.** It used to signal the direct child only, so a
  grandchild that inherited the stdout pipe kept it open and `on_exit` did not
  fire until that grandchild exited — cancelling `sh -c 'sleep 20'` took the
  full 20 s, while `sh -c 'exec sleep 20'` cancelled in 0.3 s (measured
  2026-08-16, identical before and after the `procrun` migration). The child
  now leads its own process group (`Spec.new_process_group`) and `bridge_cancel`
  signals `-pgid` through `Handle.cancelGroup`, reaching the whole tree; the
  post-spawn rollback uses `killGroup` for the same reason. Because the group
  id equals the child's own pid, this can never signal the GUI's own group.
  POSIX-only — Windows has no process-group concept here and falls back to
  signalling the child exactly as before. It was deliberately left off with the
  migration (it changes what a cancel kills) and turned on as its own decision.
  Nothing the bridge spawns today forks — `bxp-cli`'s parallelism is threads —
  so what this changes is the behaviour of whatever it spawns next. Pinned by
  `test "bridge_cancel reaches a grandchild holding the pipe"`, which drives
  the `fork-sleep` helper subcommand; without the group flag three tests fail.
- **`bridge_verify_minisign` accepts legacy `"Ed"` alongside prehashed
  `"ED"`.** Not a downgrade vulnerability — both are full Ed25519 over the
  content, forging either needs the private key; CI emits prehashed `"ED"`
  only. Now inherited from the `minisign` module (which implements the whole
  format), so tightening to prehashed-only would be a check in this wrapper
  after `parseSignatureFile`, not an upstream change. No security impact today.
- **`trusted_comment` is capped at 2048 B** — the scratch
  `FixedBufferAllocator` (`minisign_scratch_len = 64 + 2048`) the
  trusted-comment layer allocates its concatenation from; a longer comment
  fails the allocation and is refused as `bad_sig_file`, exactly as the former
  hand-rolled length check did. Upstream itself caps neither comment (it
  documents capping as the caller's job). A legitimately long trusted comment
  would false-reject; the release pipeline controls the comment (short
  `timestamp:… file:… hashed`), so no practical impact.
