# coding-agent-orchestrator

Claude Code as a command-and-control layer for a fleet of coding LLMs.
Adopts [claude-octopus](https://github.com/nyldn/claude-octopus) as the dispatch
layer; builds observation (hooks, OpenTelemetry, slash commands, journal,
catalog) and — in Plan 2 — a live web dashboard on top.

**Status:** v1.0 — Plans 1, 2, 3, 4, 5, 5b, 5c, 6, 7, 8 + Decision Loop + Cost Ledger shipped.

→ **Start using it:** [`docs/getting-started.md`](docs/getting-started.md)
→ **What's next:** [`docs/roadmap.md`](docs/roadmap.md) (tracked on [Project #5](https://github.com/users/Ryfter/projects/5))

## Quick start

```powershell
# 1. Install Octopus (one-time)
claude plugin marketplace add https://github.com/nyldn/plugins.git
claude plugin install octo@nyldn-plugins

# 2. Bootstrap this repo's observation layer
git clone <this repo> D:\Dev\coding-agent-orchestrator
cd D:\Dev\coding-agent-orchestrator
pwsh -NoProfile -File scripts\bootstrap.ps1

# 3. Enable OTel export in your PowerShell profile
notepad $PROFILE
# add: . $HOME\.claude\otel-env.ps1

# 4. Restart Claude Code and use it normally.
```

## What you get (Plan 1)

- `~/.claude/hooks/log-tool-call.ps1` — PostToolUse hook that journals every
  model dispatch.
- `~/.claude/model-routing-log.md` — append-only journal with three line types
  (`hook`, `otel`, `note`).
- `~/.claude/model-routing.md` — catalog of every model you can route to, with
  strengths/weaknesses and pricing.
- `~/.claude/commands/log-routing.md` — `/log-routing <model> <obs>` for
  qualitative notes.
- `~/.claude/commands/consolidate-routing.md` — `/consolidate-routing` to
  periodically promote journal observations into the catalog.
- `scripts/parse-otel.ps1` — converts Claude Code's OTel JSONL events into
  journal `otel` lines with cost computation.

## What you get (Plan 2)

A live web **dashboard** at `http://localhost:8765`.

- Real-time activity feed, today's spend, and a model leaderboard drawn from
  the journal.
- Ollama controls — stop a running model from the UI.
- LM Studio integration — live model list, load/unload controls.
- Dark-mode CSS (GitHub palette), Chart.js spend sparklines.
- `dashboard/` Python package (FastAPI + Jinja2); 33 integration tests.

## What you get (Plan 3)

A persistent **job** model with phase tracking, lesson capture, and a knowledge
base — all surfacing in the dashboard.

- `~/.claude/jobs/<id>/` — per-job folders with manifest, brief, phase-log,
  lessons.
- `~/.claude/knowledge/` — two-layer KB (`universal/` + `projects/<id>/`)
  populated by `/job-lesson` capture and `/consolidate-lessons` rollup.
- Slash commands:
  - `/job-start "<brief>"` — open a new job, start phase tracking
  - `/job-status`, `/job-list` — see what's active / past
  - `/job-phase next|back|done|<name>` — advance, step back, or close
  - `/job-resume <id>` — continue a job after restarting Claude Code
  - `/job-lesson <category> "<text>"` — capture a lesson while you work
  - `/consolidate-lessons` — promote lessons into the KB
- Hook + `parse-otel.ps1` now tag every journal line with `job:` + `phase:`
  whenever a job is active.
- Dashboard adds a **Jobs panel** + drill-in route at `/jobs/<id>` with
  per-phase cost breakdown.

See [`docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md`](docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md).

## What you get (Plan 4)

A **fleet** of dispatchable LLM providers — paid CLIs, free CLIs, and local
models across machines — all invokable from one command.

- `~/.claude/fleet.yaml` — lean registry: name, kind (cli|http), how to invoke,
  cost tier, optional env (the multi-machine / Tailscale / SSH-tunnel knob).
- `/fleet doctor` — health-check every enabled provider (binary on PATH? remote
  host reachable? HTTP endpoint alive?).
- `/fleet test <name> "<prompt>" [--model <m>]` — dispatch a prompt to any fleet
  member and see the response. Journaled with `fleet | <name> | …`, picking up
  the active job's `job:`/`phase:` tags.
- `/fleet list` — quick registry summary.
- Hybrid dispatcher: `kind: cli` providers run a `command_template`; `kind: http`
  providers (LM Studio) use a per-provider script under `~/.claude/scripts/fleet/`.

Adding a standard CLI provider is a 5-line `fleet.yaml` edit. Adding an HTTP
provider is one new `scripts/fleet/<name>.ps1` + one `fleet.yaml` entry.

**Known limitation:** prompts are substituted into the command template; prompts
containing double-quotes may break CLI invocation (Plan 5 hardens this via stdin).

See [`docs/superpowers/specs/2026-05-26-plan4-fleet-design.md`](docs/superpowers/specs/2026-05-26-plan4-fleet-design.md).

## What you get (Plan 5)

Concurrent multi-model **research ensembles**. Fan one prompt out to several
fleet members at once, then Claude synthesizes their responses.

- `/ensemble "<prompt>" [--providers a,b,c | --tier free,local]` — job-optional.
  Runs the roster concurrently (process-isolated `Start-Job`s), collects each
  response as a file, Claude writes a synthesis. Standalone runs land in
  `~/.claude/ensembles/<timestamp>/`.
- `/research "<question>"` — job-bound wrapper: writes to the active job's
  `phases/research/ensemble-<timestamp>/`, warns if you're not in the research
  phase, and nudges you to capture a lesson afterward.
- Roster precedence: `--providers` > `--tier` > `research_default` (a new
  top-level key in `fleet.yaml`).
- A failing or slow provider never sinks the ensemble — partial synthesis still
  happens; stragglers are killed at the timeout (default 300s).
- Per-provider `fleet | …` journal lines are written serially by the parent
  (tagged with the active job's `job:`/`phase:`), so concurrent runs never
  corrupt the journal.

See [`docs/superpowers/specs/2026-05-29-plan5-research-ensemble-design.md`](docs/superpowers/specs/2026-05-29-plan5-research-ensemble-design.md).

## What you get (Decision Loop)

A self-improvement loop on top of Plan 3's KB. Every significant decision I make
is auto-captured as a structured record (decision · alternatives · rationale ·
my confidence · revisit-if). Two layers consolidate over time:

- **Per-project guidance** — `~/.claude/knowledge/projects/<id>/decision-guidance.md`
- **Universal guidance** — `~/.claude/knowledge/universal/decision-guidance.md`
  (a pattern only promotes here once it has positive feedback in ≥2 projects)

Commands:
- `/decision-feedback <id> "<text>" [--outcome worked|didnt|mixed] [--urgent]` —
  attach human feedback. Silence = approval; negative outcome flags the record.
- `/consolidate-decisions` — distill records + feedback into the guidance docs,
  recording deviations + their reasons.
- `/project-init [--re-calibrate]` — on a new project, surface universal
  guidance and capture per-project overrides.
- `/job-phase done` now lists the just-closed job's decisions and prompts for
  retro feedback (non-blocking).

Capture is **discipline-enforced**, not magical — the rule lives in this
project's `CLAUDE.md` and is always loaded into context. Opt-out at any time
via `~/.claude/decisions-off` (global) or
`~/.claude/knowledge/projects/<id>/decisions-off` (per-project).

See [`docs/superpowers/specs/2026-05-29-decision-loop-design.md`](docs/superpowers/specs/2026-05-29-decision-loop-design.md).

## What you get (Plan 5b)

**Six Thinking Hats** preset on the ensemble primitive. Examines a question
through six fixed lenses (White / Red / Black / Yellow / Green / Blue), each
dispatched concurrently with its own role-prefixed prompt.

- `/six-hats "<question>" [--providers a,b,c]` — job-optional. Builds six
  role-prefixed prompts and dispatches them in parallel via the new
  `Invoke-FleetEnsembleTasks` heterogeneous-task primitive.
- Provider **rotation** across hats: 1-provider roster → all six hats use it;
  6+ providers → each hat unique; anything in between rotates.
- Claude (orchestrator) produces a Blue-Hat synthesis covering each hat's
  contribution, tensions (Black vs Yellow), and a recommended next move.

See [`docs/superpowers/specs/2026-05-30-plan5b-six-hats-design.md`](docs/superpowers/specs/2026-05-30-plan5b-six-hats-design.md).

## What you get (Plan 5c)

**LLM Council** — two-round deliberation where each member answers, then sees
the *other* members' answers and refines. Claude chairs the synthesis.

- `/council "<question>" [--providers a,b,c]` — job-optional. Council size
  capped at 5; quorum floor 2 surviving R1 members.
- **Round 1** = independent answers per member.
- **Round 2** = each member reads the OTHER members' R1 answers and refines.
- A failed-R1 member still runs R2 (with original question + surviving peers'
  content). Below quorum → council aborts before R2.
- Output layout: `<out>/round1/<member>.md`, `<out>/round2/<member>.md`,
  `<out>/synthesis.md` (chair's recommended answer).

See [`docs/superpowers/specs/2026-05-30-plan5c-council-design.md`](docs/superpowers/specs/2026-05-30-plan5c-council-design.md).

## What you get (Plan 6)

**Code phase** — turn a finalized spec into working code by decomposing it,
dispatching parallel implementation in isolated git worktrees, then merging.

- `/code-decompose [<spec-path>]` — Claude reads the spec, proposes N
  subtasks (id, title, files_touched, depends_on), and on confirmation
  writes `<job>/phases/<sprint>/subtasks.json`. Cycles rejected.
- `/code-parallel [--only t1,t3]` — topo-sort + dispatch one Agent subagent
  per task via Claude Code's `Agent(isolation: worktree, ...)`. Independent
  tasks dispatched in parallel (one Agent batch); dependent tasks run after
  their prereqs complete. Manifest records each worktree + branch + diff.
- `/code-merge [--apply] [--from t3]` — surfaces likely conflicts via
  `files_touched` overlap before applying; cherry-picks task branches in
  dependency order; stops on first conflict (resume by re-running with
  `--from <task-id>`).
- Journal gets a new `code | parallel | <job> | sprint:… | tasks:N | ok:K | err:E`
  aggregate line per dispatch batch.

See [`docs/superpowers/specs/2026-05-30-plan6-code-phase-design.md`](docs/superpowers/specs/2026-05-30-plan6-code-phase-design.md).

## What you get (Plan 7)

**Multi-project command center** on top of the Plan 2 dashboard. Adds
project-portfolio visibility across every project in `~/.claude/knowledge/projects/`.

- `GET /projects` — portfolio list: per-project cost total, active jobs,
  decisions, last activity. Sorted by activity.
- `GET /projects/{id}` — drill-in: cost ledger (last 10 entries), all jobs
  (filtered to project), every decision (with confidence + flags),
  every ensemble / six-hats / council run.
- Home page gains a top portfolio panel (top 5 projects, htmx 60s refresh).
- Read-only. `ROUTING_KB_ROOT` env override mirrors `ROUTING_JOURNAL` /
  `ROUTING_JOBS_ROOT` patterns. No new dependencies — hand-rolled YAML
  front-matter parser matches the existing readers/jobs.py style.

See [`docs/superpowers/specs/2026-05-30-plan7-command-center-design.md`](docs/superpowers/specs/2026-05-30-plan7-command-center-design.md).

## What you get (Plan 8)

**Embedding-based semantic search** over the knowledge base. Local-only:
Ollama `nomic-embed-text` for embeddings (274 MB one-time pull), numpy flat
cosine search — no binary deps, sub-millisecond per query at this scale.

- `kb/` Python package — `chunker.py` (markdown-aware), `embedder.py`
  (Ollama HTTP client, L2-normalised vectors), `store.py` (numpy `.npz`
  flat store with scope filters), `index.py` (mtime-incremental walker),
  `search.py` (top-k cosine).
- `/kb-index [--full] [--scope universal|<project-id>|all]` — build/update
  the index. Default: incremental by mtime. Unchanged corpus → 0 embed calls.
- `/kb-search "<query>" [--k N] [--scope ...]` — top-k semantic search,
  scope-filterable to universal-only or a single project.
- `/research` now **pre-fetches** top-3 KB chunks before fanout and prepends
  them as "Relevant prior knowledge" on each provider's prompt — small
  built-in RAG for the research phase.
- Dashboard adds a **KB Search panel** on the home page + `GET /kb/search`
  JSON endpoint for external integration.
- Index lives at `~/.claude/knowledge/.index/` (vectors.npz + metadata.json
  + manifest.json with per-source mtime tracking).
- Bootstrap nudges `ollama pull nomic-embed-text` if missing.

See [`docs/superpowers/specs/2026-05-30-plan8-kb-embeddings-design.md`](docs/superpowers/specs/2026-05-30-plan8-kb-embeddings-design.md).

## Architecture

See [`docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md`](docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md).

## Tests

```powershell
# Plan 1 / observation
pwsh -NoProfile -File scripts\test-hook.ps1
pwsh -NoProfile -File scripts\test-otel-parser.ps1
pwsh -NoProfile -File scripts\test-bootstrap.ps1
# Plan 3 / jobs + KB
pwsh -NoProfile -File scripts\test-job-lib.ps1
pwsh -NoProfile -File scripts\test-jobs.ps1
pwsh -NoProfile -File scripts\test-consolidate-lessons.ps1
# Plan 4 / fleet
pwsh -NoProfile -File scripts\test-fleet-lib.ps1
pwsh -NoProfile -File scripts\test-fleet-dispatch.ps1
pwsh -NoProfile -File scripts\test-fleet-doctor.ps1
# Plan 5 / research ensemble
pwsh -NoProfile -File scripts\test-fleet-ensemble.ps1
# Plan 5b / Six Thinking Hats
pwsh -NoProfile -File scripts\test-six-hats.ps1
# Plan 5c / LLM Council
pwsh -NoProfile -File scripts\test-council.ps1
# Plan 6 / code phase
pwsh -NoProfile -File scripts\test-code-lib.ps1
# Plan 2 + Plan 7 + Plan 8 / dashboard + kb (Python)
python -m pytest dashboard/tests/ kb/tests/ -q
```
