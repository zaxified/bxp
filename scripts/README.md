# BXP scripts

Two ortogonal groups: `test-` (run all tests) and `release-` (build +
publish release artifacts). Wrappers (`test.sh`, `release.sh`) iterate
their numbered siblings (`test-NN-*.sh`, `release-NN-*.sh`) in numeric
order, so adding a phase = drop a new file with the right prefix.
Standalone helpers without a numeric prefix
(`release-changelog.sh`, `release-tag.sh`) are human-driven; the
wrappers ignore them.

## Use case → command

| What I want to do | Command |
| -- | -- |
| Run the full test suite | `bash scripts/test.sh` |
| Console tests only (faster) | `bash scripts/test-01-console.sh` |
| Desktop tests only | `bash scripts/test-02-desktop.sh` |
| Local smoke build (no publish) | `bash scripts/release.sh` |
| Console build only | `bash scripts/release-01-console.sh` |
| Desktop build only (host platform) | `bash scripts/release-02-desktop.sh` |
| Generate `SHA256SUMS` for built artifacts | `bash scripts/release-03-checksums.sh releases/` |
| **Publish — step 1**: bump versions + write CHANGELOG | `bash scripts/release-changelog.sh patch` |
| **Publish — step 2**: tag CalVer + push (triggers CI) | `bash scripts/release-tag.sh` |

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
test-01-console.sh            bxp-core unit + bxp-fmt smoke + bxp-cli regression
test-02-desktop.sh            flutter analyze + flutter test + json5_ast dart test

release.sh                    wrapper — runs every release-NN-*.sh in order
release-01-console.sh         cross-compile bxp-cli for 3 platforms via Zig
release-02-desktop.sh         flutter build for host OS only + native packagers
release-03-checksums.sh       generate SHA256SUMS over release artifacts

release-changelog.sh          standalone — bump versions + prepend CHANGELOG.md
release-tag.sh                standalone — CalVer tag + push (triggers CI)
```

## Conventions

- Numeric prefix `NN` is zero-padded to 2 digits (`01..99`).
- All scripts are bash and use `set -e`.
- All scripts take `--dry-run` if they have side effects.
- Wrappers pass through arguments to each phase verbatim.
- Local builds populate `releases/console/` and `releases/desktop/`;
  these dirs are gitignored.
