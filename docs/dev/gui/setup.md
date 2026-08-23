---
description: "Getting a Flutter development build of the desktop app running, including the bridge library."
---

# Setup & Development Workflow

## Getting started

### Prerequisites

| Tool        | Version                  | Notes                                                                                                                                                                    |
| ----------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Flutter SDK | the version CI pins      | `flutter-version` in `.github/workflows/ci.yml` is the source of truth — pinned rather than floating, because a newer stable surfaces fresh `info` lints that fail CI while passing locally. Install from [flutter.dev](https://flutter.dev) or via [`fvm`](https://fvm.app). |
| Dart SDK    | bundled                  | Ships with Flutter; no separate install. `environment.sdk` in `bxp-gui/pubspec.yaml` is the *Dart* constraint the package resolves against, not the Flutter version.        |
| Zig         | see `build.zig.zon`      | To build bxp-cli, bxp-mcp, and the bxp-gui-bridge library — `minimum_zig_version` is the source of truth; see [build.md](../build.md).                                      |
| VS Code     | any                      | Open `bxp.code-workspace`, which recommends the Dart and Flutter extensions along with the rest — see [build.md](../build.md#vs-code-setup). IntelliJ / Android Studio work too. |

### System prerequisites

Flutter's desktop embedders build native code, so the host toolchain has to be
there before `flutter run` works. Nothing below is bxp-specific — it is what a
Flutter desktop build needs on each platform.

=== "Linux"

    ```bash
    sudo apt-get install -y clang cmake ninja-build pkg-config \
        libgtk-3-dev liblzma-dev libstdc++-12-dev
    ```

    The release pipeline installs the same GTK/lzma/libstdc++ set (plus
    `dpkg-dev`, `fuse` and `libfuse2` for the `.deb` and `.AppImage` packaging
    steps) — see `.github/workflows/release.yml`. Note that `scripts/test.sh`
    does **not** need these: `test-04` runs `flutter analyze` and
    `flutter test`, which never link GTK. Only actually running or bundling
    the app does.

=== "macOS"

    Xcode plus its command-line tools, and CocoaPods:

    ```bash
    xcode-select --install
    sudo gem install cocoapods
    ```

=== "Windows"

    Visual Studio with the **Desktop development with C++** workload (the
    Build Tools edition is enough).

`flutter doctor` checks all of this for you and names what is missing; see
[Verify the install](#verify-the-install) below.

### First run

```bash
# 1. Build the backend binaries (required before flutter run)
cd bxp-cli && zig build
cd ../bxp-gui-bridge && zig build

# 2. Install Dart/Flutter dependencies
cd ../bxp-gui && flutter pub get

# 3. Run on your host platform
flutter run -d linux    # Linux
flutter run -d macos    # macOS
flutter run -d windows  # Windows (PowerShell)
```

The dev-tree binary fallback in `findBin()` walks up from the Flutter
executable until it finds the `bxp-gui/` segment, then resolves
`../bxp-cli/zig-out/bin/bxp-cli` and the `bxp-gui-bridge` library
automatically. No environment variables needed for local dev.

### Verify the install

Start with the toolchain itself:

```bash
flutter doctor -v
```

The rows that must be green are the host desktop toolchain (**Linux
toolchain** / **Xcode** / **Visual Studio**) and **Flutter**. Android
toolchain, Chrome and Android Studio rows can stay red — bxp-gui targets
desktop only, and CI explicitly disables the mobile toolchains
(`flutter config --no-enable-android --no-enable-ios`), which is worth doing
locally too: it drops roughly 0.8 GB of engine artifacts nothing here uses.

Then the app itself. On first launch it loads the language catalog in-process
from the bridge.
If the `bxp-gui-bridge` library is missing or unbuilt a fatal error gate
appears — build it first. Then:

1. Open a config via the file-picker or drag-drop — any
   `datasets/<template_id>/sample.json` works out of a fresh clone, and
   `resources/console/bxp-cli.examples.json` is the full starter set.
2. Select a template in the toolbar dropdown.
3. Click **Run** — the dry-run trace should populate the bottom panel.
4. Click any row to see per-variable and per-rule results.
5. Click any expression cell — the ExprPanel on the right shows a live
   evaluation playground.

---

## Development workflow

### Dart changes — hot reload

```bash
# Keep this terminal open while editing Dart
cd bxp-gui
flutter run -d linux

# r   — hot reload  (preserves app state, picks up most Dart changes)
# R   — hot restart (full Dart restart, clears state)
# q   — quit
```

VS Code users: the Flutter extension auto-hot-reloads on save when
"Hot reload on save" is enabled in settings. F5 launches with a full debugger
(breakpoints, variable inspector).

### Zig changes — rebuild + restart

Flutter does not hot-reload the Zig side.

```bash
# Terminal 1 — rebuild after editing bxp-cli or bxp-gui-bridge source
cd bxp-cli && zig build   # or bxp-gui-bridge
```

- **`bxp-cli`** is spawned per run (through the bridge), so the next dry-run
  picks up the new binary; a hot restart (`R`) is enough to re-resolve the path.
- **`bxp-gui-bridge`** is `dlopen`ed once at process start and mmapped, so a
  rebuilt `.so` / `.dylib` / `.dll` is **not** picked up by hot reload *or* hot
  restart. Fully quit the app and re-run.

### Debugging with print()

`dev_trace.dart` provides `devTrace(tag, message)` — a `kDebugMode`-gated
`print('[bxp_gui] $tag: $message')` helper.

- Use the `[bxp_gui]` prefix so MCP `get_app_logs` can filter output.
- Use `print()`, **not** `developer.log()` — MCP `get_app_logs` captures
  stdout only; `developer.log()` is invisible to it.
- Gate all debug prints behind `kDebugMode` so release builds stay clean.

MCP live-debug cycle (when working with Claude Code):

```bash
# 1. Launch via MCP (root must be a plain absolute path, not file://)
mcp__dart__launch_app(root: "<abs path to the monorepo>/bxp-gui")

# 2. Edit → hot reload
mcp__dart__hot_reload()

# 3. Read recent print() output
mcp__dart__get_app_logs()
```

### Running tests

```bash
# Widget + unit tests (bxp-gui)
flutter test

# json5_ast unit tests (~105 cases + round-trip suite)
dart test packages/json5_ast/

# Full desktop suite: flutter analyze + flutter test + dart test
bash scripts/test-04-desktop.sh
```

`flutter analyze` enforces sound null-safety and catches common issues. Run it
before committing — CI runs it on every release build.
