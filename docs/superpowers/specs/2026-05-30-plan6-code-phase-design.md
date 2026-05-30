# Plan 6 — Code Phase: Decompose + Parallel Worktrees + Merge — Design

**Date:** 2026-05-30
**Status:** Authored autonomously per user direction
**Author:** Claude (with autonomous design decisions logged via decisions-lib)
**Predecessors:** Plans 1-5, 5b, 5c
**Successors:** Plan 7 (multi-project command center)

---

## Umbrella context

Plan 3 added the job scaffold with phase model `research → design → code.sprint-N → review`. Plan 4 added the fleet. Plan 5/5b/5c added research-phase muscle. Plan 6 is the **code phase**: turn a (researched, designed) feature into working code by decomposing it, dispatching parallel implementation work in isolated worktrees, then merging.

```
research  → /ensemble, /six-hats, /council    (Plans 5/5b/5c)
design    → human writes a spec               (existing)
code.s-N  → /code-decompose, /code-parallel,  ← THIS PLAN
            /code-merge
review    → (existing /job-phase review, future Plan 7)
```

## Purpose

Given a finalized feature spec, the orchestrator:
1. **Decompose** the spec into N independent (or DAG-ordered) subtasks.
2. **Parallel:** dispatch one Agent subagent per subtask in an isolated git worktree, implement concurrently.
3. **Merge:** read each subagent's diff + summary, propose an integration plan in dependency order, apply.

The win is **wall-clock speed**: independent backend / frontend / tests / docs work runs in parallel processes (Claude Code's Agent tool with `isolation: worktree`), not serial.

## Non-goals (deferred)

- **Automated dependency inference.** Decomposition includes `depends_on` per task, but Claude (or the user) writes them — no AST-based inference.
- **Cross-task communication mid-flight.** Subagents work in isolation. No shared draft files; if task B needs task A's API shape, A must finish first (sequenced via `depends_on`).
- **Auto-merge on green CI.** `/code-merge` proposes; the user (or Claude in the same session) applies. No headless auto-merge in this plan.
- **Conflict-resolution AI.** When `git merge` produces conflicts, we surface them and stop — no LLM-driven conflict fixing in scope.
- **Long-running watched worktrees** (live dashboard view). Plan 7.
- **Council-vetted decomposition.** Could feed `/code-decompose`'s draft tasks into a `/council` round — interesting but out of scope here.

## Architecture overview

```
        ┌────────────────────────────────────────────────────────────────┐
        │   CLAUDE CODE (orchestrator)                                   │
        │                                                                │
        │   /code-decompose <spec-or-path>                               │
        │     └─→ writes <job>/phases/<sprint>/subtasks.json             │
        │                                                                │
        │   /code-parallel                                               │
        │     └─→ reads subtasks.json                                    │
        │     └─→ for each task: Agent(isolation: worktree, ...)         │
        │         all dispatched in ONE message for true parallelism     │
        │     └─→ records results in parallel-<ts>/manifest.json         │
        │                                                                │
        │   /code-merge                                                  │
        │     └─→ reads manifest.json                                    │
        │     └─→ Get-CodeWorktreeStatus per task                        │
        │     └─→ presents merge plan in dependency order                │
        │     └─→ applies (cherry-pick or fast-forward merge) per task   │
        └────────────────────────────────────────────────────────────────┘
                                       │
                       ┌───────────────┼────────────────┐
                       ▼               ▼                ▼
                   worktree A     worktree B       worktree C
                   (t1 branch)    (t2 branch)      (t3 branch)
                   Agent          Agent            Agent
                   commits        commits          commits
```

## Components

### 1. `scripts/code-lib.ps1`

Thin shared library. Most decision logic lives in the slash commands (Claude). The lib handles file IO, path math, and git worktree probing.

```
New-CodeSubtasksFile
    -Path string             # where to write the JSON
    -Feature string          # feature name
    -SpecPath string         # path to the design spec (informational)
    -Tasks array             # @( @{ id; title; description; files_touched; depends_on } )
    -JobId string            # active job
    -Sprint string           # e.g. 'code.sprint-1'

Read-CodeSubtasksFile
    -Path string
  → hashtable: @{ version; feature; spec_path; decomposed_at; job_id; sprint; tasks }

Write-CodeParallelManifest
    -Path string             # parallel-<ts>/manifest.json
    -Results array           # @( @{ task_id; worktree; branch; summary; status; commits_ahead; files_changed } )

Read-CodeParallelManifest
    -Path string
  → manifest hashtable

Get-CodeWorktreeStatus
    -WorktreePath string
    -BaseBranch string = 'master'
  → @{ commits_ahead; files_changed; dirty }
  Implementation: cd into worktree (or git -C), run:
    git rev-list --count <base>..HEAD     → commits_ahead
    git diff --stat <base>..HEAD          → parse files_changed count
    git status --porcelain                → dirty if any lines

Get-CodeOutputDir
    -JobId string
    -Sprint string
  → "$HOME/.claude/jobs/<JobId>/phases/<sprint>/parallel-<ts>/"

Resolve-CodeTaskOrder
    -Tasks array             # tasks with id + depends_on
  → ordered task[] (topological sort; throws on cycle)
```

`Get-CodeWorktreeStatus` is the readback hook for `/code-merge`: it tells Claude how much work each task produced without re-reading every file.

### 2. `subtasks.json` schema (v1)

```json
{
  "version": 1,
  "feature": "Add user profile page",
  "spec_path": "D:/Dev/myrepo/docs/specs/profile.md",
  "decomposed_at": "2026-05-30T05:30:00-06:00",
  "job_id": "j042-add-user-profile",
  "sprint": "code.sprint-1",
  "tasks": [
    {
      "id": "t1",
      "title": "Backend API: GET/PUT /profile",
      "description": "Implement Express route, validation, persistence layer. See spec section 3.",
      "files_touched": ["src/api/profile.ts", "src/api/profile.test.ts"],
      "depends_on": []
    },
    {
      "id": "t2",
      "title": "Frontend ProfileForm component",
      "description": "React component with field validation. See spec section 4.",
      "files_touched": ["src/components/ProfileForm.tsx", "src/components/ProfileForm.test.tsx"],
      "depends_on": ["t1"]
    }
  ]
}
```

`files_touched` is INFORMATIONAL — used by `/code-merge` to surface likely conflicts before applying. It is not enforced (subagent may touch other files).

`depends_on` is hard: `/code-parallel` dispatches a task's subagent only once all its dependencies' subagents have completed successfully. Tasks with empty `depends_on` start immediately. Cycles → `/code-decompose` rejects.

### 3. `/code-decompose` slash command — `commands/code-decompose.md`

Grammar: `/code-decompose [<path-to-spec>]`

If no path given, infer from active job: look in `<job>/phases/design/` for the most recent `.md` file. If none, error pointing to `/job-start` or supplying a path explicitly.

Steps Claude performs:
1. Require active job (read `Read-CurrentJob`); if none, error.
2. Resolve the spec path; read it.
3. **Decomposition** (Claude's judgment): break the feature into N independent or DAG-ordered subtasks, each:
   - Small enough for one focused Agent session (~hundreds of LOC)
   - Has a clear scope and `files_touched`
   - Lists `depends_on` honestly (empty preferred; sequential when necessary)
4. Confirm count + titles with the user *before* writing the file. (Decomposition is high-stakes; one extra confirmation step is worth it.)
5. Call `New-CodeSubtasksFile` writing to `<job>/phases/<sprint>/subtasks.json`.
6. Print the resulting task list.

`<sprint>` is read from the job state (`Read-CurrentJob` → `phase`); if the active phase is not `code.sprint-N`, warn and use `code.sprint-1` as fallback.

### 4. `/code-parallel` slash command — `commands/code-parallel.md`

Grammar: `/code-parallel`

Steps Claude performs:
1. Require active job. Read `<job>/phases/<sprint>/subtasks.json`.
2. `Resolve-CodeTaskOrder` → ordered list (independent tasks first; dependent tasks after their prereqs).
3. Build the output dir: `parallel-<ts>/`. Write a starter manifest.
4. **Dispatch:** for each independent task (and each task whose `depends_on` are already complete), call the `Agent` tool with:
   - `subagent_type: general-purpose`
   - `isolation: worktree`
   - `description`: short (3-5 words)
   - `prompt`: a self-contained brief including:
     - feature name + spec excerpt (relevant section, not whole spec)
     - the task's title + description + files_touched
     - explicit completion contract: "commit your work; return a one-paragraph summary + the diffstat"
   All independent tasks are dispatched in **one Agent call batch** (multiple Agent tool uses in one message) for true parallelism.
5. **Collect:** wait for the batch, parse each Agent's returned worktree path + branch + summary.
6. **Iterate:** if `depends_on` chains exist, repeat the dispatch for the next-ready batch using updated dependency state.
7. Append each task's result to `parallel-<ts>/manifest.json` via `Write-CodeParallelManifest`.
8. Print a summary table: task_id, status, commits_ahead, files_changed.

Failure handling per task:
- Agent returns with no changes → task marked `empty` (still recorded; no worktree retained).
- Agent errors → recorded as `failed`; dependents stay blocked; user prompted to retry the specific task.
- A task whose dependencies failed → recorded as `blocked`; never dispatched.

### 5. `/code-merge` slash command — `commands/code-merge.md`

Grammar: `/code-merge [--apply]`

Steps Claude performs:
1. Require active job; read latest `parallel-<ts>/manifest.json` from the active sprint dir.
2. For each task with `status=ok`: `Get-CodeWorktreeStatus`. Refresh `commits_ahead` and `files_changed`.
3. Sort by `Resolve-CodeTaskOrder` (dependency-first).
4. **Surface likely conflicts:** for each pair of tasks (i, j) where i merges before j, intersect their `files_touched`. Any overlap → flag as "potential conflict".
5. **Present the merge plan** to the user:
   - order
   - per-task: `commits_ahead`, `files_changed`, summary
   - flagged conflicts
6. **If `--apply`** is set, execute the plan:
   - For each task in order: `git -C <repo> cherry-pick <task-branch>~<commits_ahead>..<task-branch>`
     (Or `git merge --no-ff <task-branch>` — Claude picks per task, defaulting to cherry-pick for clean linear history.)
   - Stop on first conflict; tell the user to resolve, then re-run `/code-merge --apply` to resume from the failed task.
7. **Without `--apply`:** print the plan; user reviews; re-runs with `--apply` when satisfied.
8. After all tasks merge: prompt the user to remove worktrees via `Remove-CodeWorktree -All` (separate command? for v1, just print the `git worktree remove` invocations).

### 6. Worktree lifecycle

The `Agent` tool's `isolation: worktree` parameter creates and tracks the worktree. The returned `path` is stored in the manifest. After `/code-merge`, the user (or Claude) is responsible for `git worktree remove <path>` — Plan 6 surfaces the commands but does not auto-prune (destructive operation by Claude Code defaults requires confirmation).

A `.gitignore` entry for `.worktrees/` is added in case the Agent tool places worktrees inside the repo (it may not — depends on harness implementation). Belt-and-suspenders.

## Output layout

```
<job>/phases/code.sprint-1/
  ├── subtasks.json                ← /code-decompose output
  └── parallel-2026-05-30T05-40-00/
      ├── manifest.json             ← /code-parallel output: per-task results
      ├── t1/
      │   ├── summary.md            ← subagent's one-paragraph summary
      │   └── diff.patch            ← `git diff <base>..<branch>` snapshot
      ├── t2/
      │   └── ...
      └── merge-plan.md             ← /code-merge output (if run)
```

(Subagent-produced `summary.md` and `diff.patch` are captured by Claude in `/code-parallel` after each Agent returns — the Agent tool result string is parsed; the diff is regenerated from git in the worktree.)

## Journal integration

Each `Agent` dispatch in `/code-parallel` is a Claude subagent — that's already tracked by Claude Code's own telemetry, not the `fleet | …` journal. Plan 6 adds one optional journal line type:

```
<ts> | code | parallel | <job-id> | sprint:code.sprint-N | tasks:N | ok:K | err:E
```

Written by `/code-parallel` after the final dispatch batch via a new helper `Write-CodeJournalLine` in `code-lib.ps1`. Defers to existing journal format (pipe-delimited, single line). Picks up `job:`/`phase:` tags from `current-job.json` like the fleet helper.

## Testing strategy

`scripts/test-code-lib.ps1`:
- `New-CodeSubtasksFile` + `Read-CodeSubtasksFile` round-trip the schema
- `Resolve-CodeTaskOrder` topo-sorts a DAG correctly
- `Resolve-CodeTaskOrder` throws on a cycle
- `Resolve-CodeTaskOrder` returns independent tasks first
- `Write-CodeParallelManifest` + `Read-CodeParallelManifest` round-trip
- `Get-CodeOutputDir` returns the correct `<job>/phases/<sprint>/parallel-<ts>/` shape
- `Get-CodeWorktreeStatus` against a temp git repo with N commits ahead — verify counts
- `Write-CodeJournalLine` produces the expected `| code | parallel | …` shape

Slash commands aren't unit-tested (Claude templates); manual smoke in bootstrap verification.

## File layout (repo)

```
D:\Dev\coding-agent-orchestrator\
├── docs/superpowers/specs/2026-05-30-plan6-code-phase-design.md   ← this
├── commands/
│   ├── code-decompose.md           ← NEW
│   ├── code-parallel.md            ← NEW
│   └── code-merge.md               ← NEW
└── scripts/
    ├── code-lib.ps1                ← NEW
    ├── test-code-lib.ps1           ← NEW
    └── bootstrap.ps1               ← MODIFY: deploy code-lib.ps1 + 3 new commands
```

Deployed under `~/.claude/`: `scripts/code-lib.ps1`, `commands/code-decompose.md`, `commands/code-parallel.md`, `commands/code-merge.md`.

## Success criteria

- Given a multi-component feature spec, `/code-decompose` produces a sensible task list confirmed before write.
- `/code-parallel` runs independent tasks concurrently (verifiable: wall-clock < sum of per-task durations).
- `/code-merge` surfaces conflicts via `files_touched` overlap BEFORE attempting application.
- Dependency-ordered tasks respect `depends_on`: blocked tasks wait until prereqs succeed.
- All `code-lib.ps1` tests pass.
- Worktree paths recorded in manifest survive `/code-merge` re-runs (idempotent reads).

## Decisions made (autonomous)

- **Three commands, not one mega-command.** `/code-decompose`, `/code-parallel`, `/code-merge` map to natural human checkpoints: review the decomposition; spawn the work; review/apply the merges.
- **Decomposition is Claude's job, not a fleet call.** Decomposition needs the WHOLE spec in context and produces an opinionated structured output. Could later be vetted by `/council` but that's a separate command.
- **Confirmation step before writing subtasks.json.** High-stakes; one extra prompt is worth it. (Bypassable in future via `--yes`.)
- **`isolation: worktree` via Claude Code's Agent tool, not custom worktree shell-out.** The Agent tool already handles worktree creation + cleanup-on-no-change. Reuse this; don't reinvent.
- **Cherry-pick by default, not merge.** Cleaner linear history; matches small focused commits per task.
- **Stop on first conflict; resume on re-run.** No automated conflict resolution.
- **`files_touched` is informational (not enforced).** Subagent may touch other files; enforcement would require complex sandboxing.
- **Topo-sort enforced; cycles rejected at `/code-decompose`.** Cycles indicate a bad decomposition.
- **One journal line per `/code-parallel` batch.** Aggregate `code | parallel | …` line; per-task detail lives in `parallel-<ts>/manifest.json`.
- **`.gitignore` includes `.worktrees/`** belt-and-suspenders in case Agent tool places worktrees inside the repo.
