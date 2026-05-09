# 2026-05-08 — VMware SVGA freeze (positive case)

**Conclusion:** Flutter Windows engine's EGL Context Lost recovery is
broken under the VMware SVGA D3D11 driver. When the driver crashes
with `DXGI_ERROR_DEVICE_REMOVED (0x887A0007)`, the engine enters a
"Could not make the context current to acquire the frame" loop and
never recovers. Window stays alive, framework stays alive (cursor
changes, hit-test works), but no pixels reach the screen.

## Environment

- Windows 10 Pro 19045 in VMware Workstation 17 guest
- Dart 3.11.5, locale `cs_CZ`
- Two display adapters reported by WMI:
  - `Microsoft Remote Display Adapter` 10.0.19041.5794 (RDP / generic, refresh 32 Hz, 1920×1080)
  - **`VMware SVGA 3D` driver `9.17.11.1`** (Broadcom Inc., 256 MB, refresh 60 Hz, 1920×1080)

## What the trace shows

22 frames over ~20s of pure idle (no user interaction):

- First two frames: `raster_ms` 109 / 108 — already abnormally high
  for an idle paint
- Then sustained `fps=2` with `raster_ms` 3-7 ms and frequent `fps=0`
  seconds interleaved
- `build_ms` near zero — the framework is doing nothing; the engine
  simply isn't getting paint cycles through

This is the steady-state signature of an engine in Context Lost
recovery. The classic D3D11/EGL error chain (`Present failed: D3D11
device was removed` → `EGL Error: Context Lost (12302)` → `Could not
make the context current to acquire the frame`) is logged by the
Flutter engine to stdout, not into the trace files; you only see it
if you launched the binary from a console.

The native log shows nothing remarkable — `WM_SIZE` lands once on
startup, then standard `WM_ACTIVATE` flips. No window resize, no DPI
change, no display reconfiguration coincides with the frame stalls.
The window is fine; the engine isn't.

## What was ruled out

- **Bridge / FFI subprocess** — bridge calls run 45-300 ms before
  freeze onset, no correlation with frame stalls
- **Mouse hover gates** — no `WM_*` event in 50+ lines before freeze
- **`FlutterView` 0×0 collapse** — false lead from a prior session
  (caused by a manual minimize/restore test, not a real freeze
  pathway)
- **Vsync starvation** — engine receives input messages, responds to
  `WM_PAINT`; the renderer is the one refusing to produce frames

The full elimination chain lives in
[`docs/release.md`](../../release.md) and the project memory entries
referenced from
[`bxp-gui/CLAUDE.md`](../../../bxp-gui/CLAUDE.md).

## What software rendering does

`flutter run --enable-software-rendering` eliminates the
`DXGI_ERROR_DEVICE_REMOVED` path (no EGL Context Lost) but a freeze
of a different shape still occurs — the SW rasterizer's output is
still presented through the DXGI swap chain into DWM, so the
shared-presentation cleanup path remains a failure mode. SW render
is **not** a silver bullet under VMware.

## Files

- [`diagnostic-20260508-164615.ndjson`](diagnostic-20260508-164615.ndjson)
- [`diagnostic-native-20260508-164615.log`](diagnostic-native-20260508-164615.log)
- [`diagnostic-probe.txt`](diagnostic-probe.txt)
