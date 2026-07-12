---
description: Ask Codex directly — one journaled, Governor-metered dispatch through Baton's hardened fleet path. `--tier <name>` selects a model/effort tier; `--tier all` boundary-tests every tier.
argument-hint: "<prompt>  [--tier <name>|all]"
---

# /baton:codex

Send a one-shot prompt to the **codex** fleet provider and print its answer.
Unlike a raw `codex exec`, this call is journaled to the model-routing log and
metered by the Usage Governor, and it reuses Baton's hardened prompt transport
(stdin / temp-file), so quotes and long prompts are safe.

## Steps

1. **Parse `$ARGUMENTS`.** Split off an optional trailing `--tier <name>` (or
   `--tier all`); everything else is the prompt. Empty prompt → print usage, stop.

2. **Write the prompt to a temp file** when it exceeds ~900 bytes or contains
   quotes (the 965-byte rule), then dispatch with `-PromptFile`; otherwise pass
   `-Prompt` inline:

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-ask.ps1" -Provider codex -PromptFile "<tmp>" [-Tier <name>]
   ```

3. **Relay** the model's stdout verbatim to the user, then the footer line
   (`-- codex | <N>s | exit:<code> | tok:<n>(<basis>)`). `tok:` is observe-only;
   `exact` means a real token count was captured, `estimate` means len/4.

Bare `/codex` alias: to type `/codex` instead of `/baton:codex`, copy this file
to `~/.claude/commands/codex.md` (documented, not force-deployed — namespace A3).
