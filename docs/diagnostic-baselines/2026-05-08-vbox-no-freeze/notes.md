# 2026-05-08 — VirtualBox, no freeze (negative case)

**Conclusion:** Same Windows 10 build, same `bxp-gui.exe`, but
running under VirtualBox instead of VMware: no freeze, no GPU TDR,
no Context Lost cascade. This pins the freeze to the VMware SVGA
D3D11 driver path, not to bxp-gui code or to Flutter Windows
generally. Bare-metal Windows 10 is still untested as of capture
date but presumed clean by symmetry.

## Environment

- Windows 10 Pro 19045 in VirtualBox guest
- Dart 3.11.5, locale `cs_CZ`
- Single display adapter:
  - `VirtualBox Graphics Adapter (WDDM)` driver `7.0.24.17081`
    (Oracle Corporation, refresh 1 Hz reported, 1920×1080)

The 1 Hz `CurrentRefreshRate` is a VBox WMI quirk, not a real
display rate — the driver's reported value during this capture
window is unreliable. Frame stats elsewhere in the trace show the
engine producing tens of frames per second when work is present.

## What the trace shows

20 minutes of mixed idle and interaction:

- `raster_ms` swings 47-200 ms — variable but always recovers; no
  sustained `fps=2` plateau like the VMware case
- Multiple `fps=0` seconds, but each one is followed by a real
  frame in the next second (engine recovery works)
- `build_ms` occasionally spikes to 378-479 ms during interaction —
  this is the framework genuinely doing layout work, not engine
  starvation
- Click-through to dialogs, hover scrolling over JSON tree, dry-run
  starts and completes — the GUI remains responsive throughout

## Bonus finding: open dialog crash on empty CD-ROM

The trace contains repeated `error.flutter` events from
[`open_dialog.dart:41`](../../../bxp-gui/lib/ui/components/open_dialog.dart#L41):

```text
FileSystemException: Exists failed, path = 'D:\'
(OS Error: Zařízení není připraveno, errno = 21)
```

`_windowsDrives` calls `Directory(p).existsSync()` on every drive
letter A:\..Z:\. On a "not ready" drive (CD-ROM with no media,
which VirtualBox guests typically have at `D:\`), `existsSync`
throws instead of returning `false`. The dialog rebuilds repeatedly
on every drive enumeration. Independent of the VMware freeze.

## Files

- [`diagnostic-20260508-172318.ndjson`](diagnostic-20260508-172318.ndjson)
- [`diagnostic-native-20260508-172318.log`](diagnostic-native-20260508-172318.log)
- [`diagnostic-probe.txt`](diagnostic-probe.txt)
- [`bxp-gui.json`](bxp-gui.json) — user-prefs file from this session, anonymized
