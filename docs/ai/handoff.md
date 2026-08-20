---
description: "What an agent should hand back to a non-technical user once a template is working."
---

# Handing off to the user

The user is often non-technical and is following your natural-language
instructions. After you return the JSON, append a section like this when
there's anything left to verify:

```text
## Things to check in bxp-gui

1. **Open** your `bxp-cli.json` (Ctrl+O, Cmd+O on macOS), select the
   new template `<id>` in the toolbar dropdown, click **dry-run**.

2. **DIVIDEND rows** (3 in your sample): the right-hand trace will
   show `quantity = 0`, `unitPrice = (empty)`. Wealthfolio may or
   may not accept this — try importing the resulting `.csvx` and tell
   me if Wealthfolio rejects DIVIDEND rows. If yes, I'll switch the
   template to set `$quantity = 1` and `$unitprice = $amount` for
   DIVIDEND rows specifically.

3. **Cash event description** (FEE, DEPOSIT rows): the `comment`
   column reads `' ()'` (empty source columns). If you'd prefer
   blank, click any FEE row → expression panel → change `$comment`
   to `IF([Wertpapier] = '', '', [Wertpapier] & ' (' & [WKN] & ')')`.

4. **Splits / mergers / transfers** (skipped per the target spec): I
   added `rows: []` for direction `in` / `out`. If your account had any
   splits in the sample period, those rows produce no output — click one
   of those rows after the dry-run and read the **RULE RESULTS** panel
   (it names the rule that matched, or says none did), then tell me the
   line numbers. I'll add explicit `'SPLIT'` handling if Wealthfolio
   supports it.
```

Each instruction must be:

- **Action-led** ("Open …", "Click …", "Tell me …") — the user doesn't
  infer what to do from a description.
- **Targeted** — name the specific GUI control (Ctrl+O, dropdown,
  expression panel, Settings inspector). The [GUI features](../gui/features.md)
  page lists every concrete location.
- **Round-trip** — end with what the user should report back so you can
  finish the template. Avoid open-ended "let me know if anything looks
  wrong"; ask for specific cell values, exit codes, or `.csvx` rows.

If everything is verifiably correct (every sample row predicted exactly,
no Wealthfolio-import gotchas you're aware of), say so explicitly: _"This
template should be complete. Run a dry-run and import the `.csvx` into
Wealthfolio; nothing else needs your attention."_
