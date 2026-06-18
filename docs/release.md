# Cutting a release

> [← docs/](README.md)

Release artifacts are produced by `.github/workflows/release.yml` on
every `v*` tag push. The pipeline fans out across three host runners
(ubuntu, windows, macos) so all native installers come from real native
builds rather than cross-compilation tricks.

## The release flow

Three commands, in order. The first two are local; the third triggers
the GitHub Actions matrix and waits for it to finish (~10 min).

```bash
# 1. Bump every manifest in lockstep + generate the CHANGELOG entry
#    + commit as "release: prepare X.Y.Z (YYYY.MM.DD)".
bash scripts/release-changelog.sh patch        # or `minor` / `major` / `X.Y.Z`

# 2. Push the bump commit so the tag points at a public ref.
git push origin master

# 3. Tag from the version just bumped + push the tag.
bash scripts/release-tag.sh
```

`release-tag.sh` reads the version from `bxp-cli/build.zig.zon` (the
canonical reference; `release-changelog.sh` keeps every manifest in
lockstep with it) and tags as `v$VERSION`. It refuses on a dirty tree
or if the tag already exists, so order matters: changelog first,
push, then tag.

Both scripts accept `--dry-run` to preview without mutating anything.

**Get the code green on master _before_ step 1.** The release should ride
code that CI has already passed: push your feature work, let `ci.yml` go
green, run `scripts/test.sh` locally, _then_ bump + tag. The CI workflow
deliberately **skips** the `release: prepare X.Y.Z` commit (it changes only
the six manifest version strings + `CHANGELOG.md` — no code to test), so the
master push in step 2 does not re-run the full three-OS suite. The `v*` tag
in step 3 then triggers the release build matrix. Net: one CI fan-out per
release instead of two. (This is why the skip lives as a job-level `if:`
guard in `ci.yml`, not a `[skip ci]` commit marker — the tag points at the
release-prep commit, so a commit-message marker would suppress `release.yml`
too.)

### Optional: Windows pre-shipping smoke (between step 2 and step 3)

When the release contains **substantial `bxp-gui` changes** — Flutter
widget refactors, new dialogs, MSVC-dependent native code (engine
stderr capture, NSIS installer changes, bridge ABI), or anything that
plausibly touches the Windows build path — do a local Windows build
between pushing master and pushing the tag. GH Actions matrix runs
windows-latest only, so a regression that breaks Win MSVC compile or
NSIS-install behaviour surfaces _after_ the release is half-published.

On a Windows host with Git Bash + Zig (the `build.zig.zon` version) + Flutter
(Windows desktop support) + Visual Studio with C++ desktop workload + NSIS on PATH:

```bash
git pull origin master
bash scripts/release-02-desktop.sh
# → releases/desktop/bxp-desktop-windows-x86_64.exe
```

Install and exercise the NSIS-built `.exe`: startup gate (bridge docs
probe), open a real `bxp-cli.json`, dry-run + full-run, expr
playground, settings inspector. Anything `bxp-gui` touched in the
release should be covered manually. Bridge ABI changes specifically:
verify the synthetic startup error path stays clean (the bridge probe
either loads or fails fatal — there is no `Process.start` fallback on
Windows).

If green → push the tag (step 3 below). If red → fix on the dev host,
push to master, repeat the Win pull/build/test cycle until clean. The
RC workflow_dispatch path is the alternative when Windows hardware
isn't available — see "Testing on the windows-latest runner without a
real tag" further down (uses the workflow_dispatch trigger).

Skip this step for tag-prep wave releases (CHANGELOG / version bumps
only), pure `bxp-cli` / `bxp-core` changes, or documentation-only
releases — the GH Actions matrix is sufficient for those.

## What gets built

| job               | runner         | output                                                                              |
| ----------------- | -------------- | ----------------------------------------------------------------------------------- |
| `console`         | ubuntu-latest  | `bxp-console-<ver>-{linux-x86_64.tar.gz, windows-x86_64.zip, macos-aarch64.tar.gz}` |
| `desktop-linux`   | ubuntu-22.04   | `bxp-desktop-linux-x86_64.AppImage`                                                 |
| `desktop-windows` | windows-latest | `bxp-desktop-windows-x86_64.exe`                                                    |
| `desktop-macos`   | macos-latest   | `bxp-desktop-macos-arm64.dmg`                                                       |
| `release`         | ubuntu-latest  | aggregates above + `SHA256SUMS` + minisign `SHA256SUMS.minisig`, publishes Release  |

The three desktop installers carry no version string in their filename
(only the `bxp-console` archives and the git tag do); the in-app inspector
reports the running version. Each platform ships exactly one desktop format
— AppImage on Linux, `.exe` on Windows, `.dmg` on macOS.

`bxp-console` archives are GUI-free (small, no Flutter deps) but ship
both `bxp-cli` and `bxp-mcp` — the latter so a console user (or an AI
assistant) can run the documented self-test (the bxp-mcp tools:
`bxp_validate` / `bxp_validate_expr` / `bxp_simulate`).
`bxp-desktop` archives ship the Flutter GUI plus bundled `bxp-cli`,
`bxp-mcp`, and the `bxp-gui-bridge` library companion binaries so
the GUI is self-contained.

The Linux desktop runner is pinned to `ubuntu-22.04` (glibc 2.35
baseline) so AppImages run on anything from 2022+. Bumping past glibc
2.35 should be a deliberate decision — flag it in the release notes.

## Local smoke tests

Run before tagging to catch obvious breakage:

```bash
# Full console + desktop test suite (skips desktop if Flutter is missing).
bash scripts/test.sh

# Build the host platform's desktop bundle locally (no upload).
bash scripts/release-02-desktop.sh vX.Y.Z-rc1
ls releases/desktop/

# Build all three console archives (cross-compiled via Zig).
bash scripts/release-01-console.sh vX.Y.Z-rc1
ls releases/console/
```

`release-02-desktop.sh` only builds the host's branch — the other two
platforms are exercised by GH Actions runners. Use `workflow_dispatch`
to test the Windows / macOS branches without cutting a real tag:

```bash
gh workflow run release.yml -f version=vX.Y.Z-rc-test
```

## Verifying a published release

1. Open `https://github.com/zaxified/bxp/releases/tag/vX.Y.Z`.
2. Confirm 6 build artifacts (3 console + 3 desktop) + `SHA256SUMS` +
   `SHA256SUMS.minisig` are listed (8 files total).
3. Download a desktop installer for your host, run it, and verify the
   GUI launches. The startup screen should show the version in
   SettingsInspector (Ctrl+Shift+S).
4. Check that an existing install of an earlier version (run from
   another machine or a fresh user account) shows the update prompt
   within 5 seconds of launch — UpdaterService polls
   `api.github.com/repos/zaxified/bxp/releases/latest`.

## Troubleshooting

- **Workflow fails in `desktop-linux`** — usually appimagetool runtime
  fetch (`runtime-x86_64`) hits a transient network error. Re-run the
  failed job; the cache survives.
- **Workflow fails in `desktop-macos`** — `create-dmg` is sensitive to
  the macOS runner image's exact version. If `brew install create-dmg`
  no longer pins to a working version, fall back to a tarball-only
  macOS branch by commenting out the DMG step in
  `release-02-desktop.sh::build_macos`.
- **NSIS install on Windows fails silently** — run the installer
  manually with `setup.exe /S` from PowerShell to surface stderr; check
  the `IfSilent` block in `bxp-gui/installer/bxp-desktop.nsi`.
- **Auto-updater installs but app doesn't relaunch** — the platform's
  install path is responsible for relaunching:
  - Windows: NSIS post-install hook (`Exec` under `IfSilent`).
  - macOS: `open -n` in `_installMacOS` of `updater_service.dart`.
  - Linux AppImage: re-`exec()` of the new file in `_installLinuxAppImage`.

## Signing and supply-chain integrity

Every real tag release ships a **minisign-signed checksum manifest**, and the
in-app updater **fails closed** without it:

- `release-03-checksums.sh` writes `SHA256SUMS` over the staged artifacts, then
  re-verifies it with `--check` before anything is signed — a truncated or
  corrupt artifact fails the release loudly instead of shipping.
- The `release` job signs `SHA256SUMS` with minisign (the maintainer's single
  key, held in the gated `MINISIGN_KEY` secret) to produce `SHA256SUMS.minisig`.
  The key is reachable only from `v*` tag runs.
- **A tag release with no signing key refuses to publish** — an unsigned release
  would be rejected by every fail-closed client, so the workflow errors out
  instead of shipping one. (A `workflow_dispatch` test run skips signing, as it
  is not a real release.)

On the client, `UpdaterService` verifies `SHA256SUMS.minisig` against an embedded
public key **before** trusting the manifest, then matches the downloaded
installer's hash against it — two fail-closed steps over the same bytes. A forged
installer plus a matching `SHA256SUMS` cannot produce a valid signature without
the private key. See [`gui.md`](gui.md#auto-updater-and-security) for the client
side.

## What's NOT signed (OS code signing)

Distinct from the minisign integrity layer above: the **binaries themselves**
carry no OS-level code-signing certificate, so the platform's first-launch
warning still appears. This is independent of update integrity — the updater's
minisign check still protects every download.

- macOS `.app` is **ad-hoc signed** only; Gatekeeper warns on first
  launch (right-click → Open works). Apple Developer ID notarisation
  is out of scope (paid account).
- Windows `setup.exe` is **unsigned**; SmartScreen warns once.
  Authenticode signing is out of scope (paid cert).

Updates inherit the Gatekeeper / SmartScreen allowance the user granted
at first install, so the warning only appears once per machine.
