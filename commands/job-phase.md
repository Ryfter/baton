---
description: Show or transition the current job's phase. `next` advances along research→design→code.sprint-N→review→… Loop-backs use explicit phase names. `done` closes the job.
argument-hint: (no arg | next | back | done | <explicit-phase-name>)
---

# /baton:job-phase

Manage the active job's phase.

## Steps

1. **Read state.** If no active job, print *"No active job. Use /baton:job-resume or
   /baton:job-list."* and stop.

2. **Parse `$ARGUMENTS`:**
   - empty → show current phase + what `next` would resolve to. Stop.
   - `next`  → compute next phase via `Get-NextPhase`. If current is `review`,
     prompt: *"Start `code.sprint-N+1` or `/baton:job-phase done`?"* and wait for
     answer before transitioning.
   - `back`  → compute prev phase via `Get-PrevPhase`. If null (already at
     `research`), error: *"Already at the first phase."*
   - `done`  → set status=done, clear state file.
   - any other token → treat as explicit phase name. Validate against:
     `research`, `design`, `code.sprint-<N>` where N is a positive int,
     `review`, `done`. If invalid, error with list. Record as `loop-back` in
     phase-log if the named phase is "earlier" in the sequence than the
     current.

3. **Trigger OTel parser BEFORE flipping** (so events accumulated during the
   just-ended phase get tagged with the old phase):

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/parse-otel.ps1" 2>&1 | Out-Null
   ```

   If it fails non-zero, warn but continue.

4. **Atomic transition** (manifest + state file + phase-log + journal line):

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $state = Read-CurrentJob
   $jobDir = Join-Path $HOME ".claude/jobs/$($state.job_id)"
   $mani = Read-Manifest -JobDir $jobDir
   $oldPhase = $mani.current_phase
   $newPhase = '<RESOLVED_PHASE>'    # from step 2

   $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $mani.current_phase = $newPhase
   $mani.phase_started_at = $now
   $mani.last_updated = $now
   if ($newPhase -match '^code\.sprint-(\d+)$') {
       $n = [int]$matches[1]
       if ($n -gt $mani.sprint_count) { $mani.sprint_count = $n }
   }
   if ($newPhase -eq 'done') { $mani.status = 'done' }
   Write-Manifest -JobDir $jobDir -Manifest $mani

   $kind = if ('<LOOP_BACK>' -eq '1') { 'loop-back' } else { 'transition' }
   Append-PhaseLog -JobDir $jobDir -Kind $kind -Detail "$oldPhase → $newPhase"

   if ($newPhase -eq 'done') {
       Clear-CurrentJob
       # Clear the run-feed pointer (idempotent); the run record survives as history.
       . "$HOME/.claude/scripts/runs-lib.ps1"
       Clear-CurrentRun
   } else {
       Write-CurrentJob -JobId $state.job_id -Phase $newPhase
   }

   # Journal line for the dashboard's phase-transition view
   $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $line = "$ts | dashboard | phase-transition | $oldPhase → $newPhase | job:$($state.job_id)"
   Add-Content -Path (Join-Path $HOME '.claude/model-routing-log.md') -Value $line
   ```

5. **Prompt for lessons** at `next` and `done` transitions only:
   *"Any lessons to record before moving on? (use `/baton:job-lesson <category>
   \"<text>\"`)"*. Don't block — just remind.

6. **Decision retro** (for `done` transitions only): list the decisions this job
   touched and prompt for late feedback. Non-blocking. Capture the just-closed
   job's id (`$state.job_id` BEFORE `Clear-CurrentJob`) for the lookup.

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   . "$HOME/.claude/scripts/decisions-lib.ps1"
   $jobId = '<JOB_ID>'    # captured before the state file was cleared
   $proj = Resolve-ProjectId
   $decs = Read-Decisions -Project $proj -Job $jobId
   if ($decs.Count -gt 0) {
       Write-Host ""
       Write-Host "This job touched $($decs.Count) decision(s):" -ForegroundColor Cyan
       foreach ($d in $decs) {
           $flagNote = if ($d.flag -ne 'null') { " [$($d.flag)]" } else { '' }
           Write-Host "  $($d.id) ($($d.confidence)) — $($d.title)$flagNote"
       }
       Write-Host "Any retro feedback? Use /baton:decision-feedback <id> ""<text>"" --outcome worked|didnt|mixed." -ForegroundColor Yellow
       Write-Host "(Silence = they worked.)" -ForegroundColor DarkGray
   }
   ```

## Arguments

$ARGUMENTS
