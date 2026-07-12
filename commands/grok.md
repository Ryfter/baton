---
description: Ask Grok (xAI CLI) directly — one journaled, Governor-metered dispatch through Baton's hardened fleet path (quote-safe temp-file transport).
argument-hint: "<prompt>  [--tier <name>|all]"
---

# /baton:grok

Send a one-shot prompt to the **grok-cli** fleet provider and print its answer,
journaled + Governor-metered. Grok's prompt rides a temp file (quote-safe).

## Steps

1. **Parse `$ARGUMENTS`.** Split off optional `--tier <name>`/`--tier all`; the
   rest is the prompt. Empty → usage, stop.

2. **Dispatch** (long/quote-heavy prompts via `-PromptFile`, the 965-byte rule):

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-ask.ps1" -Provider grok-cli -PromptFile "<tmp>" [-Tier <name>]
   ```

3. **Relay** stdout + the footer. grok has no token regex yet → `tok:` shows an
   honest `estimate`.

Bare `/grok` alias: copy this file to `~/.claude/commands/grok.md` (namespace A3).
