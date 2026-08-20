---
description: "The templates that ship next to the binary, what each one converts, and how to run one by id."
---

# Built-in templates

BXP ships working templates for several brokers, targeting both Wealthfolio
and brycht.app. They are what a template happens to describe here, not what
templates are for — see [what a template is](../guide/templates.md). Use one directly, or pattern-match against
the closest one when [authoring a new
template](../ai/authoring-a-template.md).

--8<-- "reference/built-in-templates.md:table"

Template ids read `<source>_to_<target>`, so an id names both ends of the
conversion, and `bxp-cli --template <id>` runs exactly one of them.

The shipping templates live in `bxp-cli.examples.json` — next to the
`bxp-cli` binary in the console archive, inside the app bundle on desktop, and
at
[`resources/console/bxp-cli.examples.json`](https://github.com/zaxified/bxp/blob/master/resources/console/bxp-cli.examples.json)
in the GitHub repository. Each carries inline JSON5 comments
documenting what every `$variable` represents and how the source's own
vocabulary maps — they are the canonical reference for new templates.
