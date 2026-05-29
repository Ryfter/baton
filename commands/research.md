---
description: Research-phase ensemble. Requires an active job; fans out to the roster, writes to the job's phases/research/, and synthesizes. Wrapper over the ensemble primitive.
argument-hint: "<question>" [--providers a,b,c] [--tier free,local]
---

# /research

Run a research ensemble within the active job's research phase.

## Steps

1. **Require an active job.** Read `~/.claude/current-job.json` (via
   `Read-CurrentJob` from `~/.claude/scripts/job-lib.ps1`). If no `job_id`, stop
   with: *"No active job. Use /ensemble for an ad-hoc run, or /job-start to
   begin a job."*

2. **Phase check.** If the job's `current_phase` (from its manifest, via
   `Read-Manifest`) is not `research`, warn: *"Current phase is <x>; running
   research anyway."* Proceed.

3. **Resolve the roster** exactly as `/ensemble` does (explicit `--providers` >
   `--tier` > `Get-FleetResearchDefault`). Empty → stop with the same message.

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
   ```

4. **Output dir** is fixed to the job's research phase:

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"   # Read-CurrentJob + Read-Manifest live in job-lib
   $state = Read-CurrentJob
   $ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
   $outDir = Join-Path $HOME ".claude/jobs/$($state.job_id)/phases/research/ensemble-$ts"
   $outDir
   ```

5. **Run the ensemble + synthesize** exactly as `/ensemble` steps 4-6 (call
   `Invoke-FleetEnsemble` from `~/.claude/scripts/fleet-ensemble.ps1`, write
   `synthesis.md`, present it, report successes/failures).

6. **Prompt for a lesson** (non-blocking): *"Capture a lesson from this
   research? e.g. `/job-lesson knowledge \"<takeaway>\"`."*

## Arguments

$ARGUMENTS
