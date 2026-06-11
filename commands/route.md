---
description: Recommend OR dispatch the optimal capability (tool or model) for a need — cheapest capable tier first ("optimal, not best"), with LEARNED quality from your ratings + an LLM-judge. --run dispatches & verifies; --rate good|bad records the last run; --judge forces judging; --calibrate dispatches ALL candidates on one prompt, judge-scores each, and collects a per-candidate rating to seed learning. Paid/frontier dispatch is rank-gated during prime hours (--rank 1 highest .. 5 lowest); lower-priority paid work defers to off-peak so premium spend happens only when it matters. --cascade drafts on cheap models and pays a frontier finisher only for the final delta — a judge-scored good-enough draft skips the frontier pass entirely.
argument-hint: "<capability>" [--max-tier local|free|paid] [--local] [--run "<prompt>"] [--rank <1-5>] [--judge] | --rate good|bad [note] | --calibrate "<capability>" "<prompt>" | --calibrate "<capability>" --rate "<cand>=good|bad ..." | --cascade "<prompt>" [--drafts N] [--good-enough 0.9] [--rank <1-5>]
---

# /baton:route

Recommend **or dispatch** the optimal capability for a need. Reads the `tools.yaml`
(capability-specific tools + specialty models) and `fleet.yaml` (general models) registries,
ranks the candidates that serve `<capability>` cheapest cost-tier first, and breaks ties by
**learned quality** — a blend of your `--rate` thumbs, an LLM-judge score, and heuristic
pass-history (`$BATON_HOME/routing-journal.jsonl` + `~/.claude/knowledge/universal/routing-ratings.jsonl`).
Cost tier always dominates; quality only reorders within a tier. **Without `--run`** it
recommends. **With `--run "<prompt>"`** it dispatches, verifies, escalates up the cost ladder,
and logs every attempt. **`--rate good|bad`** records whether the last run's output was good.

## Steps

1. **Parse `$ARGUMENTS`:** the first token is `<capability>`; optional `--max-tier local|free|paid`,
   `--local`, `--rank <1-5>` (paid-dispatch priority for the prime-hours gate, default `3`),
   `--run "<prompt>"`, and `--cascade "<prompt>"` (draft→finish mode) with its tuners
   `--drafts N` (how many cheap drafts to attempt) and `--good-enough X` (judge score at which
   a draft ships without the frontier pass). Empty capability → stop with:
   *"Usage: /baton:route \"<capability>\" [--max-tier local|free|paid] [--local] [--rank <1-5>] [--run \"<prompt>\"]"*.

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
   $rank = if ($rankArg) { [int]$rankArg } else { 3 }
   $opt['Rank'] = $rank   # enables the prime-hours gate on paid candidates
   # Cost-optimal judging: on if --judge OR a free local judge model is available.
   if ($judge -or (Get-CheapestLocalModel)) { $opt['Judge'] = $true }
   $outcome = Invoke-RoutedCapability @opt
   foreach ($a in $outcome.attempts) {
       $mark = if ($a.passed) { 'PASS' } else { 'fail' }
       Write-Host ("  {0,-5} {1,-22} {2}  ({3}s)  {4}" -f $a.cost_tier, $a.candidate, $mark, $a.duration_s, $a.reason)
   }
   $gated = @($outcome.attempts | Where-Object { $_.gate -eq 'defer' -or $_.gate -eq 'ask' })
   if ($gated.Count -gt 0) {
       Write-Host ""
       Write-Host "Prime-hours: $($gated.Count) paid candidate(s) gated this run (rank $rank). To pay premium now, re-run with --rank 1; to stay cheap, wait for off-peak or use --max-tier free."
   }
   ```

   Then report the outcome by `$outcome.status`:
   - `passed` → state the winner and show `$outcome.result.stdout`.
   - `escalate-to-conductor` → tell the user every candidate failed (list the per-attempt
     reasons above) and that it is escalating to the conductor (you, Claude) to do the task
     directly or pick a model manually.
   - `no-candidate` → no candidate serves `<capability>`; list `Get-KnownCapabilities`.

   **Prime-hours ask (interactive):** when a rank-1 or rank-2 paid candidate would be the pick
   during a peak window — the library surfaces this as a gate decision of `ask` on the attempt —
   ASK the user before dispatching it, e.g. *"This will use the paid model `<name>` during peak
   hours — proceed? (cheaper local/free options failed.)"* Spending premium during peak is a real
   cost decision, so confirm it rather than charging ahead. Unattended callers (the backlog or the
   autonomous run-loop) skip this prompt because the library already resolves `ask` to its rank
   default for non-interactive dispatch.

   Finish with: *"Logged $($outcome.attempts.Count) attempt(s) to $BATON_HOME/routing-journal.jsonl."*

4. **With `--cascade "<prompt>"` (draft→finish mode, Engine Slice B):**

   ```powershell
   . "$HOME/.claude/scripts/routing-cascade.ps1"
   $opt = @{ Capability = '<capability>'; Prompt = '<prompt>' }
   if ($draftsArg)     { $opt['DraftCount'] = [int]$draftsArg }
   if ($goodEnoughArg) { $opt['GoodEnough'] = [double]$goodEnoughArg }
   if ($local)         { $opt['RequireLocal'] = $true }
   if ($maxTier)       { $opt['MaxCostTier']  = '<tier>' }
   $opt['Rank'] = if ($rankArg) { [int]$rankArg } else { 3 }
   $out = Invoke-CapabilityCascade @opt
   foreach ($a in $out.draft_attempts) {
       $mark = if ($a.passed) { 'PASS' } else { 'fail' }
       Write-Host ("  draft  {0,-5} {1,-22} {2}  score {3:0.00}  ({4}s)  {5}" -f $a.cost_tier, $a.candidate, $mark, $a.score, $a.duration_s, $a.reason)
   }
   if ($out.finish_attempt) {
       $fa = $out.finish_attempt
       $mark = if ($fa.passed) { 'PASS' } else { 'fail' }
       Write-Host ("  finish {0,-5} {1,-22} {2}  score {3:0.00}  ({4}s)  {5}" -f $fa.cost_tier, $fa.candidate, $mark, $fa.score, $fa.duration_s, $fa.reason)
   }
   ```

   Then report by `$out.status`, always closing with the cost line:
   - `draft-sufficient` → *"Draft from `<winner>` scored ≥ the good-enough bar — shipped as-is."* Show `$out.result.stdout`. Cost line: **`frontier spend: none (draft-sufficient)`**.
   - `finished` → *"`<winner>` finished the best draft."* Show `$out.result.stdout`. Cost line: **`frontier spend: 1 finisher pass (<winner>)`**.
   - `finisher-deferred` → the prime-hours gate deferred the paid finisher; show the best draft as a PROVISIONAL result and say re-running off-peak (or `--rank 1`) will finish it. Cost line: **`frontier spend: none (finisher deferred to off-peak)`**.
   - `no-finisher` → no finisher-eligible candidate under the current constraints (e.g. `--local`); show the best draft if one passed.
   - `no-candidate` → nothing serves `<capability>`; list `Get-KnownCapabilities`.
   - `escalate-to-conductor` → drafts and finisher both failed; escalate to the conductor (you, Claude) with the per-attempt reasons above.

   **Prime-hours ask (interactive):** same semantics as `--run` — an `ask` gate on the
   finisher attempt means confirm with the user before treating the deferral as final.

5. **With `--rate good|bad [note]` (rating mode):**

   ```powershell
   . "$HOME/.claude/scripts/routing-dispatch.ps1"
   $last = Get-LastRoutedAttempt
   if (-not $last) {
       Write-Host "No completed /baton:route --run with a winning candidate to rate yet."
   } else {
       Add-CapabilityRating -Capability $last.capability -Candidate $last.candidate `
           -Source $last.source -Rating '<good|bad>' -Note '<note>'
       Write-Host "Recorded '<good|bad>' for $($last.candidate) on $($last.capability). It will weight future routing."
   }
   ```

   The rating lands in the GitHub-backed knowledge repo (`routing-ratings.jsonl`) — push it
   with the standing knowledge backup so it rolls to any machine.

6. **With `--calibrate "<capability>" "<prompt>"` (calibration — Phase 1: sample & judge):**

   Dispatches **every** candidate for the capability on one prompt, judge-scores each, and shows
   them side-by-side so you can rate them. Default tier cap is `free` (local+free); include paid
   candidates only with an explicit `--max-tier paid`.

   ```powershell
   . "$HOME/.claude/scripts/routing-calibrate.ps1"
   $tier = if ($maxTier) { $maxTier } else { 'free' }   # calibration defaults to free, not paid
   $prev = @{ Capability = '<capability>'; MaxCostTier = $tier }
   if ($local) { $prev['RequireLocal'] = $true }
   $preview = Select-Capability @prev
   if (-not $preview -or $preview.Count -eq 0) {
       Write-Host "No candidate serves '<capability>'. Known: $((Get-KnownCapabilities) -join ', ')"
   } else {
       Write-Host ("Calibrating <capability>: will dispatch {0} candidate(s) (tiers: {1})." -f `
           $preview.Count, (($preview.cost_tier | Sort-Object -Unique) -join ','))
       $opt = @{ Capability = '<capability>'; Prompt = '<prompt>'; MaxCostTier = $tier }
       if ($local) { $opt['RequireLocal'] = $true }
       # Cost-optimal judging: on if --judge OR a free local judge model is available.
       if ($judge -or (Get-CheapestLocalModel)) { $opt['Judge'] = $true }
       $cal = Invoke-CapabilityCalibration @opt
       $cal.candidates | Format-Table `
           @{n='candidate'; e={$_.candidate}}, @{n='tier'; e={$_.cost_tier}},
           @{n='judge'; e={ '{0:0.00}' -f $_.score }},
           @{n='provenance'; e={ $d=$_.quality_detail; if($d){ $g=[int][math]::Round($d.user.rate*$d.user.n); "you {0}/{1} · judge {2:0.00}x{3} · heur {4:0.00}x{5}" -f $g, $d.user.n, $d.judge.rate, $d.judge.n, $d.heuristic.rate, $d.heuristic.n } else { '—' } }},
           @{n='excerpt'; e={$_.excerpt}} -AutoSize -Wrap
       $names = ($cal.candidates | ForEach-Object { "$($_.candidate)=good" }) -join ' '
       Write-Host ""
       Write-Host "Rate them (edit good/bad), then run:"
       Write-Host "  /baton:route --calibrate `"<capability>`" --rate `"$names`""
       Write-Host ("Logged {0} calibration attempt(s) to $BATON_HOME/routing-journal.jsonl." -f $cal.candidates.Count)
   }
   ```

   Show the table to the user, then the pre-filled rate command so they only flip good→bad where
   an output was poor.

7. **With `--calibrate "<capability>" --rate "<cand>=good|bad ..."` (calibration — Phase 2: record verdicts):**

   Detected when both `--calibrate` and `--rate` are present. Records one rating per candidate.

   ```powershell
   . "$HOME/.claude/scripts/routing-calibrate.ps1"
   $res = Add-CalibrationRatings -Capability '<capability>' -Spec '<spec>'
   Write-Host ("Recorded {0} rating(s) ({1} skipped). They will weight future routing." -f $res.applied, $res.skipped)
   ```

   The ratings land in the GitHub-backed knowledge repo (`routing-ratings.jsonl`) — push it with
   the standing knowledge backup so they roll to any machine.

8. **On any error** (missing `tools.yaml`/`fleet.yaml`), surface the thrown message and suggest
   `pwsh scripts\bootstrap.ps1 -Force` to deploy the registries.

## Arguments

$ARGUMENTS
