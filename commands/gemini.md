---
description: Ask Gemini Antigravity (agy) directly — one journaled, Governor-metered dispatch through Baton's fleet path.
argument-hint: "<prompt>  [--tier <name>|all]"
---

# /baton:gemini

Send a one-shot prompt to the **gemini-antigravity** (agy) provider and print its
answer, journaled + Governor-metered.

## Steps

1. **Parse `$ARGUMENTS`.** Split off optional `--tier <name>`/`--tier all`; the
   rest is the prompt. Empty → usage, stop. Unknown tier → exit 2 with valid list.

2. **Dispatch** — agy interpolates the prompt inline (it does not read stdin), so
   embedded double quotes break it; route quote-free prompts, and use `-PromptFile`
   only for length, not quoting:

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-ask.ps1" -Provider gemini-antigravity -Prompt "<prompt>" [-Tier <name>]
   ```

3. **Relay** stdout + the footer (`tok:` = estimate; agy has no token regex).

Bare `/gemini` alias: copy this file to `~/.claude/commands/gemini.md` (A3).
