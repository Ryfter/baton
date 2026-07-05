---
description: Manage and invoke the LLM fleet. `doctor` health-checks providers, `test` dispatches a prompt to one provider, `list` shows the registry.
argument-hint: doctor [--live] [--timeout <s>] | test <name> "<prompt>" [--model <m>] | list
---

# /baton:fleet

Operate the fleet defined in `$BATON_HOME/fleet.yaml` (default `~/.baton/fleet.yaml`).

## Steps

1. **Parse `$ARGUMENTS`.** The first whitespace-delimited token is the
   subcommand: `doctor`, `test`, or `list`. If it's none of these (or empty),
   print usage and stop.

2. **Dispatch by subcommand:**

   **`doctor`** — run (with `--live` to enable canary probes):

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-doctor.ps1" -Live -TimeoutS 60
   ```

   Echo the table to the user. With `--live`, each enabled provider receives a `PONG` canary and reports `live_ok`, `live_fail(<reason>)`, or `skip`; a `no-canary` reason means the provider ran but didn't answer (often a wrong command template for this box). Plain (no `--live`) performs the fast PATH/reachability check only.

   **`list`** — run:

   ```powershell
   . "$HOME/.claude/scripts/fleet-lib.ps1"
   Read-Fleet | Select-Object name, kind, enabled, cost_tier | Format-Table -AutoSize
   ```

   **`test`** — the next token is `<name>`, then a quoted string is the prompt,
   then optional `--model <m>`. Run (substitute the parsed values for `<NAME>`,
   `<PROMPT>`, `<MODEL_OR_EMPTY>`):

   ```powershell
   . "$HOME/.claude/scripts/fleet-lib.ps1"
   $name   = '<NAME>'
   $prompt = '<PROMPT>'          # single-quote-escaped
   $model  = '<MODEL_OR_EMPTY>'
   $callArgs = @{ Name = $name; Prompt = $prompt }
   if ($model) { $callArgs['Model'] = $model }
   $r = Invoke-Fleet @callArgs
   Write-Host ""
   Write-Host "> $name" -ForegroundColor Cyan
   Write-Host ""
   Write-Host (($r.stdout | Out-String).Trim())
   Write-Host ""
   if ($r.exit_code -eq 0) {
       Write-Host "OK  $($r.duration_s)s exit:$($r.exit_code)" -ForegroundColor Green
   } else {
       Write-Host "ERR $($r.duration_s)s exit:$($r.exit_code)" -ForegroundColor Red
       if ($r.stderr) { Write-Host $r.stderr -ForegroundColor Red }
   }
   ```

   Echo the response to the user.

3. **On any error** (unknown/disabled provider, missing fleet.yaml), surface the
   thrown message clearly and suggest `/baton:fleet list` or `/baton:fleet doctor`.

## Arguments

$ARGUMENTS
