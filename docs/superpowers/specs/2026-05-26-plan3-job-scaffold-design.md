# Plan 3 — Job & Phase Scaffold (+ Knowledge Base Foundation) — Design

**Date:** 2026-05-26
**Status:** Draft, awaiting user review
**Author:** Kevin Rank (with Claude)
**Predecessors:** Plan 1 (observation foundation), Plan 2 (dashboard)
**Successors:** Plans 4 (fleet config), 5 (research phase), 6 (code phase), 7 (review + cockpit), 8 (learning loop retrieval)

---

## Umbrella context (where Plan 3 fits)

The orchestrator's full vision is a phased pipeline driven by Claude Code as the orchestrator, dispatching work across a CLI-first fleet of paid + free + local LLMs:

```
USER drops brief + constraints
      ↓
   RESEARCH       (ensemble across fleet; iterates internally:
                   brain-dump → refine → alternatives → sanity-check via
                   6 Thinking Hats / LLM Council)
      ↓
   DESIGN        (Claude synthesizes; optional council check)
      ↓
   CODE.sprint-N (decompose + farm out across fleet; each provider in
                   its own worktree)
      ↓
   REVIEW        (Claude + Codex on the diff)
      ↓
   (next sprint or done)
```

Approach C (Hybrid) was chosen: **Claude Code itself is the orchestrator**; persistent job files on disk are the source of truth; the dashboard is a cockpit that observes and (in later plans) interacts.

Plan ordering across the full vision:

| Plan | Scope |
|---|---|
| 1 (shipped) | Observation foundation: hooks, OTel exporter, journal, catalog |
| 2 (shipped) | Local web dashboard at `localhost:8765` |
| **3 (this)** | **Job & phase scaffold + knowledge-base foundation + lesson capture** |
| 4 | Fleet config + multi-machine local model access |
| 5 | Research phase wiring (ensemble, council, 6-hats) |
| 6 | Code phase (decompose + parallel worktrees) |
| 7 | Review phase + analytics cockpit (token-by-phase debrief) |
| 8 | Learning loop — embedding-based KB retrieval + auto-injection |

---

## Purpose

Make a *job* a real, persistent thing on disk with phase tracking, lesson capture, and dashboard visibility. **No dispatch to other LLMs yet** — that's Plan 4. This plan is the data substrate that all later plans hang off of.

Three deliverables:
1. **Job file layout** — every job lives under `~/.claude/jobs/<job-id>/` with manifest, brief, phase log, and lessons.
2. **Phase-tagged journal** — extend the Plan 1 hook so every tool call inside an active job carries `job:` + `phase:` trailing tags. This unlocks per-phase cost analytics in Plan 7.
3. **Knowledge base foundation** — two-layer KB (universal + per-project) under `~/.claude/knowledge/`, populated by `/job-lesson` captures during work and consolidated into KB files by `/consolidate-lessons`.

Plus the slash-command surface to drive it (`/job-start`, `/job-phase`, `/job-resume`, `/job-lesson`, `/consolidate-lessons`) and a read-only Jobs panel on the dashboard.

## Non-goals (deferred to later plans)

- Dispatching tasks to fleet members. Plan 4 wires the fleet; Plans 5–7 do the dispatch.
- Ensemble / 6-Hats / Council primitives. Plan 5.
- Decompose-and-farm-out coding. Plan 6.
- Claude+Codex pair review on the diff. Plan 7.
- Cockpit interactions in the dashboard (new-job form, phase buttons, minimizable agent cards, drill-into-live-commands). Plan 7.
- Embedding-based KB retrieval / auto-injection of relevant lessons. Plan 8.
- Concurrent jobs in the same Claude Code session. Documented limitation; defer.
- Direct API access (ChatGPT / OpenRouter). CLI-only for now.

## Architecture overview

```
        ┌────────────────────────────────────────────────────────────┐
        │   CLAUDE CODE (this session) = THE ORCHESTRATOR            │
        │                                                             │
        │   New slash commands:                                       │
        │     /job-start   /job-status   /job-list                    │
        │     /job-phase   /job-resume                                │
        │     /job-lesson  /consolidate-lessons                       │
        │                                                             │
        │   Manages session env vars:                                 │
        │     $env:CAO_JOB_ID                                         │
        │     $env:CAO_PHASE                                          │
        └────────────────────────────────────────────────────────────┘
                                │
              ┌─────────────────┼──────────────────┐
              │                 │                  │
              ▼                 ▼                  ▼
       Hook (extended)    Job files          Knowledge base
       reads env vars,    on disk            on disk
       appends trailing
       job: + phase:                         (consolidated from
       to every journal                       job lessons.md)
       line
              │                 │                  │
              ▼                 ▼                  ▼
       ~/.claude/         ~/.claude/         ~/.claude/
       model-routing-     jobs/<id>/         knowledge/
       log.md              ├ manifest.yaml    ├ universal/
       (existing)          ├ brief.md         │  ├ routing.md
                           ├ phase-log.md     │  ├ user-prefs.md
                           ├ lessons.md       │  ├ reasoning.md
                           └ phases/          │  ├ mistakes.md
                              ├ research/     │  ├ winners.md
                              ├ design/       │  └ topics/
                              ├ code/         └ projects/
                              │ ├ sprint-1/      └ <project>/
                              │ └ sprint-2/         ├ conventions.md
                              └ review/             ├ mistakes.md
                                                    ├ winners.md
                                                    ├ architecture.md
                                                    ├ decisions.md
                                                    └ topics/
                                       │
                                       ▼
                            DASHBOARD (Plan 2, extended)
                            New "Jobs" panel + drill-in route
                            Read-only in Plan 3; cockpit in Plan 7
```

## Phase model

Four phases. Inner iterations (brain-dump, refine, alternatives, sanity-check, etc.) happen *inside* a phase as dispatch patterns — they do not flip the phase tag.

| Phase | What it covers |
|---|---|
| `research` | Brain-dump, refine, generate alternatives, sanity-check (6 Hats / Council). All messy thinking. |
| `design` | Synthesis into a coherent plan. Optional council check on the design itself. |
| `code.sprint-N` | One sprint of implementation. `sprint_count` in manifest increments. |
| `review` | Claude + Codex on the diff (Plan 7). |
| `done` | Terminal. |

Default `next` walk: `research → design → code.sprint-1 → review → code.sprint-2 → review → ... → done`. Loop-backs (e.g., review surfaces a gap, jump back to `design`) are explicit: `/job-phase design`. Phase-log records the loop-back; dashboard shows the iteration count tick up.

## Components

### 1. Job file layout

Under `~/.claude/jobs/<job-id>/`:

```
j-2026-05-26-feature-flags/
├── manifest.yaml      ← current state (single source of truth)
├── brief.md           ← original brief, verbatim
├── phase-log.md       ← append-only transition history
├── lessons.md         ← raw lesson capture (consolidated later)
└── phases/            ← outputs land here; created lazily by Plans 5–7
    ├── research/
    ├── design/
    ├── code/
    │   ├── sprint-1/
    │   └── sprint-2/
    └── review/
```

**Job ID format:** `j-YYYY-MM-DD-<slug>`. Slug rule: lowercase the brief, strip a small stop-word list (`a, an, the, for, to, of, and, build, make, create, add`), take the first 4 remaining tokens, join with hyphens, alphanumeric only. Max 40 chars. Collisions get a `-2`, `-3` suffix.

**`manifest.yaml`** — small, current state only:

```yaml
id: j-2026-05-26-feature-flags
title: build a feature flag system for the orchestrator
created_at: 2026-05-26T11:00:00-06:00
status: active                       # active | done | abandoned
project: coding-agent-orchestrator   # null if --no-project
current_phase: research              # research | design | code.sprint-N | review | done
phase_started_at: 2026-05-26T11:12:33-06:00
sprint_count: 0                      # increments when entering code.sprint-N
last_updated: 2026-05-26T11:15:00-06:00
```

**`brief.md`** — free-form markdown; whatever the user wrote at `/job-start`.

**`phase-log.md`** — append-only, one line per transition:

```
# Phase Log — j-2026-05-26-feature-flags

2026-05-26T11:00:00-06:00 | created     | research
2026-05-26T11:35:00-06:00 | transition  | research → design
2026-05-26T11:58:00-06:00 | transition  | design → code.sprint-1
2026-05-26T13:20:00-06:00 | transition  | code.sprint-1 → review
2026-05-26T13:35:00-06:00 | loop-back   | review → design   note: "missing audit logging"
```

**`lessons.md`** — captured during the job by `/job-lesson`:

```
# Lessons — j-2026-05-26-feature-flags

## research
2026-05-26T11:20:00-06:00 | knowledge | "Feature flags split into release toggles vs ops toggles"

## code.sprint-1
2026-05-26T12:55:00-06:00 | mistake   | "devstral generated a flag write without locking — race condition"
2026-05-26T13:05:00-06:00 | user-pref | "Kevin prefers single-file TOML flag config over multi-file"
```

After `/consolidate-lessons` runs, each entry gets a trailing `✓ consolidated YYYY-MM-DD` marker so re-runs don't duplicate.

### 2. Knowledge base

Two layers under `~/.claude/knowledge/`:

```
~/.claude/knowledge/
├── universal/                  ← cross-project; applies everywhere
│   ├── routing.md              ← which model for what (Plan 1's catalog, moved)
│   ├── user-prefs.md           ← how Kevin works
│   ├── reasoning.md            ← thought processes / mental frameworks that work
│   ├── mistakes.md             ← cross-project mistake patterns
│   ├── winners.md              ← cross-project successes
│   └── topics/                 ← reusable domain knowledge
│       ├── feature-flags.md
│       └── …
└── projects/                   ← per-project KB
    ├── coding-agent-orchestrator/
    │   ├── conventions.md
    │   ├── mistakes.md
    │   ├── winners.md
    │   ├── architecture.md
    │   ├── decisions.md
    │   └── topics/
    └── <other-project>/
```

**Categories → default destination:**

| Category | Default scope | KB file |
|---|---|---|
| `routing` | universal | `universal/routing.md` |
| `user-pref` | universal | `universal/user-prefs.md` |
| `reasoning` | universal | `universal/reasoning.md` |
| `mistake` | project | `projects/<id>/mistakes.md` |
| `winner` | project | `projects/<id>/winners.md` |
| `convention` | project | `projects/<id>/conventions.md` |
| `decision` | project | `projects/<id>/decisions.md` |
| `architecture` | project | `projects/<id>/architecture.md` |
| `knowledge` | project | `projects/<id>/topics/general.md` for Plan 3 (single bucket per project; Plan 8 splits by topic via embeddings). `--scope universal` → `universal/topics/general.md`. |

Scope is auto-defaulted by category but always overridable via the `--scope` flag on `/job-lesson`.

**Migration note:** Plan 1's `~/.claude/model-routing.md` is moved to `~/.claude/knowledge/universal/routing.md`. The migration is part of the bootstrap step (Section 9).

### 3. Hook extension (Plan 1 hook, backward-compatible)

The PostToolUse hook already deployed by Plan 1 (`~/.claude/hooks/log-tool-call.ps1`) gains a small extension:

- Read `$env:CAO_JOB_ID` and `$env:CAO_PHASE`.
- If **both** are set, append ` | job:<id> | phase:<phase>` to the journal line.
- If either is missing or empty, write the line in the old format (no tags). **Backward compatible.**

**Existing format (unchanged when no job is active):**
```
2026-05-23T10:00:00-06:00 | hook | bash:ollama run devstral:24b 'Hello' | 2s | exit:0
2026-05-23T10:25:00-06:00 | hook | agent:claude-subagent | 0s | exit:0 | "spec review task"
```

**New format (job active):**
```
2026-05-26T11:00:00-06:00 | hook | bash:ollama list | 1s | exit:0 | job:j-2026-05-26-feature-flags | phase:research
2026-05-26T11:01:24-06:00 | hook | agent:Explore | 12s | exit:0 | "find similar feature flag patterns" | job:j-2026-05-26-feature-flags | phase:research
```

**New line type — `lesson`** (written by `/job-lesson`):
```
2026-05-26T11:20:00-06:00 | lesson | knowledge | "Feature flags split into release toggles vs ops toggles" | job:j-2026-05-26-feature-flags | phase:research
```
Format: `timestamp | lesson | <category> | "<text>" | job:... | phase:...`

**Dashboard line for phase transitions** (written by `/job-phase`):
```
2026-05-26T11:35:00-06:00 | dashboard | phase-transition | research → design | job:j-2026-05-26-feature-flags
```

**OTel lines** (Plan 1's `parse-otel.ps1` writes these) gain the same trailing tags. Since OTel events themselves don't carry job/phase info, `/job-phase` transitions trigger `parse-otel.ps1` as a side effect — all events accumulated during the just-ended phase get tagged with the old phase before the env var flips for the new phase. This avoids timestamp-joining gymnastics.

### 4. Slash commands

| Command | What it does |
|---|---|
| `/job-start "<brief>" [--project <id>\|--no-project]` | Generate ID. Create job folder. Write `manifest.yaml` + `brief.md`. Set `$env:CAO_JOB_ID` + `$env:CAO_PHASE=research`. Auto-detect project: (1) `git remote get-url origin` → slugify host/repo; (2) else cwd folder name slugified; (3) `--no-project` skips. Overridable with `--project <id>`. |
| `/job-status` | Show active job's manifest + recent journal entries scoped to it. |
| `/job-list [--all\|--active\|--done]` | List jobs in `~/.claude/jobs/`. Defaults to active. |
| `/job-phase` *(no arg)* | Show current phase + what `next` would resolve to. |
| `/job-phase next` | Advance one step along default sequence. At `review`, prompts: *"Start `code.sprint-N+1` or `/job-phase done`?"*. Triggers `parse-otel.ps1` before flipping env var. |
| `/job-phase back` | Step back one. |
| `/job-phase <explicit>` | Jump to a named phase. Loop-backs use this; phase-log records `loop-back`. |
| `/job-phase done` | Close job. Clears env vars. Prompts: *"any final lessons?"* |
| `/job-resume <id>` | Re-load env vars from a job's manifest. Use after restarting Claude Code. |
| `/job-lesson <category> "<text>" [--scope universal\|project]` | Append to active job's `lessons.md` + write a `lesson` journal line. |
| `/consolidate-lessons` | Walk every job's `lessons.md`, append entries to the right KB file by category+scope, mark source entries `✓ consolidated YYYY-MM-DD`. Manual trigger. |

**Phase-transition prompts:** at `/job-phase next` and `/job-phase done`, Claude prompts: *"any lessons to record before moving on?"* This is the friction point that keeps the lesson capture habit alive.

### 5. Dashboard Jobs panel (v1, read-only)

New card on the main dashboard:

```
JOBS
🟢 j-2026-05-26-feature-flags    research      coding-agent-orchestrator    12 min   $0.04
🟢 j-2026-05-24-auth-rewrite     code.sprint-2 acme-api                      2 days   $1.82
⚫ j-2026-05-20-logging-fix      ✓ done        coding-agent-orchestrator    6 days   $0.31
```

Click a row → **`/jobs/<id>` drill-in view:**
- Rendered brief (markdown).
- Phase timeline from `phase-log.md` — visual sequence with timestamps + loop-back arrows.
- Journal filtered to entries tagged `job:<id>`, newest first.
- Lessons captured (read from `lessons.md`).
- Cost-so-far for the job; per-phase cost breakdown (preview of Plan 7's full debrief).

**Data sources:** `~/.claude/jobs/`, `~/.claude/model-routing-log.md` filtered by `job:` tag, `~/.claude/telemetry/events.jsonl` (Plan 1's OTel JSONL) filtered the same way.

**Polling:** Jobs list polls every 30 s (htmx). Drill-in view polls every 5 s for the journal slice + every 30 s for the rest, matching Plan 2's cadence.

**Out of scope for Plan 3** (lands in Plan 7 cockpit): new-job form, phase transitions from UI, lesson capture from UI, minimizable cards, drill-into-live-commands.

### 6. End-to-end example

You drop a brief:
```
/job-start "build a feature flag system for the orchestrator"
```

What happens:
1. Slug → ID: `j-2026-05-26-feature-flags`.
2. Auto-detect project from `git remote -v` → `coding-agent-orchestrator`.
3. Create folder, write `manifest.yaml` (with `current_phase: research`), write `brief.md`, create empty `phase-log.md` + `lessons.md`.
4. Set session env vars.
5. Append to phase-log: `created | research`.
6. Echo: *"Job j-2026-05-26-feature-flags started. Phase: research. What are you actually trying to solve?"*

You ramble. Claude refines. Every tool Claude calls is now journaled with `job:j-...` + `phase:research`.

Claude captures a lesson mid-research:
```
/job-lesson knowledge "Feature flags split into release toggles vs ops toggles"
```
→ Appended to `lessons.md` under `## research` + a `lesson` line written to the journal.

Claude (or you) advances:
```
/job-phase next
```
→ Triggers `parse-otel.ps1` so the just-completed research-phase OTel events get tagged `phase:research`. Updates `manifest.yaml` (`current_phase: design`). Updates `$env:CAO_PHASE`. Appends `transition | research → design` to `phase-log.md`. Writes a `dashboard | phase-transition` line to the journal. Echoes: *"Phase: design. Any lessons to record before continuing?"*

You restart Claude Code. Tomorrow:
```
/job-resume j-2026-05-26-feature-flags
```
→ Reads manifest, sets env vars, prints status. You pick up exactly where you left off.

Days later, after the job is done and a few others too:
```
/consolidate-lessons
```
→ Walks every job's `lessons.md`. The `knowledge` lesson above lands in `~/.claude/knowledge/projects/coding-agent-orchestrator/topics/feature-flags.md` with a `[j-2026-05-26-feature-flags]` source tag. The `user-pref` lesson lands in `~/.claude/knowledge/universal/user-prefs.md`. Source entries get `✓ consolidated 2026-05-30` so re-runs don't duplicate.

You open the dashboard. The Jobs panel shows the active jobs. Click into one → brief, phase timeline (with the visible `research → design` transition), filtered journal, lessons, cost-so-far.

## Error handling

| Failure | Behavior |
|---|---|
| Slash command run with no active job (`/job-status`, `/job-phase`, `/job-lesson`) | Friendly error: *"No active job. Use `/job-resume <id>` or `/job-list`."* |
| Invalid phase name in `/job-phase <name>` | Error + list of valid names. |
| `/job-start` when one is already active | Prompt: *"Job `<id>` is active. Suspend and start new, or `/job-resume` and continue?"* |
| `manifest.yaml` corrupted (bad YAML) | Backup as `manifest.yaml.bak.<timestamp>`. Regenerate skeleton from `phase-log.md`. Warn the user. |
| Hook crashes when reading env vars (one set, one missing) | Treat as untagged; write line in Plan 1 format. Log error to `~/.claude/hooks/log-tool-call.err.log`. Plan 1's graceful-degradation contract preserved. |
| `/job-lesson` with invalid category | Error + list of valid categories. |
| `/consolidate-lessons` when KB dirs don't exist | Create them; proceed. |
| Project ID has filesystem-unsafe characters | Slugify (lowercase, hyphens, alphanumeric). |
| Two Claude Code sessions both `/job-start` | Env vars are per-session, so each has its own active job — but the file-level manifest's `current_phase` will appear inconsistent across them. Documented limitation in v1. |
| `parse-otel.ps1` invocation at `/job-phase next` fails | Phase transition still completes (manifest + env var + phase-log + journal line). Warn user; OTel events for the just-ended phase may end up tagged with the next phase. |

## Testing strategy

- **`scripts/test-jobs.ps1`** — full lifecycle test: `start → next → next → back → next → done`, verify manifest/phase-log/journal contents at each step. Verify env vars are set/cleared correctly.
- **Extension to `scripts/test-hook.ps1`** — set `$env:CAO_JOB_ID` + `$env:CAO_PHASE`, feed canned tool event, verify trailing `job:` + `phase:` fields appear. Also test with env vars unset → no trailing fields (backward compat).
- **`scripts/test-consolidate-lessons.ps1`** — set up a fake job with mixed-category lessons, run consolidate, verify entries land in correct KB files with correct format, source entries are marked consolidated, second run is a no-op.
- **`scripts/test-job-resume.ps1`** — start a job, clear env vars (simulating restart), `/job-resume <id>`, verify env vars restored from manifest.
- **`dashboard/tests/test_jobs.py`** — Jobs panel route lists from a fake jobs dir; drill-in route renders brief + phase-log + filtered-journal + lessons + cost; per-phase cost aggregation correctness.
- **End-to-end smoke** (eyeball, not automated): real `/job-start`, two real tool calls, `/job-phase next`, verify dashboard reflects within 30 s.

## Success criteria

- After `/job-start`, the job folder exists with manifest, brief, empty phase-log, empty lessons.md.
- Every tool call inside Claude Code while a job is active appears in the journal with `job:` + `phase:` trailing tags.
- Every tool call when **no** job is active appears in the journal in the unchanged Plan 1 format.
- `/job-phase next` updates manifest + env var + phase-log atomically. `parse-otel.ps1` is triggered before the env-var flip.
- `/job-resume` after a Claude Code restart restores env vars correctly — work continues uninterrupted.
- `/job-lesson` writes to both the job's `lessons.md` AND the journal in one shot.
- `/consolidate-lessons` moves lessons into the correct KB files based on category + scope, with source-job traceability, and is safely re-runnable.
- Dashboard Jobs panel reflects state changes within 30 s of any change.
- Drill-in view shows the full job context for any job ID.
- Bootstrap migrates Plan 1's `model-routing.md` → `knowledge/universal/routing.md` without data loss.

## File layout (repo)

```
D:\Dev\coding-agent-orchestrator\
├── docs/
│   └── superpowers/
│       └── specs/
│           └── 2026-05-26-plan3-job-scaffold-design.md   ← this file
├── commands/
│   ├── job-start.md
│   ├── job-status.md
│   ├── job-list.md
│   ├── job-phase.md
│   ├── job-resume.md
│   ├── job-lesson.md
│   └── consolidate-lessons.md
├── scripts/
│   ├── hooks/
│   │   └── log-tool-call.ps1            (extended in this plan)
│   ├── job-lib.ps1                      (shared functions: read/write manifest, slugify, etc.)
│   ├── consolidate-lessons.ps1          (called by slash command)
│   ├── parse-otel.ps1                   (extended to read env vars + tag)
│   ├── test-jobs.ps1
│   ├── test-job-resume.ps1
│   ├── test-consolidate-lessons.ps1
│   └── test-hook.ps1                    (extended)
└── dashboard/
    ├── readers/
    │   ├── journal.py                   (extended to parse job:/phase: tags)
    │   └── jobs.py                      (new — reads job folders)
    ├── routers/
    │   └── jobs.py                      (new — /jobs list + /jobs/<id> drill-in)
    ├── templates/
    │   ├── index.html                   (extended — Jobs panel card)
    │   ├── job_detail.html              (new — drill-in)
    │   └── partials/
    │       └── jobs_list.html           (new)
    └── tests/
        └── test_jobs.py                 (new)
```

After bootstrap runs (Section below), deployed layout under `~/.claude/`:

```
~/.claude/
├── settings.json                      (unchanged from Plan 1)
├── hooks/
│   └── log-tool-call.ps1              (extended)
├── commands/
│   ├── log-routing.md                 (existing)
│   ├── consolidate-routing.md         (existing)
│   ├── job-start.md                   (new)
│   ├── job-status.md                  (new)
│   ├── job-list.md                    (new)
│   ├── job-phase.md                   (new)
│   ├── job-resume.md                  (new)
│   ├── job-lesson.md                  (new)
│   └── consolidate-lessons.md         (new)
├── telemetry/
│   └── events.jsonl                   (existing)
├── model-routing-log.md               (existing, line format extended)
├── jobs/                              (new)
│   └── <job-id>/
└── knowledge/                         (new)
    ├── universal/
    │   ├── routing.md                 (migrated from ~/.claude/model-routing.md)
    │   ├── user-prefs.md              (empty seed)
    │   ├── reasoning.md               (empty seed)
    │   ├── mistakes.md                (empty seed)
    │   ├── winners.md                 (empty seed)
    │   └── topics/
    └── projects/
```

## Bootstrap changes

`scripts/bootstrap.ps1` gains four idempotent steps:

1. **Create `~/.claude/jobs/` and `~/.claude/knowledge/{universal,projects}/`** if missing.
2. **Migrate `~/.claude/model-routing.md` → `~/.claude/knowledge/universal/routing.md`** — move, not copy. Update `/consolidate-routing` command to write to the new path. Existing consumers re-pointed via bootstrap re-run.
3. **Deploy new slash commands** from `commands/` → `~/.claude/commands/`.
4. **Deploy extended hook** from `scripts/hooks/log-tool-call.ps1` → `~/.claude/hooks/` (overwrite Plan 1's version; the extension is purely additive).
5. **Seed empty KB files** with one-line headers so consolidation doesn't have to create-on-write.

## Decisions made / open

- **Phase model:** four phases (`research`, `design`, `code.sprint-N`, `review`, terminal `done`). Inner activities are dispatch patterns inside phases, not state changes. Decided.
- **Phase transitions are slash commands** (`/job-phase next`, `/job-phase <explicit>`) — bundles three atomic actions (manifest, env var, phase-log). Decided.
- **Env-var-based phase tagging in hook** — `$env:CAO_JOB_ID` + `$env:CAO_PHASE`. Backward-compatible when unset. Decided.
- **OTel tagging via `parse-otel.ps1` trigger at phase transitions** — avoids timestamp-joining. Decided.
- **Two-layer KB** — `universal/` + `projects/<id>/` under `~/.claude/knowledge/`. Decided.
- **Lesson categories:** `routing`, `user-pref`, `reasoning`, `mistake`, `winner`, `convention`, `decision`, `architecture`, `knowledge`. Default scope per category, overridable with `--scope`. Decided.
- **Project identification:** auto-detect from git remote / cwd at `/job-start`; manual override with `--project` / `--no-project`. Decided.
- **Consolidation is manual** (`/consolidate-lessons`), not scheduled. Decided.
- **Migration of Plan 1's `model-routing.md` → `knowledge/universal/routing.md`** — move, not copy. Decided.
- **Concurrent jobs in one Claude Code session:** not supported in v1; per-session env vars mean each session can only have one active job. Documented limitation.
- **Dashboard interactivity** — Plan 3 ships read-only Jobs panel; full cockpit (new-job form, phase transitions from UI, lesson capture from UI) is Plan 7.

## Decision history

- **2026-05-22 (Plan 1):** observation layer shipped — hooks, OTel, journal, routing catalog, `/log-routing`, `/consolidate-routing`.
- **2026-05-23 (Plan 2):** dashboard shipped — FastAPI + htmx at `localhost:8765`, leaderboard, spend, Ollama/LM Studio controls.
- **2026-05-26 (this spec):** orchestrator vision expanded from "observation only" to phased pipeline with multi-model dispatch. Approach C (Claude-as-orchestrator + persistent job files + dashboard cockpit) chosen over Approach A (slash-command stack with no persistence) and Approach B (Python daemon state machine). Phase model debated: initially expanded to seven sub-phases inside a `brainstorm` macro; collapsed back to four phases (`research`/`design`/`code`/`review`) after the user flagged complexity — inner iterations now happen *inside* phases as dispatch patterns rather than as phase flips. Knowledge base architecture added: two-layer (`universal/` + `projects/<id>/`) under `~/.claude/knowledge/`, populated by `/job-lesson` capture and `/consolidate-lessons` rollup, with Plan 8 deferred for embedding-based retrieval and auto-injection.
