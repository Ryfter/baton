---
description: Manage the LLM fleet and overnight multi-lane factory. doctor|list|test|dispatch|status|stop. Layer seating baton-d124.
argument-hint: doctor [--live] | list | test <name> "<prompt>" | dispatch | status | stop
---

# /baton:fleet

Operate the fleet. Prefer **repo scripts** under `/Users/kev/Dev/Baton/scripts/` when present; fall back to `$HOME/.claude/scripts`.

**Layer seating (`baton-d124`):** Mouth/Conductor → Ox Alpha · Orchestrator → Opus · Plan/sprint-review → Fable · Instruments → Ox Alpha + Codex/Grok/Kiro/Cursor.

Live registry: `~/.baton/fleet.yaml`  
Overnight multi-lane: `~/.baton/overnight/` (`fleet.yaml`, `goals/`, `fleet-dispatch.sh`)

## Steps

1. **Parse `$ARGUMENTS`.** First token is the subcommand: `doctor`, `test`, `list`, `dispatch`, `status`, or `stop`. Else print usage and stop.

2. **Dispatch:**

   **`doctor`** — with `--live` for canaries:

   ```powershell
   & pwsh -NoProfile -File "/Users/kev/Dev/Baton/scripts/fleet-doctor.ps1" -Live -TimeoutS 60
   ```

   **`list`** — overnight roster if user said overnight/dispatch context, else live:

   ```powershell
   . "/Users/kev/Dev/Baton/scripts/fleet-lib.ps1"
   Read-Fleet -Path "$HOME/.baton/overnight/fleet.yaml" | Select-Object name,kind,enabled,cost_tier | Format-Table -AutoSize
   ```

   **`test`** — next token `<name>`, then quoted prompt, optional `--model <m>`:

   ```powershell
   . "/Users/kev/Dev/Baton/scripts/fleet-lib.ps1"
   $r = Invoke-Fleet -Name '<NAME>' -Prompt '<PROMPT>' # + Model if set
   ```

   Prefer seats by capability: `converse`/`orchestrate`/`sprint-review`/`code-gen`.

   **`dispatch`** — start multi-lane overnight factory:

   ```bash
   rm -f ~/.baton/overnight/STOP
   bash ~/.baton/overnight/fleet-dispatch.sh
   ```

   **`status`** — show `~/.baton/overnight/fleet-status.json` and recent lane logs.

   **`stop`** — `touch ~/.baton/overnight/STOP` (lanes exit between rounds).

3. **On error**, surface the message; suggest `list` or `doctor`. Never print OpenRouter keys from `~/.baton/overnight/.openrouter.env`.

## Arguments

$ARGUMENTS
