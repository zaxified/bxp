# Your first conversion

The same conversion engine runs whether you drive it from the desktop
app or from a terminal. Pick the entry point that fits you.

## In BXP Desktop

1. **File → Open** (or ctrl+o). Pick your `bxp-cli.json`.
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
./bxp-cli --help                                  # print usage
./bxp-cli                                          # process all templates from bxp-cli.json
./bxp-cli --template <id>                           # process a single template
./bxp-cli --template <id> --data ./my-data/         # override data_dir for that template
```

All `data_dir` paths are resolved relative to the location of
`bxp-cli.json`.

## Next

- Don't see your broker? [Authoring a broker with an
  AI](../ai/authoring-a-broker.md), or write a template by hand starting
  from [Templates](../guide/templates.md).
- The full flag list is in [CLI flags](../reference/cli-flags.md); see
  also [Running a conversion](../guide/running.md) for exit codes and
  output behaviour.
