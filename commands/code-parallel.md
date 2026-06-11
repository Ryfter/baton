---
description: Dispatch one Agent subagent per subtask in isolated git worktrees. Reads <job>/phases/<sprint>/subtasks.json; writes parallel-<ts>/manifest.json.
argument-hint: "[--only t1,t2]"
---

# /baton:code-parallel

Dispatch the subtasks from `subtasks.json` as parallel Agent subagents in isolated worktrees.

## Steps

1. **Require an active job.** Read state; resolve sprint (same logic as
   `/baton:code-decompose`).

2. **Read subtasks.json.**

   ```powershell
   . "$HOME/.claude/scripts/code-lib.ps1"
   . "$HOME/.claude/scripts/job-lib.ps1"
   $state = Read-CurrentJob
   $sprint = if ($state.phase -match '^code\.sprint-\d+$') { $state.phase } else { 'code.sprint-1' }
   $stPath = Join-Path (Get-BatonHome) "jobs/$($state.job_id)/phases/$sprint/subtasks.json"
   if (-not (Test-Path $stPath)) { Write-Host "Run /baton:code-decompose first." -ForegroundColor Red; return }
   $subs = Read-CodeSubtasksFile -Path $stPath
   ```

3. **Filter `--only`** if present (`--only t1,t3`) — only dispatch those ids.

4. **Topological-sort + group by dependency wave.** Independent tasks form
   wave 1 (dispatched in parallel). Tasks whose `depends_on` are all in wave 1
   form wave 2, and so on.

   ```powershell
   $ordered = Resolve-CodeTaskOrder -Tasks $subs.tasks
   # Group into waves: a task joins the earliest wave where all its deps are in earlier waves.
   ```

5. **Pick the output dir** + write a starter manifest.

   ```powershell
   $outDir = Get-CodeOutputDir -JobId $state.job_id -Sprint $sprint
   New-Item -ItemType Directory -Force -Path $outDir | Out-Null
   ```

6. **For each wave:** dispatch one `Agent` tool call per task — ALL in one
   message so the harness runs them concurrently. Per-task prompt:

   ```
   You are implementing one subtask of feature "<Feature>". Spec excerpt:
   <relevant section from $subs.spec_path>

   Task: <task.id> — <task.title>
   <task.description>

   Files you will likely create/edit: <task.files_touched>
   Dependencies already completed: <ids+brief from prior waves>

   Contract:
   - Work in this worktree only.
   - Make small, focused commits with clear messages.
   - When done, output a one-paragraph summary ending with: SUMMARY:<your summary>
   ```

   Pass `subagent_type: general-purpose`, `isolation: worktree`,
   `description: "<task.id>: <short title>"`.

7. **Collect results** from each Agent call:
   - `worktree` (path returned by the harness)
   - `branch` (returned by the harness)
   - `summary` (parsed from agent output after `SUMMARY:`)
   - If no changes were made, the Agent tool result will say so → mark `empty`.
   - On error, mark `failed`; downstream waves that depend on it become `blocked`.

8. **Probe each worktree** for current state:

   ```powershell
   $results = @()
   foreach ($wave in $waves) {
       foreach ($task in $wave) {
           $st = Get-CodeWorktreeStatus -WorktreePath $task._worktree -BaseBranch 'master'
           $results += @{
               task_id = $task.id; worktree = $task._worktree; branch = $task._branch
               summary = $task._summary; status = $task._status
               commits_ahead = $st.commits_ahead; files_changed = $st.files_changed
           }
       }
   }
   Write-CodeParallelManifest -Path (Join-Path $outDir 'manifest.json') -Results $results
   ```

9. **Append journal line + print summary table.**

   ```powershell
   $ok  = @($results | Where-Object { $_.status -eq 'ok' }).Count
   $err = @($results | Where-Object { $_.status -in 'failed','blocked' }).Count
   Write-CodeJournalLine -JobId $state.job_id -Sprint $sprint `
       -TaskCount $results.Count -OkCount $ok -ErrCount $err
   $results | Format-Table task_id, status, commits_ahead, files_changed -AutoSize
   ```

10. **Hand off.** Print: *"Run /baton:code-merge to review the integration plan."*

## Arguments

$ARGUMENTS
