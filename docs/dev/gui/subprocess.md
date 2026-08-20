---
description: "How the app reaches its backend: the bridge C-ABI surface, the in-process ops and the bxp-cli proxy."
---

# Subprocess Wiring

`BxpProcessClient` is the single entry point for all binary calls. Every call
goes through the in-process FFI bridge (`bxp-gui-bridge.{dll,so,dylib}`) on every
platform — there is no `dart:io` `Process.start` path. The bridge offers two call
shapes: in-process inspect / eval, and a native-code `bxp-cli` subprocess proxy
(both detailed below).

## Transport paths

The bridge is the **single backend on every platform** — there is no
`Process.start` path. Every entry point is a `bridge_*` call, and the whole
C-ABI surface is below: `in-proc` runs inside the GUI process against
`bxp-core`, `proxy` spawns `bxp-cli` and drains its pipes in native code, and
`lifecycle` covers handles, buffers and the version probe.

--8<-- "includes/bridge-ops.md:table"

The table is generated from `bxp-gui-bridge/src/ops.zig`, which a compile-time
check holds to the library's actual `pub export fn`s in both directions — so an
export cannot be added, renamed or removed without this page following.

The bridge is implemented as a Zig shared library that links the
`bxp-core/inspect` + `expr` modules directly (in-proc paths) and spawns the
`bxp-cli` subprocess (proxy paths). For the **two-cause rationale** behind the in-proc / proxy split see
[internals/index.md — "Why the bridge exists"](../internals/index.md#why-the-bridge-exists).
The C-ABI surface and Debug→ReleaseSafe rewrite landmine live in
[`bxp-gui-bridge/CLAUDE.md`](https://github.com/zaxified/bxp/blob/master/bxp-gui-bridge/CLAUDE.md). The proxy path's pipe
drain is hardened against several subprocess-reaping hazards — the Dart VM's own
child reaper closing fds mid-read, an inherited `SIGCHLD=SIG_IGN`, and `ECHILD`
on `wait` — by joining the stream readers before reaping; see that file for the
ordering.

**Mandatory on every platform.** Library probe failure at startup is fatal
(synthetic error surfaced through the normal startup gate, which also parses
the docs catalog). There is no subprocess fallback — Windows can't use
`Process.start` (dart-lang/sdk#1727) and the Linux/macOS `Process.start` route
was removed when the bridge became the single backend.

**Reloading bridge changes.** `dlopen` mmaps the file at process start, so
editing a `.so`/`.dylib` and `mcp__dart__hot_reload` does NOT pick it up. After
`zig build` in `bxp-gui-bridge/`, fully stop and relaunch the Flutter app.

---

## Binary resolution

Resolved in this order:

1. **Env override** — `$BXP_CLI_PATH`. If set and non-empty,
   used absolutely (missing file → fatal error, no fallthrough).
   (`$BXP_EXAMPLES_PATH` is the analogous override for locating the bundled
   `bxp-cli.examples.json` template catalog.)
2. **Bundle sibling** — `<name>` next to the Flutter executable inside the app
   bundle.
3. **Dev-tree fallback** — walks up from the exe dir until it finds a `bxp-gui/`
   segment, then looks for `<monorepo-root>/<name>/zig-out/bin/<name>`. This
   makes `flutter run -d linux` work without copying binaries after a bundle wipe.

---

## Client methods

| Method                  | Backend call                       | Notes                                                   |
| ----------------------- | ---------------------------------- | ------------------------------------------------------- |
| `validateConfig(path)`  | `bridge_inspect {config}`          | Returns annotated JSON with `$err_*`/`$warn_*` siblings |
| `getDocs()`             | `bridge_inspect {docs}`            | Cached at startup; drives FnDoc tooltips + SchemaGate   |
| `listTemplates(path)`   | `bridge_inspect {list_templates}`  | `{templates:[…]}` → `List<TemplateInfo>` (id + io shape) |
| `validateExpr(text)`    | `bridge_eval_expr`                 | Returns `{error, offset, length}` on failure            |
| `traceExpr(text, …)`    | `bridge_eval_expr_trace`           | NDJSON stream of per-call values                        |
| `runWithBtrace(...)`    | `bridge_run_streaming` → `bxp-cli --trace=bin` | BXTB frame stream → in-store reader           |
| `getVersion(name)`      | `bridge_run` → `bxp-cli --version` | Writes to stdout                                        |

---

## Linux dev-tree gotcha

The Linux CMake config copies the `bxp-gui-bridge` library (and `bxp-cli`) into
the bundle at build time. After rebuilding the bridge, either run a clean Flutter
build or rely on the dev-tree fallback (option 3 above) which reads directly from
`bxp-gui-bridge/zig-out/`.
