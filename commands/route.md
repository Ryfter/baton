---
description: Recommend OR dispatch the optimal capability (tool or model) for a need — cheapest capable tier first ("optimal, not best"), now with LEARNED quality from your ratings + an LLM-judge. Reads tools.yaml + fleet.yaml + the routing journal/ratings. --run dispatches & verifies; --rate good|bad records whether the last run's output was good; --judge forces LLM-judge grading.
argument-hint: "<capability>" [--max-tier local|free|paid] [--local] [--run "<prompt>"] [--judge] | --rate good|bad [note]
---

# /route

Recommend **or dispatch** the optimal capability for a need. Reads the `tools.yaml`
(capability-specific tools + specialty models) and `fleet.yaml` (general models) registries,
ranks the candidates that serve `<capability>` cheapest cost-tier first, and breaks ties by
**learned quality** — a blend of your `--rate` thumbs, an LLM-judge score, and heuristic
pass-history (`~/.claude/routing-journal.jsonl` + `~/.claude/knowledge/universal/routing-ratings.jsonl`).
Cost tier always dominates; quality only reorders within a tier. **Without `--run`** it
recommends. **With `--run "<prompt>"`** it dispatches, verifies, escalates up the cost ladder,
and logs every attempt. **`--rate good|bad`** records whether the last run's output was good.

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
     $cands | Format-Table name, source, cost_tier,
         @{n='quality'; e={ '{0:0.00}' -f $_.quality }},
         @{n='provenance'; e={ $d=$_.quality_detail; $g=[int][math]::Round($d.user.rate*$d.user.n); "you {0}/{1} · judge {2:0.00}x{3} · heur {4:0.00}x{5}" -f $g, $d.user.n, $d.judge.rate, $d.judge.n, $d.heuristic.rate, $d.heuristic.n }},
         why -AutoSize
     Write-Host "Top pick: $($cands[0].name) — $($cands[0].why)"
     ```

   Note this is a recommendation; pass `--run "<prompt>"` to dispatch.

3. **With `--run "<prompt>"` (dispatch mode):**

   ```powershell
   . "$HOME/.claude/scripts/routing-dispatch.ps1"
   $opt = @{ Capability = '<capability>'; Prompt = '<prompt>' }
   if ($local)   { $opt['RequireLocal'] = $true }
   if ($maxTier) { $opt['MaxCostTier']  = '<tier>' }
   # Cost-optimal judging: on if --judge OR a free local judge model is available.
   if ($judge -or (Get-CheapestLocalModel)) { $opt['Judge'] = $true }
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

4. **With `--rate good|bad [note]` (rating mode):**

   ```powershell
   . "$HOME/.claude/scripts/routing-dispatch.ps1"
   $last = Get-LastRoutedAttempt
   if (-not $last) {
       Write-Host "No completed /route --run with a winning candidate to rate yet."
   } else {
       Add-CapabilityRating -Capability $last.capability -Candidate $last.candidate `
           -Source $last.source -Rating '<good|bad>' -Note '<note>'
       Write-Host "Recorded '<good|bad>' for $($last.candidate) on $($last.capability). It will weight future routing."
   }
   ```

   The rating lands in the GitHub-backed knowledge repo (`routing-ratings.jsonl`) — push it
   with the standing knowledge backup so it rolls to any machine.

5. **On any error** (missing `tools.yaml`/`fleet.yaml`), surface the thrown message and suggest
   `pwsh scripts\bootstrap.ps1 -Force` to deploy the registries.

## Arguments

$ARGUMENTS
