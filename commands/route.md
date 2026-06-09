---
description: Recommend OR dispatch the optimal capability (tool or model) for a need — cheapest capable tier first ("optimal, not best"), reading tools.yaml + fleet.yaml. Without --run it recommends; with --run "<prompt>" it auto-dispatches, verifies the output, and escalates up the cost ladder.
argument-hint: "<capability>" [--max-tier local|free|paid] [--local] [--run "<prompt>"]
---

# /route

Recommend **or dispatch** the optimal capability for a need. Reads the `tools.yaml`
(capability-specific tools + specialty models) and `fleet.yaml` (general models) registries and
ranks the candidates that serve `<capability>`, cheapest cost-tier first. **Without `--run`** it
recommends only. **With `--run "<prompt>"`** it auto-dispatches the cheapest candidate, verifies
the output with a heuristic grader, escalates up the cost ladder on failure (ending at
"escalate to conductor"), and logs every attempt to `~/.claude/routing-journal.jsonl`.

## Steps

1. **Parse `$ARGUMENTS`:** the first token is `<capability>`; optional `--max-tier local|free|paid`,
   `--local`, and `--run "<prompt>"`. Empty capability → stop with:
   *"Usage: /route \"<capability>\" [--max-tier local|free|paid] [--local] [--run \"<prompt>\"]"*.

2. **Without `--run` (recommendation mode, unchanged):**

   ```powershell
   . "$HOME/.claude/scripts/routing-lib.ps1"
   $sel = @{ Capability = '<capability>' }
   if ($local)   { $sel['RequireLocal'] = $true }
   if ($maxTier) { $sel['MaxCostTier']  = '<tier>' }
   $cands = Select-Capability @sel
   ```

   - If `$cands` is empty, say no candidate serves `<capability>` and list `Get-KnownCapabilities`.
   - Otherwise print the ranked table and the top pick:

     ```powershell
     $cands | Format-Table name, source, kind, cost_tier, quality, why -AutoSize
     Write-Host "Top pick: $($cands[0].name) — $($cands[0].why)"
     ```

   Note this is a recommendation; pass `--run "<prompt>"` to dispatch.

3. **With `--run "<prompt>"` (dispatch mode):**

   ```powershell
   . "$HOME/.claude/scripts/routing-dispatch.ps1"
   $opt = @{ Capability = '<capability>'; Prompt = '<prompt>' }
   if ($local)   { $opt['RequireLocal'] = $true }
   if ($maxTier) { $opt['MaxCostTier']  = '<tier>' }
   $outcome = Invoke-RoutedCapability @opt
   foreach ($a in $outcome.attempts) {
       $mark = if ($a.passed) { 'PASS' } else { 'fail' }
       Write-Host ("  {0,-5} {1,-22} {2}  ({3}s)  {4}" -f $a.cost_tier, $a.candidate, $mark, $a.duration_s, $a.reason)
   }
   ```

   Then report the outcome by `$outcome.status`:
   - `passed` → state the winner and show `$outcome.result.stdout`.
   - `escalate-to-conductor` → tell the user every candidate failed (list the per-attempt
     reasons above) and that it is escalating to the conductor (you, Claude) to do the task
     directly or pick a model manually.
   - `no-candidate` → no candidate serves `<capability>`; list `Get-KnownCapabilities`.

   Finish with: *"Logged $($outcome.attempts.Count) attempt(s) to ~/.claude/routing-journal.jsonl."*

4. **On any error** (missing `tools.yaml`/`fleet.yaml`), surface the thrown message and suggest
   `pwsh scripts\bootstrap.ps1 -Force` to deploy the registries.

## Arguments

$ARGUMENTS
