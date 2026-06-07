---
description: Start a new job. Creates ~/.claude/jobs/<id>/ with manifest, brief, phase-log; sets ~/.claude/current-job.json so the hook starts phase-tagging tool calls.
argument-hint: "<brief>" [--project <id> | --no-project]
---

# /job-start

You are starting a new orchestrator job. The brief and optional flags are in
`$ARGUMENTS`.

## Steps

1. **Check no job is active.** Read `~/.claude/current-job.json`. If `job_id`
   is set, ask the user: *"Job `<id>` is active. Suspend and start new, or
   `/job-resume` and continue?"* — wait for their answer before proceeding.

2. **Parse arguments.** The brief is the quoted string (or first arg if
   unquoted). Flags: `--project <id>` (override), `--no-project` (skip
   detection).

3. **Run this PowerShell** (substitute values for `<BRIEF>`, `<PROJECT_FLAG>`):

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"

   $brief   = '<BRIEF>'                     # the user's brief, single-quote-escaped
   $today   = Get-Date -Format 'yyyy-MM-dd'
   $slug    = ConvertTo-JobSlug $brief
   $jobId   = "j-$today-$slug"
   $jobDir  = Join-Path $HOME ".claude/jobs/$jobId"

   # Collision handling
   $suffix = 2
   while (Test-Path $jobDir) {
       $jobDir = Join-Path $HOME ".claude/jobs/$jobId-$suffix"
       $suffix++
   }
   $jobId = Split-Path -Leaf $jobDir

   # Project resolution
   $project = $null
   if ('<PROJECT_FLAG>' -eq '--no-project') {
       $project = $null
   } elseif ('<PROJECT_FLAG>' -match '^--project (.+)$') {
       $project = $matches[1]
   } else {
       $project = Resolve-ProjectId
   }

   $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   New-Item -ItemType Directory -Path $jobDir | Out-Null
   New-Item -ItemType Directory -Path (Join-Path $jobDir 'phases') | Out-Null
   Set-Content -Path (Join-Path $jobDir 'brief.md') -Value "# Brief`n`n$brief" -Encoding utf8NoBOM
   Set-Content -Path (Join-Path $jobDir 'lessons.md') -Value "# Lessons — $jobId`n" -Encoding utf8NoBOM

   Write-Manifest -JobDir $jobDir -Manifest @{
       id = $jobId; title = $brief; created_at = $now
       status = 'active'; project = $project
       current_phase = 'research'; phase_started_at = $now
       sprint_count = 0; last_updated = $now
   }
   Append-PhaseLog -JobDir $jobDir -Kind 'created' -Detail 'research'
   Write-CurrentJob -JobId $jobId -Phase 'research'

   # Point the run-feed at this job so the PostToolUse hook narrates the
   # conductor's session into it (seeds the run record as 'running').
   . "$HOME/.claude/scripts/runs-lib.ps1"
   Set-CurrentRun -Id $jobId -Name $brief -Project $project

   Write-Host ""
   Write-Host "Job started: $jobId" -ForegroundColor Green
   Write-Host "  project: $project"
   Write-Host "  phase:   research"
   Write-Host "  folder:  $jobDir"
   ```

4. **After running**, echo to the user a one-line summary plus the natural
   first question: *"What are you actually trying to solve?"*.

## Arguments

$ARGUMENTS
