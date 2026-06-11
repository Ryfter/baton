---
description: Resume a previously-started job. Reads its manifest, sets the current-job state file so the hook resumes phase-tagging.
argument-hint: <job-id>
---

# /baton:job-resume

Resume a job by ID. The ID is in `$ARGUMENTS` (e.g.,
`j-2026-05-26-feature-flags`).

## Steps

1. **Validate.** If `$ARGUMENTS` is empty, show output of `/baton:job-list --active`
   and ask which one to resume.

2. **Check no other job is active.** Read `$BATON_HOME/current-job.json`. If
   another job is set, prompt: *"Job `<other>` is active. Switch?"* — wait for
   confirmation.

3. **Run:**

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $jobId = '<JOB_ID>'
   $jobDir = Join-Path (Get-BatonHome) "jobs/$jobId"
   if (-not (Test-Path $jobDir)) {
       Write-Host "No such job: $jobId" -ForegroundColor Red
       return
   }
   $mani = Read-Manifest -JobDir $jobDir
   if (-not $mani -or -not $mani.current_phase) {
       Write-Host "Manifest missing or corrupted for $jobId" -ForegroundColor Red
       return
   }
   Write-CurrentJob -JobId $mani.id -Phase $mani.current_phase
   Write-Host "Resumed $($mani.id)" -ForegroundColor Green
   Write-Host "  phase:   $($mani.current_phase)"
   Write-Host "  project: $($mani.project)"
   ```

4. Echo a short status to the user.

## Arguments

$ARGUMENTS
