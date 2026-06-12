---
description: Inventory the local model fleet. Probes each box's API (LM Studio native, ollama), joins with registry pins/claims/keep-list, prints recommendations. `--import` loads a Gauntlet scorecard into the ratings store.
argument-hint: "[--json] [--box <provider>] [--import <scorecard.json>]"
---

# /baton:models

Inventory the models installed on each registered local box, compare against
`$BATON_HOME/fleet.yaml` (pins, capability claims, keep_list), and surface
recommend-only findings (missing pins, judge risks, near-duplicates,
unregistered specialists). Never installs or deletes anything.

## Steps

1. **Parse `$ARGUMENTS`.** Recognize `--json`, `--box <provider-name>`, and
   `--import <path>`. Anything else: print usage and stop.

2. **Dispatch** (substitute parsed values; map `--json` to `-Json`, `--box X`
   to `-Box X`, `--import P` to `-Import P`):

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-models.ps1" <MAPPED-ARGS>
   ```

   - default: echo the per-box tables and the recommendations section verbatim.
   - `--json`: emit the snapshot JSON (also always written to
     `$BATON_HOME/model-inventory.json`).
   - `--import <path>`: forwards to `Import-GauntletScorecard`; report the
     imported/skipped/unmapped counts it prints.

3. **Summarize for the user** in 2-4 plain-language bullets: how many models
   per box, anything OFFLINE, and each recommendation line with a one-clause
   explanation. Do not act on recommendations — Kevin decides.
