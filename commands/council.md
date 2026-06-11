---
description: LLM Council — two-round deliberation where each member answers, then reads the other members' answers and refines. Claude chairs the synthesis. Job-optional. Council size capped at 5.
argument-hint: "<question>" [--providers a,b,c] [--tier free,local]
---

# /baton:council

Run a two-round LLM Council on a high-stakes question.

## Steps

1. **Parse `$ARGUMENTS`:** quoted question + optional `--providers a,b,c` and `--tier free,local`.

2. **Resolve roster** (same precedence as `/baton:ensemble`):
   - if `--providers` given → that list (drop unknown/disabled with a warning)
   - else if `--tier` given → all enabled providers whose `cost_tier` is in the list
   - else → `Get-FleetResearchDefault`
   Cap at 5 members. Below 2 members → stop with: *"Council needs at least 2 members for deliberation."*

   ```powershell
   . "$HOME/.claude/scripts/fleet-lib.ps1"
   . "$HOME/.claude/scripts/council-lib.ps1"
   $limits = Get-CouncilLimits
   $explicit = @( <comma-split of --providers, or empty> )
   $tiers    = @( <comma-split of --tier, or empty> )
   if ($explicit.Count) {
       $all = Read-Fleet
       $roster = @($explicit | Where-Object { $n = $_; ($all | Where-Object { $_.name -eq $n -and $_.enabled -eq $true }) })
   } elseif ($tiers.Count) {
       $roster = @((Read-Fleet | Where-Object { $_.enabled -eq $true -and $tiers -contains $_.cost_tier }).name)
   } else {
       $roster = @(Get-FleetResearchDefault)
   }
   if ($roster.Count -gt $limits.max) { $roster = $roster[0..($limits.max - 1)]; Write-Warning "Council capped at $($limits.max) members." }
   if ($roster.Count -lt 2) { Write-Host "Council needs at least 2 members." -ForegroundColor Red; return }
   ```

3. **Output dir.** Job-bound → `<job>/phases/research/council-<ts>/`; standalone → `$BATON_HOME/ensembles/council-<ts>/`.

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
   $state = Read-CurrentJob
   if ($state.job_id) {
       $outDir = Join-Path (Get-BatonHome) "jobs/$($state.job_id)/phases/research/council-$ts"
   } else {
       $outDir = Join-Path (Get-BatonHome) "ensembles/council-$ts"
   }
   $r1Dir = Join-Path $outDir 'round1'
   $r2Dir = Join-Path $outDir 'round2'
   ```

4. **Round 1 — answer:**

   ```powershell
   . "$HOME/.claude/scripts/fleet-ensemble.ps1"
   $r1Tasks = Build-CouncilR1Tasks -Question '<question>' -Providers @(<roster>)
   $m1 = Invoke-FleetEnsembleTasks -Tasks $r1Tasks -OutputDir $r1Dir
   $m1 | Format-Table label, status, duration_s -AutoSize
   ```

5. **Quorum check.** If fewer than 2 members survived R1 (`status -eq 'ok'`),
   abort: print `[COUNCIL ABORT] insufficient quorum` and skip R2 + synthesis.
   Suggest the user inspect `$r1Dir`, run `/baton:fleet doctor`, or retry with a
   different roster.

   ```powershell
   $survivors = Get-CouncilR1Survivors -R1Manifest $m1
   if ($survivors.Count -lt $limits.quorum) {
       Write-Host "[COUNCIL ABORT] insufficient quorum ($($survivors.Count)/$($limits.quorum) survived R1)." -ForegroundColor Red
       return
   }
   ```

6. **Round 2 — critique + refine.** All roster members get R2 prompts (a failed-R1 member still gets a second chance, with the surviving peers' content for context).

   ```powershell
   $r2Tasks = Build-CouncilR2Tasks -Question '<question>' -Providers @(<roster>) -R1Dir $r1Dir
   $m2 = Invoke-FleetEnsembleTasks -Tasks $r2Tasks -OutputDir $r2Dir
   $m2 | Format-Table label, status, duration_s -AutoSize
   ```

7. **Chair synthesis (Claude).** Read every `$r1Dir/<member>.md` and `$r2Dir/<member>.md`. Write `$outDir/synthesis.md` with this structure:
   - **Council composition** — who served, who failed at which round
   - **Convergence** — where the council aligned (especially after R2)
   - **Disagreements** — and chair's judgment on which side is stronger
   - **Mind-changes (R1 → R2)** — deltas worth surfacing
   - **Chair's recommended answer** — the actionable conclusion
   Skip files that begin with `[ENSEMBLE ERROR]` or `[ENSEMBLE TIMEOUT]`, but call them out in "Council composition".

8. **Present** the synthesis. Report R1 and R2 success/failure per member.

## Arguments

$ARGUMENTS
