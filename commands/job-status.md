---
description: Show the active job's manifest plus recent journal entries tagged with this job ID.
argument-hint: (no arguments)
---

# /baton:job-status

You are showing the user the current job's status. Run:

```powershell
. "$HOME/.claude/scripts/job-lib.ps1"

$state = Read-CurrentJob
if (-not $state.job_id) {
    Write-Host "No active job. Use /baton:job-resume <id> or /baton:job-list to see available jobs." -ForegroundColor Yellow
    return
}

$jobDir = Join-Path $HOME ".claude/jobs/$($state.job_id)"
$mani = Read-Manifest -JobDir $jobDir
$brief = (Get-Content (Join-Path $jobDir 'brief.md') -Raw)

Write-Host "Job: $($mani.id)" -ForegroundColor Cyan
Write-Host "  title:   $($mani.title)"
Write-Host "  project: $($mani.project)"
Write-Host "  phase:   $($mani.current_phase)  (started $($mani.phase_started_at))"
Write-Host "  status:  $($mani.status)"
Write-Host "  sprints: $($mani.sprint_count)"
Write-Host ""
Write-Host "Recent journal entries (last 10 tagged with this job):" -ForegroundColor Cyan

$journal = Join-Path $HOME '.claude/model-routing-log.md'
if (Test-Path $journal) {
    $tag = "job:$($state.job_id)"
    Get-Content $journal | Where-Object { $_ -like "*$tag*" } | Select-Object -Last 10 | ForEach-Object {
        Write-Host "  $_"
    }
}
```

Then echo the output to the user. No transformation.
