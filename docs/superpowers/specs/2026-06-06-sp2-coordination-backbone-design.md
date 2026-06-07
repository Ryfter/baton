# SP2 — Coordination Backbone: make the legibility feed reflect the real fleet

**Date:** 2026-06-06
**Status:** Approved (design) — proceeding to plan
**Predecessors:** Slice 1 (legibility dashboard, merged `0c0f274`); decisions d018 (conductor, not monolith), d019 (web dashboard = primary surface), d020 (build local backbone; Agent HQ is a future call-out).

## Problem

The Slice 1 legibility feed (`~/.claude/runs/<id>/run.json` + `events.jsonl` + `index.json`, read by `dashboard/readers/runs.py`) is fully built but **nothing writes real runs to it** — the gutter/detail/global-strip only ever show test fixtures.

Meanwhile, actual fleet dispatch (`scripts/fleet-backlog.ps1`, both `Invoke-Backlog` and `Invoke-BacklogConcurrent`) writes a **separate, older** feed: `<OutputDir>/_ensemble.json` + `<id>.live.json`, read by `dashboard/readers/ensembles.py`. The two feeds are disconnected.

The north star (autonomy + **legibility**) requires the new feed to show what the fleet is *actually* doing, grouped so the human can see — in plain English — which model is on what, what is queued, and what is parked waiting on them.

## Goal

When the fleet runs, every dispatched agent appears as a live run in the new legibility feed, and the dashboard gains a **per-agent assignment view** (active · queued · parked) plus a **parked-for-human lane**. The conductor's own interactive session also narrates into the feed.

Non-goal (this slice): retiring the old ensemble cockpit; auto-parking the unattended gate driver; new styling polish. These are tracked follow-ups.

## Architecture

Additive bridge, parent-process emission, one canonical feed going forward.

```
fleet-backlog.ps1 (Invoke-Backlog / Invoke-BacklogConcurrent)
   │  (existing Write-ItemLive calls stay — old cockpit untouched)
   └─▶ Publish-ItemRun  (scripts/fleet-runs-bridge.ps1)
          └─▶ runs-lib.ps1  Set-RunRecord / Add-RunEvent / Set-RunStatus
                 └─▶ ~/.claude/runs/<id>/{run.json, events.jsonl}

job lifecycle (/job-start, /job-phase done)
   └─▶ Set-CurrentRun / Clear-CurrentRun (runs-lib.ps1)
          └─▶ ~/.claude/current-run.json  ──read by──▶ run-feed.ps1 PostToolUse hook
                                                          └─▶ narrates conductor's own run

dashboard:  runs.py  read_assignments()  ──▶  routers/runs.py  ──▶  partials/assignments.html
                                                                     (new section on index.html)
```

All run-feed writes happen in the **parent** process. The `Start-Job` worker in `Invoke-BacklogConcurrent` (which cannot dot-source helpers) is never modified — the parent already owns every lifecycle transition it needs (`queued` before launch, `running` right after `Start-Job`, `done`/`blocked` at serial merge time).

## Unit 1 — Fleet→runs bridge (`scripts/fleet-runs-bridge.ps1`)

Dot-sources `runs-lib.ps1`. One public function:

```
Publish-ItemRun
  -Id        <string>   # backlog item id, e.g. 'issue-22'
  -Model     <string>   # e.g. 'codex'
  -State     <string>   # ensemble state: queued|running|done|blocked
  [-Name     <string>]  # human label (item title/prompt first line); default "<Id>"
  [-Project  <string>]  # default 'coding-agent-orchestrator'
  [-Branch   <string>]  # item branch, recorded as tree; sets worktree=$true
  [-Reasons  <string[]>]# block reasons (for blocked → event.why + current_step)
  [-RunsRoot <string>]  # test override (honours $env:ROUTING_RUNS_ROOT)
```

**Run id:** `backlog-<Id>-<Model>` (stable across the item's lifecycle so transitions update one record).

**State → status map:**

| ensemble State | runs status | event kind / what |
|---|---|---|
| `queued`  | `queued`  | `action` / "queued for <model>" |
| `running` | `running` | `action` / "implementing <Id>" |
| `done`    | `done`    | `result` (status=done) / "merged to integration" |
| `blocked` | `failed`  | `result` (status=failed) / "gate blocked: <reasons joined>" |

Behaviour:
- Always `Set-RunRecord -Id <runid> -Name -Model -Status <mapped> -Project` and, when `-Branch` given, `-Tree <branch> -Worktree $true`.
- Always append one `Add-RunEvent` per call describing the transition (the `what`/`why`/`status` from the table). `blocked` also sets `-CurrentStep "blocked: <first reason>"`.
- Never writes cost/tokens (the gate driver doesn't know them) — relies on the Slice 1 `$PSBoundParameters.ContainsKey` guards so existing values are preserved.

## Unit 2 — Conductor current-run wiring

Add to `runs-lib.ps1`:

```
Set-CurrentRun   -Id <string> [-Name] [-Model] [-Project] [-RunsRoot]
Clear-CurrentRun [-RunsRoot]
```

- `Set-CurrentRun` writes `<RunsRoot>/current-run.json` = `{ id, name, model, project }` **and** seeds the run via `Set-RunRecord -Status running` so the run exists the moment narration starts.
- `Clear-CurrentRun` deletes `current-run.json` (idempotent — no error if absent). It does **not** delete the run record (it stays as history); callers set terminal status separately if desired.
- `current-run.json` lives at the runs root (sibling of `index.json`), matching what the Slice 1 `run-feed.ps1` hook already expects.

Wiring (documented, minimal): the `/job-start` command calls `Set-CurrentRun`; `/job-phase done` calls `Clear-CurrentRun`. Job id reused as run id (`job-<jobid>`).

## Unit 3 — Assignment/queue view

`dashboard/readers/runs.py` gains:

```python
class AgentLane(BaseModel):           # in models/runs.py
    model: str
    active: list[RunRecord] = []      # status running
    queued: list[RunRecord] = []      # status queued
    parked: list[RunRecord] = []      # status needs-you

def read_assignments(runs_root: Path) -> list[AgentLane]:
    """Group all runs by model into per-agent lanes.
    Lanes sorted by model name; within a lane, runs by existing _sort_key.
    Models with only done/failed/idle runs still appear (empty active/queued/parked)
    so a recently-finished agent is visible. Runs whose status is done/failed/idle
    are omitted from the three lanes (they live in the gutter/history, not the board)."""
```

- `routers/runs.py`: `GET /partials/assignments` → renders `partials/assignments.html` with `lanes=read_assignments(...)`.
- `partials/assignments.html`: one block per `AgentLane` — model name, a ▶ active line (name + current_step), a "queued:" list, and parked items shown with their `parked_question`. Empty lanes render "idle".
- `index.html`: a new `<section>` above or beside the runs gutter, `hx-get="/partials/assignments"` `hx-trigger="load, every 5s"` (matches the existing 5s polling).

## Unit 4 — Parked-for-human lane

No new data — `needs-you` status + `parked_question` + the `answer.txt` round-trip already exist from Slice 1. This unit is the **view**: a dedicated "Parked — waiting on you" lane at the top of the assignments section listing every `needs-you` run across all models, each with its question and the existing answer form (reusing the Slice 1 `POST /runs/{id}/answer`). The autonomous gate driver does **not** auto-park (decision: keeps the DAG from stalling); parking is produced only by interactive/conductor runs that call `Set-RunStatus -Status needs-you -ParkedQuestion`.

## Data flow (concurrent driver, worked example)

1. `Invoke-BacklogConcurrent` writes meta + per-item `queued` live.json → bridge emits `Publish-ItemRun -State queued` for each. Dashboard: all items show in their model's **queued** lane.
2. Wave launch: parent `Start-Job`s item, then `Publish-ItemRun -State running -Branch auto/issue-22-codex`. Dashboard: item moves to **active**, gutter shows it running, global strip `active_runs` increments.
3. Worker edits in worktree (writes only its own `<id>.live.json`); the PostToolUse hook does not fire for child jobs, so no event spam — the bridge's transition events are the narration.
4. Serial merge: gate passes → `Publish-ItemRun -State done`; gate blocks → `-State blocked -Reasons @(...)`. Dashboard: item → **done** (leaves the board) or **failed** with reason in detail.

## Error handling

- Bridge calls are best-effort: wrap each `Publish-ItemRun` call site in the driver with `try { } catch { }` so a feed-write failure never aborts a real merge. (The gate/merge is the source of truth; the feed is observational.)
- `read_assignments` reuses `_read_record`'s tolerance (bad `run.json` → skipped, not a 500).
- `Clear-CurrentRun` is idempotent.
- Run-id collisions are intended (same item re-run updates the same record); `started_at` is preserved by `Set-RunRecord`, `updated_at` refreshes.

## Testing

PowerShell (`scripts/test-fleet-runs-bridge.ps1`, extend `test-runs-lib.ps1`):
- `Publish-ItemRun` writes a run.json with mapped status + one appended event, for each of the 4 states, under a temp `$env:ROUTING_RUNS_ROOT`.
- `queued→running→done` sequence keeps one record, preserves `started_at`, accumulates 3 events.
- `blocked` sets status `failed`, `current_step` from first reason, event `status=failed`.
- `Set-CurrentRun` writes current-run.json + seeds a running record; `Clear-CurrentRun` removes the file, leaves the record, and no-ops when absent.

Python (`dashboard/tests/test_assignments_reader.py`, `test_runs_router.py`):
- `read_assignments` groups by model; running→active, queued→queued, needs-you→parked; done/failed omitted from lanes; lanes sorted by model.
- empty runs_root → `[]`; malformed run.json → skipped.
- `GET /partials/assignments` returns 200 and contains each model name and parked question.

Integration (extend `test_runs_integration.py`): PowerShell `Publish-ItemRun` across a lifecycle → Python `read_assignments` renders the expected lanes (PowerShell-written JSON parsed by the Python reader, end to end).

Gate (all must pass before merge): full Python suite (`python -m pytest dashboard kb -q`), all PowerShell suites, `bootstrap.ps1` smoke.

## Build order (for the plan)

1. `models/runs.py`: add `AgentLane`.
2. `runs.py`: `read_assignments` + tests.
3. `routers/runs.py` + `partials/assignments.html` + tests.
4. `index.html`: wire the assignments section.
5. `fleet-runs-bridge.ps1` + `Publish-ItemRun` + tests.
6. Wire `Publish-ItemRun` into `Invoke-Backlog` and `Invoke-BacklogConcurrent` (parent call sites, try/catch).
7. `runs-lib.ps1`: `Set-CurrentRun`/`Clear-CurrentRun` + tests; wire into `/job-start` and `/job-phase done`.
8. `bootstrap.ps1`: deploy `fleet-runs-bridge.ps1`; smoke includes assignments partial.

## Decisions resolved in this spec

- **Additive bridge**, old ensemble cockpit retained (retire later) — avoids ripping out working code.
- **Autonomous gate driver does not auto-park** — parking is interactive/conductor-only, so the unattended DAG never stalls on a human.
- **Assignment view is a section on the existing dashboard page**, not a separate tab — one glance, no navigation.
- **Parent-process emission** — never touch the dot-source-less `Start-Job` worker.
