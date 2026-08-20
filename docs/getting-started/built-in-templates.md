# Built-in templates

BXP ships working templates for several brokers, targeting both
Wealthfolio and brycht.app. Use one directly, or pattern-match against
the closest one when [authoring a new
broker](../ai/authoring-a-broker.md).

--8<-- "reference/built-in-templates.md:table"

The shipping templates live in `bxp-cli.examples.json` — next to the
`bxp-cli` binary in the console archive, and at
[`resources/console/bxp-cli.examples.json`](https://github.com/zaxified/bxp/blob/master/resources/console/bxp-cli.examples.json)
in the GitHub repository. Each carries inline JSON5 comments
documenting what every `$variable` represents and how the broker's source
actions map — they are the canonical reference for new templates.
