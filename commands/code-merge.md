---
description: Review and (optionally) apply the merge plan from /baton:code-parallel. Surfaces likely conflicts via files_touched overlap before applying.
argument-hint: "[--apply] [--from t3]"
---

# /baton:code-merge

Read the latest `parallel-<ts>/manifest.json`, present a merge plan in dependency order, and (with `--apply`) execute it.

## Steps

1. **Require active job.** Resolve sprint.

2. **Locate the most recent `parallel-<ts>/` directory** under the sprint.

   ```powershell
   . "$HOME/.claude/scripts/code-lib.ps1"
   . "$HOME/.claude/scripts/job-lib.ps1"
   $state = Read-CurrentJob
   $sprint = if ($state.phase -match '^code\.sprint-\d+$') { $state.phase } else { 'code.sprint-1' }
   $sprintDir = Join-Path $HOME ".claude/jobs/$($state.job_id)/phases/$sprint"
   $latest = Get-ChildItem -Path $sprintDir -Directory -Filter 'parallel-*' | Sort-Object Name -Descending | Select-Object -First 1
   if (-not $latest) { Write-Host "No parallel run found. Run /baton:code-parallel first." -ForegroundColor Red; return }
   $mfPath = Join-Path $latest.FullName 'manifest.json'
   $mf = Read-CodeParallelManifest -Path $mfPath
   $stPath = Join-Path $sprintDir 'subtasks.json'
   $subs = Read-CodeSubtasksFile -Path $stPath
   ```

3. **Refresh worktree status** (commits_ahead, files_changed, dirty) — the
   recorded values may be stale if the user committed inside a worktree.

   ```powershell
   foreach ($r in $mf.results) {
       if ($r.status -eq 'ok' -and (Test-Path $r.worktree)) {
           $st = Get-CodeWorktreeStatus -WorktreePath $r.worktree -BaseBranch 'master'
           $r | Add-Member -NotePropertyName _live_ahead -NotePropertyValue $st.commits_ahead -Force
           $r | Add-Member -NotePropertyName _live_files -NotePropertyValue $st.files_changed -Force
           $r | Add-Member -NotePropertyName _live_dirty -NotePropertyValue $st.dirty -Force
       }
   }
   ```

4. **Order tasks** by dependency.

   ```powershell
   $ordered = Resolve-CodeTaskOrder -Tasks $subs.tasks
   ```

5. **Surface likely conflicts** via `files_touched` overlap.

   ```powershell
   $conflicts = Get-CodeFilesTouchedConflicts -OrderedTasks $ordered
   ```

6. **Parse `--apply`** and `--from <task-id>` from `$ARGUMENTS`.

7. **Present the merge plan.** For each task in order:
   - id, title, status, commits_ahead (live), files_changed (live), dirty?
   - Any conflict pair this task appears in (overlap files)
   - The subagent's `summary`
   Then print the conflicts table separately so it stands out.

8. **If `--apply` is NOT set:** stop here. User reviews; reruns with `--apply`.

9. **If `--apply` IS set:** execute in order, starting at `--from <id>` if given.
   For each `ok` task with `commits_ahead > 0`:

   ```powershell
   $branch = $r.branch
   # Cherry-pick is default — clean linear history per task
   & git cherry-pick "$branch~$($r._live_ahead)..$branch"
   if ($LASTEXITCODE -ne 0) {
       Write-Host "[CONFLICT] task '$($r.task_id)' — resolve manually, then rerun /baton:code-merge --apply --from $($r.task_id)" -ForegroundColor Yellow
       return
   }
   ```

   Skip `empty`, `failed`, `blocked`, and `dirty` (uncommitted state in
   worktree) — call them out. Stop on the first conflict.

10. **After successful application:** print the cleanup hint
    (do NOT auto-prune — worktree removal is destructive):

    ```
    Cleanup when ready:
      git worktree remove <path>      # per task
      git branch -D <branch>          # per task
    ```

## Arguments

$ARGUMENTS
