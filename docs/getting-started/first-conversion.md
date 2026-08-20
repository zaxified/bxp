---
description: "Run a real conversion end to end: point a shipped template at a broker export and read the result."
---

# Your first conversion

The same conversion engine runs whether you drive it from the desktop
app or from a terminal. Pick the entry point that fits you.

## In BXP Desktop

1. Click **OPEN** in the toolbar (or ctrl+o — cmd+o on macOS). Pick your
   `bxp-cli.json`.
2. Select a template in the toolbar dropdown, click `dry-run`. The
   bottom pane streams trace events for every input row.
3. Inspect the trace, fix any errors that appear inline in the tree,
   then click `full-run` to produce the `.csvx` files.

## From a terminal

1. Drop the broker's export file into the template's `data_dir`.
2. Run `./bxp-cli --template <id>`.
3. Pick up the generated `*.csvx` file next to the input — ready to
   import into the tracker the template targets (Wealthfolio for
   `*_to_wealthfolio`, brycht.app for `*_to_brychtapp`).

```bash
./bxp-cli --help                                    # print usage
./bxp-cli                                           # process all templates from bxp-cli.json
./bxp-cli --template <id>                           # process a single template
./bxp-cli --template <id> --data ./my-data/         # override data_dir for that template
```

All `data_dir` paths are resolved relative to the location of
`bxp-cli.json`.

## Your own exports

`bxp-cli` reads `bxp-cli.json` from the current directory, and each template's
`data_dir` is resolved *relative to that config file*. The config in the
console archive uses `data_dir: "."`, which is why `sample.csv` is found next
to the binary. For real work, give each template its own folder:

```text
my-conversions/
├── bxp-cli.json              # your config — data_dir paths start here
├── trading212/               # data_dir of the trading212 template
│   ├── export-2026-01.csv    # drop broker exports here
│   └── export-2026-01.csvx   # bxp-cli writes the result alongside
└── revolut/                  # data_dir of another template
    └── statement.csv
```

To add a broker, open [`bxp-cli.examples.json`](built-in-templates.md), copy
the template you want into the `conversion_templates` object of your own
`bxp-cli.json`, and set its `data_dir` to the folder you made for it. Then:

```bash
./bxp-cli --template trading212_to_wealthfolio   # one template
./bxp-cli                                        # every template in the config
```

## Next

- Don't see your broker? [Authoring a broker with an
  AI](../ai/authoring-a-broker.md), or write a template by hand starting
  from [Templates](../guide/templates.md).
- The full flag list is in [CLI flags](../reference/cli-flags.md); see
  also [Running a conversion](../guide/running.md) for exit codes and
  output behaviour.
