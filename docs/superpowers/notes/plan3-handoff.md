# Plan 3 Handoff Notes

**Audience:** Any LLM or developer continuing this work in a future session. Read this first to orient yourself.

**Date:** 2026-05-26
**Branch:** `plan3/job-scaffold`
**Status:** Implementation complete, all tests green, PR-ready.

---

## The 30-second picture

`coding-agent-orchestrator` is Kevin Rank's personal orchestration layer for a fleet of coding LLMs, built on top of Claude Code. It evolves in numbered Plans:

| Plan | Status | What it adds |
|---|---|---|
| 1 | shipped (master) | Observation layer: PostToolUse hook, OTel exporter, append-only `~/.claude/model-routing-log.md` journal, `~/.claude/model-routing.md` catalog, `/log-routing` + `/consolidate-routing` slash commands |
| 2 | shipped (master) | Local FastAPI + htmx dashboard at `http://localhost:8765` — leaderboard, today's spend, Ollama/LM Studio controls, Chart.js doughnut |
| **3** | **this branch** | **Job lifecycle + KB foundation (the thing this doc describes)** |
| 4 | not started | Fleet config + multi-machine local Ollama access — the actual dispatchable provider registry |
| 5 | not started | Research phase wiring (ensemble across fleet, 6-Hats / LLM Council primitives) |
| 6 | not started | Code phase (decompose + parallel worktrees + per-provider farm-out) |
| 7 | not started | Review phase (Claude + Codex on the diff) + dashboard cockpit polish (minimizable cards, drill-into-live-commands, end-of-job debrief) |
| 8 | not started | Learning loop — embedding-based KB retrieval + auto-injection of relevant lessons at job/phase start |

The umbrella vision is **Approach C** (chosen during brainstorming): Claude Code itself IS the orchestrator. Persistent job files on disk are the source of truth. The dashboard is a cockpit that observes (read-only in Plan 3; interactive in Plan 7). Fleet members are CLI-first (claude, codex, antigravity = Gemini CLI, gh copilot, opencode, local Ollama). Paid API plans are accessed via their CLIs, not direct APIs.

## What Plan 3 actually delivers

A *job* is now a real, persistent thing on disk. Every tool call Claude makes inside an active job is tagged with `job:` + `phase:` in the journal. Lessons captured during a job feed a two-layer knowledge base. The dashboard surfaces a Jobs panel and a drill-in per job.

### Phase model

Four phases. Inner activities (brain-dump, refine, alternatives, sanity-check) happen INSIDE a phase as dispatch patterns; they do not flip the phase label.

```
research  →  design  →  code.sprint-1  →  review  →  code.sprint-2  →  review  →  …  →  done
```

`/job-phase next` walks this default sequence. Loop-backs (e.g., review surfaces a gap → jump back to `design`) use explicit names and are recorded as `loop-back` entries in `phase-log.md`.

### Slash commands shipped

| Command | Purpose |
|---|---|
| `/job-start "<brief>" [--project <id> \| --no-project]` | Generate ID, create job folder, set state file, write `manifest.yaml` + `brief.md` + empty `phase-log.md`/`lessons.md` |
| `/job-status` | Show current job's manifest + recent journal entries tagged with this job |
| `/job-list [--all\|--active\|--done]` | List jobs |
| `/job-phase` *(no arg)* | Show current phase + what `next` would resolve to |
| `/job-phase next\|back\|done\|<explicit>` | Atomic transition (manifest + state file + phase-log + journal line) |
| `/job-resume <id>` | Re-load state file from a job's manifest (use after restarting Claude Code) |
| `/job-lesson <category> "<text>" [--scope universal\|project]` | Append to active job's `lessons.md` + write a `lesson` line to the journal |
| `/consolidate-lessons` | Walk every job's `lessons.md`, route entries to KB files by category+scope, mark consolidated |

### Key data contracts (memorize these — they're the API surface for Plans 4-8)

**State file** at `~/.claude/current-job.json`:
```json
{ "job_id": "j-2026-05-26-feature-flags", "phase": "research" }
```
- Source of truth for "which job/phase is active" across processes.
- Written by `/job-start`, `/job-phase`, `/job-resume`. Deleted by `/job-phase done`.
- Read by the hook + `parse-otel.ps1` on every invocation.
- Missing/corrupted → no tagging (backward-compatible with Plan 1).
- **Why a file, not env vars:** Claude Code slash-command subprocesses cannot mutate the parent process's env. A file is the only reliable cross-process signal.

**Journal line format** (extends Plan 1/2):
```
# Plan 1/2 (still valid when no job active):
ISO-ts | hook    | <target>                | <Ns> | exit:N [ | "<brief>" ]
ISO-ts | otel    | <model>                 | in:N out:N | $cost | api_request
ISO-ts | note    | <target>                | "<text>"

# Plan 3 additions:
... [any of the above] | job:<id> | phase:<phase>       ← trailing tags
ISO-ts | lesson  | <category>              | "<text>" | job:<id> | phase:<phase>
ISO-ts | dashboard | phase-transition      | <old> → <new> | job:<id>

# Plan 3 with scope on lessons.md only (not journal):
ISO-ts | <category> | <scope> | "<text>"   ← inside per-job lessons.md
```

Rules:
- `job:` and `phase:` are always TRAILING, always at the end.
- Pipe-in-payload is sanitized to `¦` (Plan 2 rule, still applies).
- Lessons.md uses the new 4-field format with explicit scope; consolidator tolerates old 3-field format too (backward-compat).

**Job folder layout** at `~/.claude/jobs/<job-id>/`:
```
j-2026-05-26-feature-flags/
├── manifest.yaml          ← current state (single source of truth)
├── brief.md
├── phase-log.md           ← append-only transition history
├── lessons.md             ← raw capture, consolidated later
└── phases/                ← outputs land here (Plans 5-7 fill in)
    ├── research/  design/  code/{sprint-1/sprint-2/...}/  review/
```

**Knowledge base layout** at `~/.claude/knowledge/`:
```
universal/                ← cross-project
  ├── routing.md          ← MIGRATED from ~/.claude/model-routing.md
  ├── user-prefs.md
  ├── reasoning.md
  ├── mistakes.md
  ├── winners.md
  └── topics/
projects/<project-id>/    ← per-project
  ├── conventions.md
  ├── mistakes.md
  ├── winners.md
  ├── architecture.md
  ├── decisions.md
  └── topics/
```

**Lesson categories → default scope:**

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
| `knowledge` | project | `projects/<id>/topics/general.md` |

Override per-lesson with `--scope universal` or `--scope project` on `/job-lesson`. The override is persisted in the per-job `lessons.md` line and honored by `/consolidate-lessons`.

## Why these decisions

If you're picking this up, the answer to "why is it shaped this way?" is usually one of:

1. **Claude Code is the orchestrator, not a daemon.** Brainstorming considered a Python state-machine daemon (Approach B) and rejected it: too much code, duplicates what Claude Code already does well, harder to debug. Approach C (Claude orchestrates, persistent job files are the contract) was chosen. The job files are designed so a daemon could later pick them up — escape hatch for Plan 4+ if needed.
2. **CLI-first fleet** (not direct APIs). Kevin pays for Claude, Codex, Gemini (Antigravity CLI), GitHub Copilot. Each has a CLI. Direct APIs / OpenRouter are deferred (Plan 4 may add them as fleet expansions).
3. **State file > env vars** (see "Why a file" above).
4. **Four phases, not seven** (brainstorm was originally expanded into 7 sub-phases). The 7-phase model was rejected as overengineered. Inner activities live INSIDE a phase as dispatch patterns; analytics granularity is sufficient at the 4-phase level. If finer cost analytics are wanted later, add an optional `activity:` tag to journal lines — orthogonal to phase.
5. **Two-layer KB** (universal + per-project). User explicitly requested this. Universal = cross-project preferences, reasoning, routing. Per-project = repo-specific conventions, mistakes, architecture.
6. **Hook tags are TRAILING and optional.** Backward compat with Plan 1/2 lines is mandatory — they must still parse, and untagged lines must still be written when no job is active.
7. **`/consolidate-lessons` is manual, not scheduled.** Same rationale as Plan 1's `/consolidate-routing`. User triggers it when they think enough has accumulated.

## What's intentionally NOT in Plan 3 (deferred)

- **Dispatch to fleet members.** No actual multi-model dispatch happens yet. Plans 5-7 do that.
- **Fleet config.** `~/.claude/fleet.yaml` doesn't exist yet. Plan 4.
- **Ensemble, 6 Hats, LLM Council.** Plan 5.
- **Decompose + farm-out coding.** Plan 6.
- **Claude+Codex pair review.** Plan 7.
- **Embedding-based KB retrieval / auto-injection.** Plan 8.
- **Cockpit interactivity** (submit jobs from UI, phase buttons, minimizable cards, drill-into-live-commands). Plan 7.
- **Concurrent jobs in one Claude Code session.** Single state file means one active job at a time. Documented v1 limitation.
- **`manifest.yaml` corruption recovery.** Spec mentions auto-regenerate from phase-log; not implemented. Edge case.

## Known follow-ups (small)

These were flagged in the final review but accepted as non-blockers:

- `dashboard/templates/job_detail.html` uses a `setTimeout(location.reload, 30000)` for drill-in polling (pragmatic — Plan 7 will replace with proper htmx-partial polling on a 5s/30s split).
- Brief is rendered as `<pre>`, not Markdown. Plan 7 enhancement.
- `'abandoned'` status is in the manifest schema but no command sets it. Plan 7.
- `scripts/parse-otel.ps1` and `/consolidate-routing` still default to `~/.claude/model-routing.md` (which is now the migrated sentinel `.migrated` file, but the path defaults haven't been retargeted). Cosmetic; both still work because bootstrap migrates correctly.
- `ConvertTo-JobSlug` uses `-First 5` tokens, not `-First 4` as spec originally said — the plan's own test cases required 5 tokens for one example, so the implementer correctly chose 5.

## How to verify it works (E2E)

After bootstrap has run (deploys hooks, scripts, slash commands, creates dirs):

```powershell
# 1. Run all tests — should all be green
pwsh -NoProfile -File scripts/test-job-lib.ps1
pwsh -NoProfile -File scripts/test-jobs.ps1
pwsh -NoProfile -File scripts/test-hook.ps1
pwsh -NoProfile -File scripts/test-otel-parser.ps1
pwsh -NoProfile -File scripts/test-consolidate-lessons.ps1
python -m pytest dashboard/tests/ -v
```

Manual smoke (from inside a Claude Code session in the repo):
1. `/job-start "smoke test plan 3"` — verify `~/.claude/jobs/j-<today>-smoke-test-plan-3/` exists, `current-job.json` has the values.
2. Run any tool (e.g., `ls` via Bash). Check `~/.claude/model-routing-log.md` last line — should end with ` | job:j-… | phase:research`.
3. Open `http://localhost:8765` — Jobs panel shows the new job.
4. Click into it — drill-in shows brief, phase timeline, empty lessons, $0 cost.
5. `/job-lesson knowledge "smoke test note"` — lesson appears in drill-in.
6. `/job-phase next` — phase flips to `design`. Dashboard reflects within 30s.
7. `/job-phase done` — status flips, state file removed.
8. `/consolidate-lessons` — knowledge file at `~/.claude/knowledge/projects/coding-agent-orchestrator/topics/general.md` contains the lesson.

## File guide for the next person

**Most important to understand first:**
- `docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md` — the full design
- `docs/superpowers/plans/2026-05-26-plan3-job-scaffold.md` — the 19-task implementation plan
- `scripts/job-lib.ps1` — all the shared PowerShell logic (~250 lines, single file by design)
- `commands/job-phase.md` — the most complex slash command, study to understand transition semantics

**Less important but useful:**
- `scripts/consolidate-lessons.ps1` — KB routing logic, including the optional scope-override regex
- `dashboard/readers/jobs.py` — Python equivalent of the manifest/phase-log/lessons parsers; reuses the patterns from `journal.py`
- `scripts/bootstrap.ps1` Steps 5b/5c/5d — Plan 3's bootstrap additions; the migration logic is in 5d

## If you want to start Plan 4

Plan 4 adds `~/.claude/fleet.yaml` and wraps each CLI provider. Suggested first slice:
1. Define `fleet.yaml` schema (provider name, kind=local|remote|cli, command template, capabilities, cost tier, host).
2. Add `scripts/fleet-doctor.ps1` that probes each provider and reports health.
3. Add second-computer Ollama: `OLLAMA_HOST=http://other-machine:11434 ollama list` should appear in fleet.
4. Update `dashboard/main.py` to show a Fleet panel beside Jobs.

Plan 4 unblocks Plan 5 (research ensemble) which dispatches across the fleet. Plans 5-7 are where the actual multi-model work begins.

---

*If you found anything in this handoff confusing or wrong, fix it. This document is meant to evolve.*
