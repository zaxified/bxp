---
description: "Run conversions from the command line: selecting templates, overriding the data directory, dry runs and exit codes."
---

# Running a conversion

The conversion engine is `bxp-cli`. The GUI runs it for you; from a
terminal you invoke it directly. This page covers what happens at run
time — flags, exit codes, and where output goes. The full flag table is
in [CLI flags](../reference/cli-flags.md).

## In BXP Desktop

- **`dry-run`** runs the full pipeline in memory and streams a per-row
  trace, writing no files — the GUI equivalent of a preview/validation
  run.
- **`full-run`** produces the `.csvx` files.
- Clicking a run button again while a run is active cancels it (the label
  flips to `cancel`). There are no keyboard shortcuts for the run
  buttons — clicking is the only way to start a run.

## From a terminal

All flags are optional. Without arguments, bxp-cli reads `bxp-cli.json`
from the current directory and processes every template in it.

```bash
./bxp-cli --help                                    # print usage
./bxp-cli                                           # process all templates from bxp-cli.json
./bxp-cli --template <id>                           # process a single template
./bxp-cli --template <id> --data ./my-data/         # override data_dir for that template
```

See [CLI flags](../reference/cli-flags.md) for `--config`, `--debug`,
`--quiet`, `--fresh`, `--dry-run`, `--check-fs`, and the rest.

## Exit codes

| Binary  | Code | Meaning                                                                                                     |
| ------- | ---- | ----------------------------------------------------------------------------------------------------------- |
| bxp-cli | `0`  | Success — all matched rows converted, no warnings.                                                          |
| bxp-cli | `1`  | Fatal error — config invalid, file missing, expression failure.                                             |
| bxp-cli | `2`  | Completed with warnings — output written but at least one warning emitted (typo'd field, no input rows, …). |

`bxp-mcp` exits `0` in normal operation; per-tool outcomes ride on the
JSON-RPC response (the `isError` flag / a domain `{"ok":false}`), not the
process exit code. See [Exit codes](../reference/exit-codes.md).

## Where output goes

- **stdout** — bxp-cli per-template summaries and `--debug` JSON dumps.
  (bxp-mcp also writes its JSON-RPC responses to stdout, but that's the
  agent protocol channel, not something you pipe by hand.)
- **stderr** — fatal errors and warning text. Pipe `2>/dev/null` to
  silence warnings while still capturing the exit code.

Don't pipe `2>&1` if you intend to feed stdout to another tool —
bxp-cli's streaming output assumes stdout and stderr stay separate.
