# Contributing

Thanks for considering a contribution to BXP. Contributions of all
shapes are welcome — bug reports, broker templates, code, documentation,
and especially **datasets** (real broker exports + expected outputs)
that lock in edge cases for future releases.

## Bug reports and feature requests

Open an issue at <https://github.com/zaxified/bxp/issues>.

For bugs, please include:

- The binary version (`bxp-cli --version`, or
  `Help → About` in `bxp-gui`).
- A minimal config snippet plus a short input sample that reproduces
  the problem.
- Expected vs. actual output, and the exit code.

For feature requests, describe the broker or use-case first and the
implementation idea second. Planned work is in
[`docs/roadmap.md`](docs/roadmap.md) — check there before opening a new
issue in case something is already queued.

## Datasets — the most valuable contribution

The [`datasets/`](datasets/) directory is the regression-test corpus
exercised by `scripts/test.sh`. Each entry pairs a real (anonymised)
broker export with its expected `.csvx` output, so changes to the
engine cannot silently break a real-world template.

Each dataset folder is named `<template_id>/` and contains:

- `sample.json` — short description of the case.
- `sample_<from>_<to>.csv` (or `.xlsx` / `.json`) — the anonymised input.
- `sample_<from>_<to>.expected` — the expected `.csvx` output, byte-for-byte.

To submit:

1. Anonymise the export — strip account numbers, names, exact amounts
   if sensitive, but preserve the format quirks that matter.
2. Add the folder under `datasets/<template_id>/`.
3. Run `bash scripts/test.sh` locally — it must pass.
4. Open a PR with a short description of what edge case is covered.

If your contribution uncovers a bug in an existing template, fix the
template in the same PR.

## New broker templates

If your broker is not in the built-in `conversion_templates` list, the
workflow is:

1. Draft a template with the AI workflow described in
   [`resources/console/readme.md`](resources/console/readme.md)
   ("Need a broker that isn't listed?" section).
2. Verify it with the bxp-mcp tools (`bxp_validate` + `bxp_simulate`) or
   `bxp-cli --debug` (runtime check).
3. Add the template to `resources/bxp-cli.examples.json` and a paired
   dataset under `datasets/`.
4. Open a PR.

## Code contributions

For build / test commands, repo layout, and architecture see
[`docs/devel.md`](docs/devel.md). Module-level conventions live in the
`CLAUDE.md` file inside each package
([`bxp-cli/`](bxp-cli/CLAUDE.md), [`bxp-core/`](bxp-core/CLAUDE.md),
[`bxp-mcp/`](bxp-mcp/CLAUDE.md), [`bxp-gui/`](bxp-gui/CLAUDE.md)).

- Run `bash scripts/test.sh` before opening a PR.
- Keep one logical change per PR — bundle dataset + template + code in
  one PR only when they really belong together.
- Don't commit secrets or non-anonymised broker data.

## Documentation

Fixes to [`docs/`](docs/) and the user-facing readmes in
[`resources/console/`](resources/console/readme.md) /
[`resources/desktop/`](resources/desktop/readme.md) are welcome as
small PRs. If a section is unclear or wrong, file an issue or open the
PR directly.

## Recognition

Contributors of merged PRs are credited in the GitHub release notes for
the version that ships their change.
