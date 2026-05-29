---
description: Fan a prompt out to multiple fleet members concurrently, then synthesize their responses. Job-optional. Roster from --providers, --tier, or fleet.yaml research_default.
argument-hint: "<prompt>" [--providers a,b,c] [--tier free,local]
---

# /ensemble

Run a concurrent multi-model ensemble and synthesize the results.

## Steps

1. **Parse `$ARGUMENTS`:** the quoted string is the prompt; optional
   `--providers a,b,c` (comma list) and `--tier free,local` (comma list of
   paid/free/local).

2. **Resolve the roster** (first match wins):
   - if `--providers` given → that list (drop unknown/disabled with a warning)
   - else if `--tier` given → all enabled providers whose `cost_tier` is in the list
   - else → `Get-FleetResearchDefault`
   If the resolved roster is empty, stop with:
   *"No providers resolved. Check --providers/--tier or research_default in fleet.yaml."*

   ```powershell
   . "$HOME/.claude/scripts/fleet-lib.ps1"
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
   if (-not $roster.Count) { Write-Host "No providers resolved." -ForegroundColor Red; return }
   $roster -join ','
   ```

3. **Pick the output dir.** If a job is active (`~/.claude/current-job.json` has
   a job_id), use `<job>/phases/research/ensemble-<timestamp>/`; else
   `~/.claude/ensembles/<timestamp>/`. Timestamp format `yyyy-MM-ddTHH-mm-ss`.

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"   # Read-CurrentJob lives in job-lib
   $ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
   $state = Read-CurrentJob
   if ($state.job_id) {
       $outDir = Join-Path $HOME ".claude/jobs/$($state.job_id)/phases/research/ensemble-$ts"
   } else {
       $outDir = Join-Path $HOME ".claude/ensembles/$ts"
   }
   $outDir
   ```

4. **Run the ensemble:**

   ```powershell
   . "$HOME/.claude/scripts/fleet-ensemble.ps1"
   $manifest = Invoke-FleetEnsemble -Providers @(<roster>) -Prompt '<prompt>' -OutputDir '<outDir>'
   $manifest | Format-Table -AutoSize
   ```

5. **Synthesize.** Read each `<outDir>/<provider>.md`. Write a synthesis to
   `<outDir>/synthesis.md` covering: where the models AGREE, where they DIVERGE
   (and why it matters), any UNIQUE insight only one surfaced, and a RECOMMENDED
   direction. Do not use a rigid template — structure it to fit the content.
   Skip any provider whose file starts with `[ENSEMBLE ERROR]` or
   `[ENSEMBLE TIMEOUT]`, but note the gap. If ALL failed, skip synthesis and
   suggest `/fleet doctor`.

6. **Present** the synthesis to the user and report which providers
   succeeded/failed (from the manifest).

## Arguments

$ARGUMENTS
