---
description: Decompose a feature spec into independent subtasks for parallel implementation. Writes <job>/phases/<sprint>/subtasks.json. Requires confirmation before write.
argument-hint: "[<path-to-spec>]"
---

# /code-decompose

Decompose a finalized feature spec into a DAG of subtasks for `/code-parallel`.

## Steps

1. **Require an active job.** Read `~/.claude/current-job.json` via
   `Read-CurrentJob`. No job → stop with: *"No active job. Run /job-start first."*

2. **Resolve the spec path.**
   - If `$ARGUMENTS` is non-empty and points to an existing file → use it.
   - Else look in `<job>/phases/design/` for the most recent `.md` file. Use it.
   - Else stop with: *"No spec found. Pass a path or place one in <job>/phases/design/."*
   Read the spec.

3. **Resolve sprint.** From `Read-CurrentJob`'s `phase`; if it doesn't match
   `code.sprint-N`, warn and use `code.sprint-1`.

4. **Decompose** (Claude's judgment): break the feature into N small,
   independently-implementable subtasks. For each:
   - `id` — short kebab id (`t1`, `t2`, … or semantic like `backend-api`)
   - `title` — one-line scope
   - `description` — 2-3 sentences of what to build + acceptance criteria
   - `files_touched` — best-effort list of files the task will create/edit
   - `depends_on` — array of task ids this one needs first; empty preferred
   Aim for: each task ≤ a few hundred LOC of changes, scope unambiguous,
   independent unless a real ordering dep exists. Cycles are not allowed.

5. **Confirm before writing.** Present the task list (id, title, depends_on,
   files_touched) to the user and ask: *"Write this to subtasks.json? [Y/n]"*
   On `n` → stop without writing; user can re-run after editing context.

6. **Write the file.**

   ```powershell
   . "$HOME/.claude/scripts/code-lib.ps1"
   . "$HOME/.claude/scripts/job-lib.ps1"
   $state = Read-CurrentJob
   $sprint = if ($state.phase -match '^code\.sprint-\d+$') { $state.phase } else { 'code.sprint-1' }
   $path = Join-Path $HOME ".claude/jobs/$($state.job_id)/phases/$sprint/subtasks.json"
   $tasks = @(
       @{ id='t1'; title='...'; description='...'; files_touched=@('...'); depends_on=@() },
       # ... one entry per subtask
   )
   New-CodeSubtasksFile -Path $path -Feature '<feature>' -SpecPath '<specPath>' `
       -Tasks $tasks -JobId $state.job_id -Sprint $sprint
   "Wrote $path"
   ```

7. **Verify** by reading it back and running `Resolve-CodeTaskOrder` — surfaces
   any cycle the user might have introduced mid-edit.

   ```powershell
   $rd = Read-CodeSubtasksFile -Path $path
   $ordered = Resolve-CodeTaskOrder -Tasks $rd.tasks
   $ordered | Select-Object id, title | Format-Table -AutoSize
   ```

8. **Hand off.** Print: *"Decomposition ready. Run /code-parallel to dispatch."*

## Arguments

$ARGUMENTS
