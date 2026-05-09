# Diagnostic baselines

Anonymized BXP-GUI diagnostic traces captured during past freeze
investigations. Each baseline is a paired NDJSON + native log + notes
describing the environment, what the trace shows, and what conclusions
followed.

The baselines exist for two reasons:

1. **Reference** when triaging a future "it freezes for me" report.
   Diff a fresh capture against the closest matching baseline (same
   GPU vendor, same Windows version) to see whether the failure mode
   matches a known one.
2. **Case studies** for upstream bug reports. The VMware-SVGA freeze
   case is, on its own, a complete reproduction of a Flutter Windows
   engine recovery bug.

## Activating the trace

Diagnostic capture is opt-in. Three activation paths, all equivalent:

- **Toggle in the app** (recommended for end users) — Ctrl+Shift+S
  opens the runtime inspector, the DEBUG section has a
  "Diagnostic mode" master switch. Flipping it writes the marker
  file, saves any pending edits, and auto-restarts the binary so
  the capture covers the engine boot path. No environment-variable
  knowledge required.
- `BXP_DIAGNOSTIC=1` environment variable (developer-friendly when
  running `flutter run -d windows`).
- Manually create the marker file `%APPDATA%\bxp-gui\.bxp-diagnostic`
  and launch normally.

Output lands in `%APPDATA%\bxp-gui\diagnostic-{,native-,engine-}YYYYMMDD-HHMMSS.{ndjson,log}`
— a Dart-side NDJSON, a Win32-message log, and a captured-stderr
engine log, fresh triple per launch, 5 MB cap on the NDJSON.
Implementation lives in
[`bxp-gui/lib/services/diagnostic_log.dart`](../../bxp-gui/lib/services/diagnostic_log.dart)
and [`bxp-gui/windows/runner/win32_window.cpp`](../../bxp-gui/windows/runner/win32_window.cpp).

## Reading the NDJSON

One JSON object per line. Common event kinds:

| `kind` | Fields | Meaning |
| --- | --- | --- |
| `startup` | `platform`, `os_version`, `dart_version`, `executable`, `cwd`, `locale` | One per launch. |
| `gpu` | `controllers[]` — WMI `Win32_VideoController` dump | `Name`, `DriverVersion`, `CurrentRefreshRate`. **First place to look** — `VMware SVGA 3D` here is the smoking gun for this bug class. |
| `gpu_error` | `exitCode`, `stderr` | WMI query failed; rare. |
| `frame` | `fps`, `build_ms`, `raster_ms`, `pe`, `pe_fwd`, `scroll`, `mid_btn` | 1 Hz. `fps=0` means the engine produced zero frames in that second. Sustained `fps=2` with `raster_ms<10ms` is the signature of an engine stuck in EGL Context Lost recovery (no actual painting). |
| `action.start` / `action.end` | `name`, `ms`, `exit`, `stdout_bytes`, ... | Wraps `loadConfig`, `runDryRun`, `runFullRun`, `validateExpr` subprocess calls. |
| `action.validateExpr` | `len` | High frequency — emitted per keystroke. |
| `error.flutter` | `exception`, `library`, `context`, `stack` | Caught by `FlutterError.onError`. |
| `error.zone` | `error`, `stack` | Caught by the top-level `runZonedGuarded`. |

## Reading the native log

Plain text, one Win32 message per line, prefixed with
`[HH:MM:SS.mmm]`. Hooks are limited to window-lifecycle messages
(`WM_NCCREATE`, `WM_SIZE`, `WM_WINDOWPOSCHANGED`, `WM_DPICHANGED`,
`WM_ACTIVATE`, `WM_SHOWWINDOW`, `WM_DISPLAYCHANGE`, `WM_DESTROY`).

This log is intentionally narrow — its job is to confirm whether the
freeze coincided with a real Windows event (resize, DPI change,
display reconfiguration) or whether the process simply stopped
producing frames while the window remained nominally healthy. The
VMware case is the latter.

## Reading the engine log

`diagnostic-engine-*.log` captures the Flutter engine's stderr stream
verbatim — `[ERROR:flutter/shell/...]` messages plus the underlying
ANGLE OpenGL-ES-on-D3D11 driver writes (`ERR: SwapChain11.cpp...`).
This is where the freeze cascade lives:

```text
ERR: SwapChain11.cpp:951: Present failed: D3D11 device was removed,
    HRESULT: 0x887A0007
[ERROR] EGL Error: Context Lost (12302) in surface.cc:61
[ERROR] EGL Error: Context Lost (12302) in context.cc:33
[ERROR] Could not make the context current to acquire the frame.
    ← repeats every frame, forever
```

The first `D3D11 device was removed` line is the trigger. Anything
**before** it in this log is the "what stressed the GPU" lead — read
that area carefully when bisecting a new freeze report. The
`Could not make the context current` lines repeat until the user
force-closes the process; their volume is meaningless beyond
confirming the engine got stuck in EGL recovery.

In a release binary launched without a console (double-click from
Explorer, NSIS shortcut, etc.) stderr would otherwise vanish — the
engine log file is the only place these messages survive. Activated
together with the NDJSON and native logs by the same `BXP_DIAGNOSTIC`
trigger.

## Adding a new baseline

1. Capture a trace by running `bxp-gui` with `BXP_DIAGNOSTIC=1`.
2. Copy the four files (`diagnostic-*.ndjson`,
   `diagnostic-native-*.log`, `diagnostic-probe.txt`, optionally
   `bxp-gui.json`) to a working directory.
3. Run `bash anonymize-trace.sh <captured-dir> <baseline-dir>` —
   the script auto-detects the Windows username and replaces every
   occurrence (case-insensitive) with `<user>`.
4. Drop a `notes.md` next to the files describing: environment
   (host OS, hypervisor, GPU), what the user did, what the trace
   shows, and the conclusion.

## What the anonymizer does and does not scrub

**Replaced:** the Windows username, anywhere it appears (paths in
`executable` / `cwd` / stack traces / native log header / recent-files
list).

**Preserved:** locale (`cs_CZ`), OS build, Dart version, GPU adapter
strings, driver versions, exception messages, stack traces. These are
load-bearing for diagnosis and not personally identifying.

If a trace happens to contain user-supplied broker template paths or
file names that you do not want to publish, scrub them by hand before
committing. The script only knows about the Windows username.
