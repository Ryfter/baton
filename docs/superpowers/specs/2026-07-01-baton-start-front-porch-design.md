---
title: /baton:start — the Conductor's Front Porch (slice 1)
status: draft
date: 2026-07-01
supersedes: none
relates-to: /baton:go (conductor-go-mode), /baton:idea, /baton:project-init, north-star (autonomy + legibility)
---

# /baton:start — the Conductor's Front Porch (slice 1)

## Summary

`/baton:start` is the one command a human types to **begin or resume** work on a
project — including a human who does not know what git is, cannot code, and does
not know what they don't know. It runs a plain-language, **teaching**, **user-adaptive**
onboarding that captures *what* they want and *why*, sets up the project mechanics
for them (folder, git) while explaining each step, writes a plain-language project
**CHARTER**, and then hands the captured goal to `/baton:go` to run **full-auto**
under the two existing guards. At every seam — after setup, at a guard pause, on
completion, on resume — it narrates what happened and recommends the single best
next command, and *why that one*, so the user learns over time.

This is the **legibility** half of the north star, complementing `/baton:go`'s
**autonomy** half. It is a wrapper/orchestrator over the existing front doors, not
a replacement.

Slice 1 delivers the Front Porch core plus a **minimal** box-private user profile
(read to pick interview depth; written back), so the personalization seam exists
from day one. Slices 2 (working-style learning loop into Grimdex) and 3 (mid-stream
idea injection) are named here but out of scope.

## Goals

- **One command, two paths.** `/baton:start` (aliases `/baton:init`,
  `/baton:initialize`) starts a new project or resumes an ongoing one, deciding
  which automatically.
- **No mechanics required of the user.** Folder creation, `git init`, project
  registration all happen *for* the user, each narrated in plain language.
- **Adaptive, teaching interview.** Depth adapts to the user (light for known
  users, fuller for new ones, deeper when answers are vague/high-stakes). Teaching
  is on by default and can be dialed down.
- **Capture the reasoning.** Every answer and the *why* is written down: a
  user-owned `CHARTER.md` in the project folder, plus the decision *why* in
  Baton's box-private decision store, supplemented to Grimdex/memory when present.
- **Full-auto execution.** After onboarding, hand the goal to `/baton:go`; do not
  re-implement the engine.
- **Recommend the next command at every juncture.**

## Non-goals (slice 1)

- Language/framework scaffolds beyond `git init` + a minimal seed. (No `npm init`,
  no templates.)
- The full working-style learning loop into Grimdex — slice 2.
- Mid-stream idea injection — slice 3.
- Replacing `/baton:job-start`, `/baton:job-phase`, `/baton:go`, or `/baton:idea`.
  They remain as-is; `/baton:start` orchestrates and recommends them.

## Context — the front doors today

| Command | Role today | Gap for a non-technical starter |
| --- | --- | --- |
| `/baton:job-start "<brief>"` | Low-level job creator; assumes a registered project + a written brief; drops you at `research`. | Demands a brief; asks nothing; teaches nothing. |
| `/baton:go "<outcome>"` | Autonomous DAG execution under two guards. | Never asks name/folder; never recommends a next command; zero hand-holding. |
| `/baton:idea "<idea>"` | Idea → vetted GitHub-issue backlog. | Job-less; produces issues, not a running project. |
| `/baton:project-init` | Calibrates per-project *decision guidance*. | Not an entry point; no folder/goal/charter. |

`/baton:start` is the missing porch that points a human at the right door.

## Architecture

House pattern: a pure, I/O-seamed PowerShell library + a markdown command that
inlines calls to it. Aliases are thin delegators. All persistent state is
box-private under `$BATON_HOME`; the user's CHARTER lives in their project folder.

### Files

- **Create** `commands/start.md` — canonical command (the brain).
- **Create** `commands/init.md` — thin delegator: "This is an alias for
  `/baton:start`; execute its procedure with the same `$ARGUMENTS`."
- **Create** `commands/initialize.md` — thin delegator (same body as `init.md`).
- **Create** `scripts/start-lib.ps1` — pure helpers + thin I/O wrappers with path
  seams (project record, user profile, interview-depth resolution, charter
  scaffolding, status summary, next-command recommendation).
- **Create** `scripts/test-start-lib.ps1` — hermetic tests (temp dirs, no network,
  never touches real `$BATON_HOME`/`~/.claude`).
- **Modify** `scripts/bootstrap.ps1` + `scripts/test-bootstrap.ps1` — ship the new
  command files and `start-lib.ps1`; assert their presence.
- **Modify** `.claude-plugin/plugin.json` — version bump (rc).
- **Modify** `docs/COMMANDS.md` / `docs/getting-started.md` — document
  `/baton:start` as the recommended entry point.

### `start-lib.ps1` — functions

All pure unless noted. Path parameters default to `$BATON_HOME`-derived locations
but are injectable for tests.

- `Resolve-StartMode -ProjectRecord` → `'new' | 'resume'`. Pure. `$null` record →
  `new`; otherwise `resume`.
- `Resolve-InterviewDepth -Profile -Explicit` → `'light' | 'adaptive' | 'full'`.
  Pure. Precedence: explicit flag > profile's `preferred_interview_depth` > (`full`
  if profile is `$null` — a new/unknown user) > `adaptive`.
- `Resolve-TeachingLevel -Profile -Explicit` → `'teach' | 'quiet'`. Pure.
  Precedence: explicit `--quiet` > profile's `teaching_level` > `teach`.
- `New-CharterContent -Name -Goal -Audience -Done -Reasoning` → CHARTER.md markdown
  string. Pure. Empty optional sections render a plain "(to be filled in)" line,
  never a blank.
- `Format-ResumeStatus -ProjectRecord` → one plain-language status paragraph
  (project name, folder, last-run status, what it means). Pure.
- `Get-NextCommandRecommendation -RunStatus` → `@{ command; why }`. Pure. Maps a
  `/baton:go` status to the recommended follow-up:
  - `completed` → `/baton:gate` (review quality) or `/baton:effective-cost` (spend);
  - `interrupted-budget` → re-run `/baton:start` / `/baton:go` with a higher
    `--budget`;
  - `interrupted-destructive` → approve the pending step, then resume;
  - `rejected` → `/baton:gate` findings + re-run;
  - `failed` / `plan-failed` / `plan-invalid` → sharpen the goal and retry.
- `Read-ProjectRecord -ProjectId -ProjectsRoot` → record object or `$null` (thin
  I/O; `<root>/<id>/project.json`).
- `Write-ProjectRecord -Record -ProjectsRoot` → writes `project.json`
  (`utf8NoBOM`), creating parent dirs.
- `Read-UserProfile -ProfilePath` → profile object or `$null` (thin I/O).
- `Write-UserProfile -Profile -ProfilePath` → writes `user-profile.json`
  (`utf8NoBOM`).

Reuses from `job-lib.ps1`: `Get-BatonHome`, `Resolve-ProjectId`,
`ConvertTo-JobSlug` (for `name → project-id`).

## State machine

On invocation:

1. **Parse `$ARGUMENTS`.** Optional leading quoted **name**; flags `--folder
   <path>`, `--goal "<text>"`, `--budget <n>`, `--max-tier local|free|paid`,
   `--quiet`. Anything absent is asked for (new path) or inferred (resume path).
2. **Resolve project.** Slug the name (if given) via `ConvertTo-JobSlug`, else
   `Resolve-ProjectId` on the target/cwd folder. `Read-ProjectRecord`.
3. **`Resolve-StartMode`:**
   - **resume** → `Format-ResumeStatus`, narrate where it left off, recommend the
     next command via `Get-NextCommandRecommendation` against `last_run.status`,
     and (on the user's OK) continue driving `/baton:go`.
   - **new** → run onboarding (below), then drive `/baton:go`.

## Onboarding (new path)

Depth from `Resolve-InterviewDepth`. In **all** depths the assistant offers
proactive recommendations ("I don't know what I don't know" support) — *light* is
not "no help," it is "help on demand + proactive suggestions."

Captured, in plain language (never assuming jargon):

1. **What are you trying to make?** → `goal`.
2. **Who is it for?** (adaptive/full only; skipped in light unless volunteered) →
   `audience`.
3. **How will we know it's working / done?** (adaptive/full) → `done`.
4. **Where should it live?** → `folder`. If the user has no idea, recommend a
   sensible default under a projects directory and explain it.
5. Throughout, the assistant records the user's **reasoning** verbatim-ish for the
   CHARTER's "Why" section.

### Folder — detect & branch, narrated

- **Exists** → adopt it; if not already a git repo, offer `git init` and explain
  why ("git saves snapshots so we can never lose your work or go back a step").
- **Absent** → create the folder, `git init`, seed a minimal structure
  (`CHARTER.md`, a `.gitignore`, a stub `README.md`) — each step narrated.
- Never require the user to run git themselves.

### Register the project

Write `project.json` (box-private) binding `id ↔ name ↔ folder ↔ charter_path`,
`created_at`. Write `CHARTER.md` (in the folder) from `New-CharterContent`. Because
goal/reasoning text can be long, **write the CHARTER from a file/heredoc, never an
inline shell argument** (965-byte limit).

### Documentation, layered

- `CHARTER.md` — the user's, in their repo, versioned with their code.
- **Decision store** — capture the genuine go/architecture decisions of the
  onboarding via the file-based decision intake (`Add-DecisionRecordFromFile`),
  box-private.
- **Grimdex / memory supplement** — if a Grimdex project tier or auto-memory is
  present, record the *why* there too (detected, best-effort, never required).

## Execution — hand to `/baton:go`

After setup (new) or confirmation (resume), run the engine in the project folder:

```powershell
pwsh -File "$HOME/.claude/scripts/fleet-go.ps1" -Goal "<goal>" -Json
# add -Budget <n> and/or -MaxCostTier <tier> when supplied
```

Read the returned JSON (`status`, `run_dir`, `spend`, `pending_task_id`). Update
`project.json`'s `last_run` (`run_id` from `run_dir`, `status`, `at`). Narrate the
run terse-one-liner style from `<run_dir>/events.jsonl` and surface the autonomous
choices from `<run_dir>/decisions.jsonl` (legibility). `/baton:start` does **not**
re-implement planning/dispatch — it is a wrapper.

## Seam legibility + teaching

Teaching level from `Resolve-TeachingLevel` (default `teach`). At each seam:

- **After setup:** "Registered *<Name>* at *<folder>*, set up git, wrote your
  CHARTER. Now driving `/baton:go` — I'll only stop for a budget limit or an
  irreversible action." (teach mode adds the one-line *why* for git/charter.)
- **Guard pause:** surface what is pending + the exact resume command +
  `Get-NextCommandRecommendation`.
- **Completion:** point at `report.md`; recommend `/baton:gate` /
  `/baton:effective-cost` / `/baton:start` again, with the why.
- **Resume:** `Format-ResumeStatus` + recommended next command.

In `teach` mode, each recommendation includes a one-sentence rationale so the user
learns *why* this is the right move. In `quiet` mode, recommendations are the bare
command.

## Data structures

### `$BATON_HOME/projects/<id>/project.json` (box-private)

```json
{
  "id": "acme-api",
  "name": "Acme API",
  "folder": "D:/Dev/acme-api",
  "charter_path": "D:/Dev/acme-api/CHARTER.md",
  "created_at": "2026-07-01T09:00:00-06:00",
  "last_updated": "2026-07-01T09:20:00-06:00",
  "last_run": { "run_id": "run-2026-07-01-...", "status": "completed", "at": "2026-07-01T09:20:00-06:00" }
}
```

### `$BATON_HOME/user-profile.json` (box-private, one per box)

```json
{
  "preferred_interview_depth": "light",
  "teaching_level": "teach",
  "updated_at": "2026-07-01T09:20:00-06:00"
}
```

Slice 1 writes `preferred_interview_depth` and `teaching_level` only. `null`/absent
fields are honored by the resolvers (new user → `full` depth, `teach` level). The
schema is intentionally forward-compatible with slice 2's richer profile.

### `CHARTER.md` (in the project folder)

```markdown
# <Name> — Project Charter

_Written by /baton:start on <date>. Your plain-language record of what we're building and why._

## What we're building
<goal>

## Who it's for
<audience or "(to be filled in)">

## What "done" looks like
<done or "(to be filled in)">

## Why — the reasoning
<captured reasoning>

## Decisions & open questions
<running list; seeded from onboarding>

---
_Baton tracks the technical run history privately under its own home; this file is yours._
```

## Box-private boundary

- `project.json` and `user-profile.json` live under `$BATON_HOME` — **never** the
  knowledge repo or any shared seed.
- Run artifacts stay under `$BATON_HOME/runs/<run-id>/` (unchanged).
- The **CHARTER** is the user's own product documentation and lives in *their*
  project folder — it is not a model inventory/cost record, so the box-private rule
  does not apply to it.
- Grimdex/memory supplements follow their own existing privacy rules.

## Testing

Hermetic, house-standard. Tests never touch real `$BATON_HOME` or `~/.claude`;
they use temp dirs and injected path seams, with zero network.

`test-start-lib.ps1`:

- **Pure resolvers:** `Resolve-StartMode` (null → new; record → resume);
  `Resolve-InterviewDepth` (explicit > profile > null-user=full > adaptive, all
  branches); `Resolve-TeachingLevel` (quiet flag, profile, default).
- **`New-CharterContent`:** required sections present; empty optionals render the
  "(to be filled in)" line, never blank; name/goal interpolated.
- **`Get-NextCommandRecommendation`:** one case per `/baton:go` status
  (`completed`, `interrupted-budget`, `interrupted-destructive`, `rejected`,
  `failed`, `plan-failed`), asserting `command` + non-empty `why`.
- **`Format-ResumeStatus`:** includes name, folder, and a human-readable last-run
  state.
- **Record/profile round-trips:** `Write-*` then `Read-*` against a temp
  `ProjectsRoot`/`ProfilePath` returns equal values; reading a missing file
  returns `$null` (not a throw); files are `utf8NoBOM`.

`test-bootstrap.ps1`: assert `commands/start.md`, `commands/init.md`,
`commands/initialize.md`, and `scripts/start-lib.ps1` are staged by
`bootstrap.ps1`.

**End-to-end** onboarding is validated post-deploy by a smoke run using
`fleet-go.ps1`'s canned seams (`-Planner/-Spawner/-Gater` / the `BATON_GO_*` canned
env), so no real fleet call or network is needed to prove the hand-off, the
`project.json` write, and the recommendation at completion.

## Decisions made

1. **Wrapper, not replacement.** `/baton:start` orchestrates the existing front
   doors and recommends them; it does not re-implement job/go/idea machinery.
   *Alt considered:* fold everything into one mega-command — rejected: duplicates
   the engine, breaks the building blocks, harder to test.
2. **Full-auto execution after a guided, teaching, user-adaptive onboarding.** The
   *questions and teaching* live in onboarding and at junctions; the *execution* is
   autonomous via `/baton:go`. *Alt:* per-step approval — rejected: user chose
   full-auto; defeats "LLMs do the heavy lifting."
3. **Interview depth from a box-private user profile**, minimal at n=1 (light for
   known users, full for new). *Alt:* hard-code adaptive — rejected: the personal­
   ization is the point, and anchoring the profile concept now (concept-anchoring
   over YAGNI) is what slice 2's learning loop fills.
4. **CHARTER in the user's project folder; decision *why* in the box-private store;
   supplement to Grimdex/memory when present.** *Alt:* box-private only — rejected:
   the user must own and be able to read their own project documentation.
5. **Detect-&-branch folder with `git init` performed and narrated for the user.**
   *Alt:* require an existing folder — rejected: a non-technical user may not have
   one and should not have to make it.

## Global constraints (for the plan)

- **Box-private:** `project.json`, `user-profile.json`, and run artifacts stay
  under `$BATON_HOME`; never the knowledge repo/shared seed. CHARTER is the
  exception (user-owned, in the project folder).
- **965-byte shell-arg limit:** write CHARTER / long goal/reasoning text via
  file/heredoc, never an inline argument.
- **`utf8NoBOM`** for every file written.
- **PowerShell automatic-variable trap:** never name a param/local `$args`,
  `$input`, `$event`, `$matches`, `$host` (codebase uses `$EventObj`); reading the
  automatic `$Matches` after `-match` is allowed.
- **Parenthesize function calls inside comparisons.**
- **Unary-comma array return** (`return ,@($x)` non-empty, `return @()` empty) and
  do **not** re-wrap the returned value in `@()` on direct assignment.
- **`Write-Error` throws under `$ErrorActionPreference='Stop'`:** CLI user-error
  paths use `[Console]::Error.WriteLine()` + `exit 2`.
- **Tests never touch real `$BATON_HOME`/`~/.claude`:** temp dirs, injected seams,
  zero network.
- **Decision capture** via `Add-DecisionRecordFromFile` for the genuine onboarding
  decisions (don't announce; skip micro-choices).

## Out of scope / future slices

- **Slice 2 — Working-style learning loop.** Grow `user-profile.json` into Grimdex:
  persist and consolidate light/adaptive/full preference, teaching verbosity, and
  accumulated preferences, so a returning user's onboarding keeps shrinking.
  Sibling of the learned-cost routing loop.
- **Slice 3 — Mid-stream idea injection.** Brain-dump-anytime: paste paragraphs
  mid-project; they fold into the CHARTER and route to a re-plan / `/baton:idea` /
  new `/baton:go` run. Supports the days-long, idea-driven cadence.
