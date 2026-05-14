# BXP scripts

Two ortogonal groups: `test-` (run all tests) and `release-` (build +
publish release artifacts). Wrappers (`test.sh`, `release.sh`) iterate
their numbered siblings (`test-NN-*.sh`, `release-NN-*.sh`) in numeric
order, so adding a phase = drop a new file with the right prefix.
Standalone helpers without a numeric prefix
(`release-changelog.sh`, `release-tag.sh`) are human-driven; the
wrappers ignore them.

## Use case → command

| What I want to do                                     | Command                                          |
| ----------------------------------------------------- | ------------------------------------------------ |
| Run the full test suite                               | `bash scripts/test.sh`                           |
| Console tests only (faster)                           | `bash scripts/test-01-console.sh`                |
| Dataset regression only                               | `bash scripts/test-02-datasets.sh`               |
| Desktop tests only                                    | `bash scripts/test-03-desktop.sh`                |
| Bridge tests only                                     | `bash scripts/test-04-bridge.sh`                 |
| Format + markdown lint only                           | `bash scripts/test-05-format.sh`                 |
| Expression corpus only                                | `bash scripts/test-06-expr-corpus.sh`            |
| Local smoke build (no publish)                        | `bash scripts/release.sh`                        |
| Console build only                                    | `bash scripts/release-01-console.sh`             |
| Desktop build only (host platform)                    | `bash scripts/release-02-desktop.sh`             |
| Generate `SHA256SUMS` for built artifacts             | `bash scripts/release-03-checksums.sh releases/` |
| **Publish — step 1**: bump versions + write CHANGELOG | `bash scripts/release-changelog.sh patch`        |
| **Publish — step 2**: tag CalVer + push (triggers CI) | `bash scripts/release-tag.sh`                    |

## Publishing a release

```bash
# Make sure tests pass and you're on master with everything pushed.
bash scripts/test.sh

# Bump versions across all 5 manifests (lockstep) and prepend a
# CHANGELOG.md entry generated from `git log <last-tag>..HEAD`.
bash scripts/release-changelog.sh patch    # or: minor / major / 0.3.0

# Review CHANGELOG.md, edit if needed.
git push origin master

# Tag with today's date (YYYY.MM.DD), append `-N` if a tag already
# exists for today. Pushing the tag triggers
# `.github/workflows/release.yml` which produces console + desktop
# archives + SHA256SUMS and publishes a GitHub Release.
bash scripts/release-tag.sh
```

## File reference

```text
test.sh                       wrapper — runs every test-NN-*.sh in order
test-lib.sh                   shared section/step/summary helpers (sourced)
test-01-console.sh            bxp-core unit + bxp-cli/fmt build + bxp-fmt smoke + json5_ast unit
test-02-datasets.sh           bxp-cli regression vs datasets/*/*.expected
test-03-desktop.sh            flutter analyze + flutter test + json5_ast dart test
test-04-bridge.sh             bxp-gui-bridge unit tests (FFI surface)
test-05-format.sh             prettier --check + markdownlint-cli2
test-06-expr-corpus.sh        bxp-fmt --expr corpus regression gate

release.sh                    wrapper — runs every release-NN-*.sh in order
release-01-console.sh         cross-compile bxp-cli for 3 platforms via Zig
release-02-desktop.sh         flutter build for host OS only + native packagers
release-03-checksums.sh       generate SHA256SUMS over release artifacts

release-changelog.sh          standalone — bump versions + prepend CHANGELOG.md
release-tag.sh                standalone — CalVer tag + push (triggers CI)
```

## Platform requirements

CI (`.github/workflows/release.yml`) drives the release pipeline on
`ubuntu-latest` / `windows-latest` / `macos-latest`. The scripts also
run locally on all three hosts, with a few caveats:

- **bash ≥ 4** — `test.sh` and `release-changelog.sh` use `declare -A`
  (associative arrays), which bash 3.2 (Apple's default `/bin/bash`)
  does not support. macOS users: `brew install bash` and either invoke
  via `bash scripts/...` (the brew bash from PATH wins) or update the
  shebang resolution. The `#!/usr/bin/env bash` shebang already does
  the right thing if a newer bash is on PATH.
- **coreutils on macOS** — `test.sh` uses `timeout` to bound the corpus
  phase. macOS doesn't ship it; the wrapper degrades gracefully
  (no enforcement). `brew install coreutils` if you want the bound back.
  `release-03-checksums.sh` handles `sha256sum` vs BSD `shasum` itself.
- **python3** — `test-01-console.sh` and `test-06-expr-corpus.sh` shell
  out to `python3` for JSON validation. Pre-installed on all three GH
  runners; on Windows local dev (Git Bash) you may need to add Python
  to PATH explicitly.
- **Maintainer-only scripts** (`release-changelog.sh`, `release-tag.sh`)
  use GNU-leaning idioms but have been written to work on BSD sed too
  (write-to-tmp instead of `sed -i`).

## Conventions

- Numeric prefix `NN` is zero-padded to 2 digits (`01..99`).
- All scripts are bash and use `set -e`.
- All scripts take `--dry-run` if they have side effects.
- Wrappers pass through arguments to each phase verbatim.
- Local builds populate `releases/console/` and `releases/desktop/`;
  these dirs are gitignored.
