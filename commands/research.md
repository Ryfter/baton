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

5. **KB pre-fanout retrieval (Plan 8).** Before dispatching to the fleet,
   query the embedded KB for top-3 relevant chunks and prepend them as a
   "Relevant prior knowledge" section on each provider's prompt. Graceful
   no-op if the index is empty or kb-search errors.

   ```powershell
   . "$HOME/.claude/scripts/kb-lib.ps1"
   $kbHits = Invoke-KbSearch -Query '<question>' -K 3 -SnippetChars 600 2>$null
   if ($kbHits -and $kbHits.Count -gt 0) {
       $kbBlock = "Relevant prior knowledge (from this project's KB):`n`n"
       foreach ($h in $kbHits) {
           $snippet = ($h.text -replace "`r?`n", ' ').Trim()
           if ($snippet.Length -gt 600) { $snippet = $snippet.Substring(0, 600) + '…' }
           $kbBlock += "- $($h.source) [score $('{0:F2}' -f $h.score)]: $snippet`n"
       }
       $augmented = "$kbBlock`n---`n`n<question>"
   } else {
       $augmented = '<question>'
   }
   ```

6. **Run the ensemble + synthesize** exactly as `/ensemble` steps 4-6 (call
   `Invoke-FleetEnsemble` from `~/.claude/scripts/fleet-ensemble.ps1` with the
   `$augmented` prompt, write `synthesis.md`, present it, report
   successes/failures). When KB hits were prepended, mention which sources
   were used in the synthesis preamble.

7. **Prompt for a lesson** (non-blocking): *"Capture a lesson from this
   research? e.g. `/job-lesson knowledge \"<takeaway>\"`."*

## Arguments

$ARGUMENTS
