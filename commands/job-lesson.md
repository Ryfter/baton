---
description: Capture a lesson into the active job's lessons.md and the journal. Categories: routing, user-pref, reasoning, mistake, winner, convention, decision, architecture, knowledge.
argument-hint: <category> "<text>" [--scope universal|project]
---

# /baton:job-lesson

Append a lesson to the active job's `lessons.md` + write a `lesson` line to the
journal so the dashboard can show it.

## Steps

1. **Parse `$ARGUMENTS`:** first token is the category, then a quoted string is
   the text, then an optional `--scope universal|project`.

2. **Validate category.** If invalid, show the valid list and stop.

3. **Confirm active job.** If no active job, error: *"No active job — use
   /baton:job-resume."*

4. **Run:**

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $category = '<CATEGORY>'
   $text     = '<TEXT>'         # already single-quote-escaped
   $scope    = if ('<SCOPE>') { '<SCOPE>' } else { Get-LessonDefaultScope $category }

   if (-not (Test-LessonCategory $category)) {
       Write-Host "Invalid category. Valid: $((Get-LessonCategories) -join ', ')" -ForegroundColor Red
       return
   }

   $state = Read-CurrentJob
   if (-not $state.job_id) {
       Write-Host "No active job." -ForegroundColor Red
       return
   }
   $jobDir = Join-Path $HOME ".claude/jobs/$($state.job_id)"

   # Append to job lessons.md
   Append-LessonToJob -JobDir $jobDir -Phase $state.phase -Category $category -Scope $scope -Text $text

   # Append a `lesson` line to the journal
   $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $safeText = ($text -replace '\|', '¦' -replace "`r?`n", ' ').Trim()
   $journalLine = "$ts | lesson | $category | `"$safeText`" | job:$($state.job_id) | phase:$($state.phase)"
   Add-Content -Path (Join-Path $HOME '.claude/model-routing-log.md') -Value $journalLine

   Write-Host "Lesson recorded ($category, scope=$scope)." -ForegroundColor Green
   ```

5. Echo confirmation to the user.

## Arguments

$ARGUMENTS
