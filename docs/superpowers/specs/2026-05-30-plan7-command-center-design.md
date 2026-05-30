# Plan 7 — Multi-Project Command Center Dashboard — Design

**Date:** 2026-05-30
**Status:** Authored autonomously per user direction
**Author:** Claude (with autonomous design decisions logged via decisions-lib)
**Predecessors:** Plan 2 (dashboard foundation), Plan 3 (jobs), Plan 5/5b/5c (ensembles), Decision Loop, Cost Ledger
**Successors:** Plan 8 (embedding-based KB retrieval)

---

## Umbrella context

Plan 2 shipped a single-project dashboard: today's spend, leaderboard, activity feed, jobs list. Since then we've added per-project knowledge bases, decisions, cost ledgers, and ensemble runs — all stored under `~/.claude/knowledge/projects/<id>/`. Plan 7 makes the dashboard **project-aware** so you can see the whole portfolio at once.

```
Plan 2  ── single-tenant dashboard (one journal, one job tree)
Plan 7 (this) ── multi-project command center
                 ├─ project list with portfolio totals
                 ├─ per-project drill-in (jobs, decisions, costs, ensembles)
                 └─ project filter on the activity feed
Plan 8  ── KB embeddings + semantic retrieval (Plan 7 surfaces them)
```

## Purpose

A "command center" landing view that answers, at a glance:
- **Which projects am I running?** (list, with last activity)
- **Where is my money going?** (per-project cost totals + this-month delta)
- **What's in flight per project?** (active jobs per project)
- **What decisions has each project made?** (count + recent decisions)
- **What ensembles ran where?** (recent /ensemble, /six-hats, /council runs per project)
- **What's happening right now?** (journal feed, with a project filter)

## Non-goals (deferred)

- **Real-time cross-project notifications.** Plan 8 if at all.
- **Project archival workflow.** Out of scope — a project is "current" if it has a `~/.claude/knowledge/projects/<id>/` directory.
- **Editing project metadata from the UI.** Read-only Plan 7. Editing (rename, archive, set color) is later.
- **Per-project ACLs / multi-user.** Local-only tool.
- **Charts/graphs.** Plan 7 is tables + small numbers. Charts are Plan 8.
- **Ensemble synthesis preview pane** inside the dashboard. Plan 7 just lists; opening the directory shows the synthesis.

## Architecture overview

```
~/.claude/
├── knowledge/projects/<project-id>/    ← project root
│   ├── cost.md                          (cost-lib ledger)
│   ├── decisions/d###-*.md              (decisions-lib records)
│   └── decision-guidance.md             (project-init seed)
├── jobs/<job-id>/manifest.yaml          ← `project: <project-id>` field
├── ensembles/<ts>/                      ← standalone ensemble runs
└── model-routing-log.md                 ← journal (job/phase tags)


      ┌───────────────────────────────────────────────────────────┐
      │   FastAPI app (dashboard/main.py)                         │
      │                                                           │
      │   GET /                       ← updated home: portfolio  │
      │   GET /projects               ← NEW: project list view   │
      │   GET /projects/{id}          ← NEW: project drill-in    │
      │   GET /partials/projects      ← NEW: portfolio panel     │
      │   GET /partials/project/{id}/* ← NEW: drill-in partials  │
      └───────────────────────────────────────────────────────────┘
                              │
                              ▼
      ┌───────────────────────────────────────────────────────────┐
      │   dashboard/readers/projects.py (NEW)                     │
      │     discover_projects(kb_root) -> list[ProjectSummary]    │
      │     read_project_detail(kb_root, id, …) -> ProjectDetail  │
      │     read_project_cost(kb_root, id) -> ProjectCost         │
      │     read_project_decisions(kb_root, id) -> [DecisionRow]  │
      │     read_project_ensembles(jobs_root, id) -> [EnsembleRow]│
      └───────────────────────────────────────────────────────────┘
```

## Components

### 1. Models — `dashboard/models/events.py` extensions

New dataclasses (Pydantic-style or plain dataclass to match existing style):

```
ProjectSummary:
    id: str                  # the directory name
    title: str               # from a `title:` line in decision-guidance.md, or fallback to id
    cost_total_usd: float    # from cost.md current header
    decision_count: int
    active_job_count: int
    last_activity: datetime | None  # max(latest decision ts, latest job ts, latest ensemble ts)

ProjectDetail:
    summary: ProjectSummary
    jobs: list[JobSummary]            # filtered by project
    decisions: list[DecisionRow]
    cost: ProjectCost
    ensembles: list[EnsembleRow]

ProjectCost:
    current_usd: float
    last_entry_date: str | None
    entries: list[CostEntry]          # date, total, delta, source, note

DecisionRow:
    id: str                  # d042
    title: str
    confidence: str          # high|med|low
    flag: str                # null | review-needed
    timestamp: datetime
    job: str | None
    path: str

EnsembleRow:
    kind: str                # ensemble | six-hats | council | research
    timestamp: datetime
    path: str                # the parallel-<ts>/ or six-hats-<ts>/ dir
    provider_count: int      # number of <provider>.md files inside
    job_id: str | None
```

### 2. `dashboard/readers/projects.py` (NEW)

Pure-Python, no shell-out. Discovers projects by scanning `kb_root / "projects" / *`.

```
discover_projects(kb_root: Path, jobs_root: Path, journal_path: Path) -> list[ProjectSummary]:
    for each <kb_root>/projects/<id>/ that is a directory:
      title    = read decision-guidance.md first H1, or fallback to id.replace('-', ' ').title()
      cost     = parse cost.md for current-total header
      decision_count = len(decisions/d*.md)
      active_job_count = count of jobs whose manifest project: == id and status: active
      last_activity   = max(latest decision file mtime, latest job activity, latest ensemble mtime)
    sort by last_activity desc

read_project_detail(kb_root, id, jobs_root, journal_path) -> ProjectDetail:
    summary    = discover_projects(...) filtered to id
    jobs       = list_job_summaries(...) filtered to project==id (status all)
    decisions  = read_project_decisions(kb_root, id)
    cost       = read_project_cost(kb_root, id)
    ensembles  = read_project_ensembles(jobs_root, id)
```

**Decision parser:** read each `decisions/d*.md`, parse the YAML front-matter (`id`, `timestamp`, `confidence`, `flag`, `job`) and the H1 title. Reuse a minimal hand-rolled parser (no PyYAML dep) since the front-matter is flat.

**Ensemble enumeration:** scan `<jobs_root>/<job-id>/phases/*/ensemble-*` and `<jobs_root>/<job-id>/phases/*/six-hats-*` and `<jobs_root>/<job-id>/phases/*/council-*` for each job whose `manifest.yaml` has `project: <id>`. Standalone runs in `~/.claude/ensembles/*` have no project tag — Plan 7 surfaces these under a synthetic `_standalone` project (or omits them; default: omit, with a flag in the project list).

**Cost parser:** reuse the same line-by-line cost.md regex that PowerShell `cost-lib.ps1` uses (same shape, deterministic).

### 3. `dashboard/routers/projects.py` (NEW)

Constructor pattern matching `routers/jobs.py`:

```
build_router(templates: Jinja2Templates) -> APIRouter:
  GET /projects                      → projects_list.html
  GET /projects/{id}                 → project_detail.html
  GET /partials/projects             → partials/projects_list.html
  GET /partials/project/{id}/cost    → partials/project_cost.html
  GET /partials/project/{id}/decisions → partials/project_decisions.html
  GET /partials/project/{id}/ensembles → partials/project_ensembles.html
```

App-state inputs: `kb_root` (`~/.claude/knowledge` by default; overridable via `ROUTING_KB_ROOT` env), `jobs_root` (existing), `journal_path` (existing).

### 4. Templates

New:
- `templates/projects_list.html` — portfolio table (rows = projects)
- `templates/project_detail.html` — drill-in (sections: cost, decisions, jobs, ensembles)
- `templates/partials/projects_list.html` — htmx target for portfolio refresh
- `templates/partials/project_cost.html`, `project_decisions.html`, `project_ensembles.html`

Updates to existing `templates/index.html` and `templates/base.html`:
- Add a top-nav link: `Portfolio` → `/projects`
- On the home page, replace (or supplement) the activity feed with a small "Projects" panel above it

### 5. Home page extension

The existing home page shows: today spend, leaderboard, jobs, activity, controls. Plan 7 extension: between Jobs and Activity, add a **Projects panel** — top 5 projects by `last_activity`, each row showing id, cost, active jobs, decision count. This is htmx-loaded from `/partials/projects` and refreshes on the same cadence.

### 6. App wiring — `dashboard/main.py`

```python
KB_ROOT = Path(os.environ.get('ROUTING_KB_ROOT', '') or Path.home() / '.claude' / 'knowledge')
app.state.kb_root = KB_ROOT

from dashboard.routers.projects import build_router as build_projects_router
app.include_router(build_projects_router(templates))
```

## Output / data flow

Reads only. No writes. (PowerShell scripts continue to be the writers.)

## Testing strategy

`dashboard/tests/test_projects_reader.py` (NEW):
- `discover_projects` over a synthetic `kb_root` with two project dirs returns two summaries, sorted by `last_activity`
- A project with no `cost.md` shows `current_usd=0` (no crash)
- A project with no `decisions/` shows `decision_count=0`
- `read_project_decisions` parses the YAML front-matter and H1 title from a synthetic `d001-foo.md`
- `read_project_cost` matches the current-total header from a synthetic `cost.md`
- `read_project_ensembles` enumerates `ensemble-*/`, `six-hats-*/`, `council-*/` directories under a job's `phases/*/` and reports `kind` correctly
- Filtering by project on the jobs list reuses existing `list_job_summaries`

`dashboard/tests/test_projects_router.py` (NEW):
- `GET /projects` returns 200 with the project list rendered
- `GET /projects/{id}` returns 200 for a present project, 404 for absent
- `GET /partials/projects` returns 200 + the partial fragment

Existing test files unaffected (Plan 7 is additive).

## File layout (repo)

```
D:\Dev\coding-agent-orchestrator\
├── docs/superpowers/specs/2026-05-30-plan7-command-center-design.md  ← this
├── dashboard/
│   ├── main.py                            ← MODIFY: add kb_root state + project router
│   ├── models/events.py                   ← MODIFY: add ProjectSummary, ProjectDetail, etc.
│   ├── readers/projects.py                ← NEW
│   ├── routers/projects.py                ← NEW
│   ├── templates/
│   │   ├── base.html                      ← MODIFY: add Portfolio nav link
│   │   ├── projects_list.html             ← NEW
│   │   ├── project_detail.html            ← NEW
│   │   └── partials/
│   │       ├── projects_list.html         ← NEW
│   │       ├── project_cost.html          ← NEW
│   │       ├── project_decisions.html     ← NEW
│   │       └── project_ensembles.html     ← NEW
│   └── tests/
│       ├── test_projects_reader.py        ← NEW
│       └── test_projects_router.py        ← NEW
└── scripts/bootstrap.ps1                  ← no change (dashboard is run from repo, not deployed)
```

## Success criteria

- `GET /projects` lists every project under `~/.claude/knowledge/projects/` sorted by activity.
- `GET /projects/{id}` shows cost, decisions, jobs, ensembles for that project.
- Home page surfaces a top-5 projects panel.
- New tests pass; existing tests still pass.
- Page load latency for `/projects` with 10 projects each having 50 decisions: under 200ms on local.

## Decisions made (autonomous)

- **Read-only Plan 7.** Editing project metadata is a future plan; UI complexity not worth it now.
- **No charts/graphs.** Tables + small numbers. Charts in Plan 8 alongside KB embeddings (when there's more to chart).
- **Standalone ensembles default to "hidden in portfolio"** (no project tag). They're still listed under the active job's phases page if any. A `_standalone` synthetic project could be added later if usage warrants.
- **No PyYAML dependency.** Hand-roll the manifest/front-matter parsing — same approach already used by `readers/jobs.py`. Keeps the dep surface stable.
- **`ROUTING_KB_ROOT` env override** matching existing `ROUTING_JOURNAL` / `ROUTING_JOBS_ROOT` pattern.
- **Constructor router pattern** matching `routers/jobs.py` (shared templates injection).
- **Project title derivation** = first H1 of `decision-guidance.md`, fallback to id. Avoids needing a separate metadata file.
- **`last_activity` = max(latest decision mtime, latest job activity, latest ensemble mtime)**. Approximate but cheap.
