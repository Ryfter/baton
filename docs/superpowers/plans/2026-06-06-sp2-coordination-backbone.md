# SP2 Coordination Backbone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the new legibility feed (`~/.claude/runs/`) reflect the real fleet — dispatched agents appear as live runs, grouped into a per-agent assignment view with a parked-for-human lane, and the conductor's own session narrates in.

**Architecture:** Additive bridge. A new `Publish-ItemRun` (in `scripts/fleet-runs-bridge.ps1`) maps each backlog item to a run via the existing `runs-lib.ps1` writers; it is called from the **parent** process of both `fleet-backlog.ps1` drivers (never the dot-source-less `Start-Job` worker). The dashboard gains `read_assignments` + an assignments partial. The conductor session is wired via `Set-CurrentRun`/`Clear-CurrentRun`. The old ensemble cockpit is left untouched.

**Tech Stack:** PowerShell 7 (producers + tests), Python 3.14 / FastAPI / Jinja2 / pydantic (reader + router + templates), htmx (5s polling).

**Spec:** `docs/superpowers/specs/2026-06-06-sp2-coordination-backbone-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `dashboard/models/runs.py` | add `AgentLane` model | Modify |
| `dashboard/readers/runs.py` | add `read_assignments` | Modify |
| `dashboard/routers/runs.py` | add `GET /partials/assignments` | Modify |
| `dashboard/templates/partials/assignments.html` | per-agent lanes + parked lane | Create |
| `dashboard/templates/index.html` | wire assignments section | Modify |
| `scripts/fleet-runs-bridge.ps1` | `Publish-ItemRun` (ensemble→runs map) | Create |
| `scripts/fleet-backlog.ps1` | call `Publish-ItemRun` at lifecycle points | Modify |
| `scripts/runs-lib.ps1` | `Set-CurrentRun` / `Clear-CurrentRun` | Modify |
| `scripts/bootstrap.ps1` | deploy `fleet-runs-bridge.ps1` | Modify |
| `dashboard/tests/test_assignments_reader.py` | reader tests | Create |
| `dashboard/tests/test_runs_router.py` | assignments route test | Modify |
| `dashboard/tests/test_runs_integration.py` | PS→Python lifecycle test | Modify |
| `scripts/test-fleet-runs-bridge.ps1` | bridge tests | Create |
| `scripts/test-runs-lib.ps1` | current-run tests | Modify |

Build order: Python view first (Tasks 1–4, pure additions over the existing fixture), then the PowerShell producers (Tasks 5–7), then bootstrap (Task 8).

---

## Task 1: `AgentLane` model

**Files:**
- Modify: `dashboard/models/runs.py` (append after `GlobalStrip`)
- Test: `dashboard/tests/test_assignments_reader.py` (create)

- [ ] **Step 1: Write the failing test**

Create `dashboard/tests/test_assignments_reader.py`:

```python
from dashboard.models.runs import AgentLane, RunRecord


def test_agentlane_defaults_empty_lists():
    lane = AgentLane(model="codex")
    assert lane.model == "codex"
    assert lane.active == []
    assert lane.queued == []
    assert lane.parked == []


def test_agentlane_holds_runrecords():
    r = RunRecord(id="x", name="x", model="codex", status="running")
    lane = AgentLane(model="codex", active=[r])
    assert lane.active[0].id == "x"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest dashboard/tests/test_assignments_reader.py -v`
Expected: FAIL with `ImportError: cannot import name 'AgentLane'`

- [ ] **Step 3: Implement the model**

Append to `dashboard/models/runs.py`:

```python
class AgentLane(BaseModel):
    model: str
    active: list[RunRecord] = []     # status running
    queued: list[RunRecord] = []     # status queued
    parked: list[RunRecord] = []     # status needs-you
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest dashboard/tests/test_assignments_reader.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add dashboard/models/runs.py dashboard/tests/test_assignments_reader.py
git commit -m "feat(sp2): add AgentLane model for the assignment view"
```

---

## Task 2: `read_assignments` reader

**Files:**
- Modify: `dashboard/readers/runs.py` (add function + import)
- Test: `dashboard/tests/test_assignments_reader.py` (append)

The existing `runs_root` fixture (in `dashboard/tests/conftest.py`) has two runs: `run_auth-rewrite` (model `claude-opus-4-8`, status `running`) and `run_fix-login` (model `codex`, status `needs-you`).

- [ ] **Step 1: Write the failing tests**

Append to `dashboard/tests/test_assignments_reader.py`:

```python
from pathlib import Path
import json
from dashboard.readers.runs import read_assignments


def test_groups_runs_by_model(runs_root: Path):
    lanes = read_assignments(runs_root)
    by_model = {lane.model: lane for lane in lanes}
    assert "claude-opus-4-8" in by_model
    assert "codex" in by_model


def test_running_goes_to_active(runs_root: Path):
    lanes = {l.model: l for l in read_assignments(runs_root)}
    assert [r.id for r in lanes["claude-opus-4-8"].active] == ["run_auth-rewrite"]
    assert lanes["claude-opus-4-8"].queued == []
    assert lanes["claude-opus-4-8"].parked == []


def test_needs_you_goes_to_parked(runs_root: Path):
    lanes = {l.model: l for l in read_assignments(runs_root)}
    assert [r.id for r in lanes["codex"].parked] == ["run_fix-login"]


def test_lanes_sorted_by_model_name(runs_root: Path):
    lanes = read_assignments(runs_root)
    models = [l.model for l in lanes]
    assert models == sorted(models)


def test_done_failed_idle_omitted_from_lanes(tmp_path: Path):
    root = tmp_path / "runs"
    root.mkdir()
    for rid, status in [("a", "done"), ("b", "failed"), ("c", "idle")]:
        d = root / rid
        d.mkdir()
        (d / "run.json").write_text(json.dumps({
            "id": rid, "name": rid, "model": "codex", "status": status,
        }), encoding="utf-8")
    lanes = {l.model: l for l in read_assignments(root)}
    # codex lane exists (model was used) but no run lands in active/queued/parked
    assert lanes["codex"].active == []
    assert lanes["codex"].queued == []
    assert lanes["codex"].parked == []


def test_empty_root_returns_empty(tmp_path: Path):
    assert read_assignments(tmp_path / "nope") == []


def test_malformed_run_json_skipped(tmp_path: Path):
    root = tmp_path / "runs"
    root.mkdir()
    bad = root / "bad"
    bad.mkdir()
    (bad / "run.json").write_text("{ not json", encoding="utf-8")
    assert read_assignments(root) == []
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest dashboard/tests/test_assignments_reader.py -v`
Expected: FAIL with `ImportError: cannot import name 'read_assignments'`

- [ ] **Step 3: Implement the reader**

In `dashboard/readers/runs.py`, update the model import line and append the function. Change the import at the top from:

```python
from dashboard.models.runs import RunRecord, RunEvent, RunDetail, GlobalStrip
```

to:

```python
from dashboard.models.runs import RunRecord, RunEvent, RunDetail, GlobalStrip, AgentLane
```

Then append at the end of the file:

```python
def read_assignments(runs_root: Path) -> list[AgentLane]:
    """Group runs by model into per-agent lanes (active/queued/parked).

    A model gets a lane if it has at least one run. Only running/queued/needs-you
    runs populate the three lanes; done/failed/idle runs live in the gutter/history,
    so a model whose runs are all terminal shows an empty (idle) lane. Lanes are
    sorted by model name; runs within each lane keep list_runs' ordering.
    """
    lanes: dict[str, AgentLane] = {}
    for r in list_runs(runs_root):       # already sorted by _sort_key
        lane = lanes.get(r.model)
        if lane is None:
            lane = AgentLane(model=r.model)
            lanes[r.model] = lane
        if r.status == "running":
            lane.active.append(r)
        elif r.status == "queued":
            lane.queued.append(r)
        elif r.status == "needs-you":
            lane.parked.append(r)
    return [lanes[m] for m in sorted(lanes)]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest dashboard/tests/test_assignments_reader.py -v`
Expected: PASS (9 passed)

- [ ] **Step 5: Commit**

```bash
git add dashboard/readers/runs.py dashboard/tests/test_assignments_reader.py
git commit -m "feat(sp2): read_assignments groups runs into per-agent lanes"
```

---

## Task 3: Assignments route + partial

**Files:**
- Modify: `dashboard/routers/runs.py` (import + new route)
- Create: `dashboard/templates/partials/assignments.html`
- Test: `dashboard/tests/test_runs_router.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `dashboard/tests/test_runs_router.py` (this file has no `client` fixture — each test builds its own client via the module-level `make_app(runs_root)` helper, which is already defined at the top of the file):

```python
def test_partial_assignments_renders_models_and_parked(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.get("/partials/assignments")
    assert resp.status_code == 200
    body = resp.text
    assert "claude-opus-4-8" in body
    assert "codex" in body
    # parked question from the fixture's needs-you run
    assert "rotate tokens without invalidating logins?" in body
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest dashboard/tests/test_runs_router.py::test_partial_assignments_renders_models_and_parked -v`
Expected: FAIL with 404 (route not defined)

- [ ] **Step 3: Create the partial**

Create `dashboard/templates/partials/assignments.html`:

```html
{# Per-agent assignment board over the legibility feed. Polled every 5s. #}
{% set parked_runs = [] %}
{% for lane in lanes %}{% for r in lane.parked %}{% set _ = parked_runs.append(r) %}{% endfor %}{% endfor %}

{% if parked_runs %}
<div class="assign-parked-lane">
  <h3>⏸ Parked — waiting on you</h3>
  {% for r in parked_runs %}
  <div class="assign-parked-item">
    <span class="assign-model">{{ r.model }}</span>
    <span class="assign-name">{{ r.name }}</span>
    <p class="assign-question">{{ r.parked_question or "needs your input" }}</p>
    <form hx-post="/runs/{{ r.id }}/answer" hx-target="#run-detail" hx-swap="innerHTML">
      <input type="text" name="answer" placeholder="your answer…" required>
      <button type="submit">Send</button>
    </form>
  </div>
  {% endfor %}
</div>
{% endif %}

<div class="assign-board">
  {% for lane in lanes %}
  <div class="assign-lane">
    <h4 class="assign-model">{{ lane.model }}</h4>
    {% if lane.active %}
      {% for r in lane.active %}
      <div class="assign-active" hx-get="/partials/runs/{{ r.id }}" hx-target="#run-detail" hx-swap="innerHTML" style="cursor:pointer">
        ▶ {{ r.name }}{% if r.current_step %} — {{ r.current_step }}{% endif %}
      </div>
      {% endfor %}
    {% else %}
      <div class="assign-idle muted">idle</div>
    {% endif %}
    <div class="assign-queued">
      queued:
      {% if lane.queued %}{{ lane.queued | map(attribute='name') | join(', ') }}{% else %}—{% endif %}
    </div>
  </div>
  {% endfor %}
</div>
```

- [ ] **Step 4: Add the route**

In `dashboard/routers/runs.py`, extend the reader import (currently `list_runs, read_run_detail, read_global_strip, write_run_answer`) to include `read_assignments`:

```python
from dashboard.readers.runs import (
    list_runs, read_run_detail, read_global_strip, write_run_answer, read_assignments,
)
```

Then add this route inside `build_router`, immediately after the `partial_runs` handler (before `run_detail`):

```python
    @router.get("/partials/assignments", response_class=HTMLResponse)
    async def partial_assignments(request: Request) -> HTMLResponse:
        root = _runs_root(request)
        return templates.TemplateResponse("partials/assignments.html", {
            "request": request,
            "lanes": read_assignments(root),
        })
```

- [ ] **Step 5: Run test to verify it passes**

Run: `python -m pytest dashboard/tests/test_runs_router.py::test_partial_assignments_renders_models_and_parked -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add dashboard/routers/runs.py dashboard/templates/partials/assignments.html dashboard/tests/test_runs_router.py
git commit -m "feat(sp2): /partials/assignments route + per-agent board partial"
```

---

## Task 4: Wire the assignments section into the dashboard

**Files:**
- Modify: `dashboard/templates/index.html`

- [ ] **Step 1: Add the section**

In `dashboard/templates/index.html`, insert this block immediately **before** the existing `<!-- Runs gutter + detail ...` comment (so the board sits above the gutter, both feeding the shared `#run-detail` pane):

```html
<!-- Per-agent assignment board (legibility feed, polls every 5s) -->
<section class="assignments-section" style="grid-column: 1 / -1;">
  <h2>Fleet assignments</h2>
  <div id="assignments" hx-get="/partials/assignments" hx-trigger="load, every 5s"></div>
</section>
```

- [ ] **Step 2: Verify the app boots and serves the section**

Run:
```bash
python -c "from dashboard.main import app; from starlette.testclient import TestClient; c=TestClient(app); r=c.get('/'); print(r.status_code); assert 'assignments' in r.text"
```
Expected: prints `200` and no assertion error.

- [ ] **Step 3: Run the full dashboard suite**

Run: `python -m pytest dashboard -q`
Expected: PASS (all green, new tests included)

- [ ] **Step 4: Commit**

```bash
git add dashboard/templates/index.html
git commit -m "feat(sp2): surface the assignment board on the dashboard index"
```

---

## Task 5: `Publish-ItemRun` bridge

**Files:**
- Create: `scripts/fleet-runs-bridge.ps1`
- Test: `scripts/test-fleet-runs-bridge.ps1` (create)

- [ ] **Step 1: Write the failing test**

Create `scripts/test-fleet-runs-bridge.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-runs-bridge.ps1"

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-test-" + [guid]::NewGuid().ToString('N'))
$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "PASS: $name" } else { Write-Host "FAIL: $name"; $script:fail++ }
}

try {
    # queued -> queued
    Publish-ItemRun -RunsRoot $root -Id 'issue-22' -Model 'codex' -State 'queued' -Name 'wire bridge'
    $rid = 'backlog-issue-22-codex'
    $rj  = Join-Path $root "$rid/run.json"
    Check 'run.json created'        (Test-Path $rj)
    $rec = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'status queued'           ($rec.status -eq 'queued')
    Check 'model recorded'          ($rec.model -eq 'codex')
    Check 'name recorded'           ($rec.name -eq 'wire bridge')
    $ej = Join-Path $root "$rid/events.jsonl"
    Check 'one event appended'      ((Get-Content $ej).Count -eq 1)

    # running -> running, with branch -> tree + worktree
    Publish-ItemRun -RunsRoot $root -Id 'issue-22' -Model 'codex' -State 'running' -Branch 'auto/issue-22-codex'
    $rec2 = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'status running'          ($rec2.status -eq 'running')
    Check 'tree = branch'           ($rec2.tree -eq 'auto/issue-22-codex')
    Check 'worktree true'           ($rec2.worktree -eq $true)
    Check 'started_at preserved'    ($rec2.started_at -eq $rec.started_at)
    Check 'two events now'          ((Get-Content $ej).Count -eq 2)

    # done -> done
    Publish-ItemRun -RunsRoot $root -Id 'issue-22' -Model 'codex' -State 'done'
    $rec3 = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'status done'             ($rec3.status -eq 'done')
    $lastDone = (Get-Content $ej | Select-Object -Last 1) | ConvertFrom-Json
    Check 'done event kind result' ($lastDone.kind -eq 'result')
    Check 'done event status'      ($lastDone.status -eq 'done')

    # blocked -> failed, with reasons
    Publish-ItemRun -RunsRoot $root -Id 'issue-99' -Model 'codex' -State 'blocked' -Reasons @('scope: out-of-scope edits', 'tests: exit 1')
    $rb = Get-Content (Join-Path $root 'backlog-issue-99-codex/run.json') -Raw | ConvertFrom-Json
    Check 'blocked -> failed'       ($rb.status -eq 'failed')
    Check 'current_step from reason'($rb.current_step -like 'blocked: scope*')
    $eb = (Get-Content (Join-Path $root 'backlog-issue-99-codex/events.jsonl') | Select-Object -Last 1) | ConvertFrom-Json
    Check 'block event status failed' ($eb.status -eq 'failed')
    Check 'block event why has reasons' ($eb.why -like '*tests: exit 1*')

    # default name when omitted
    Publish-ItemRun -RunsRoot $root -Id 'issue-7' -Model 'gemini' -State 'queued'
    $rd = Get-Content (Join-Path $root 'backlog-issue-7-gemini/run.json') -Raw | ConvertFrom-Json
    Check 'default name = id'       ($rd.name -eq 'issue-7')
    Check 'default project'         ($rd.project -eq 'coding-agent-orchestrator')
}
finally {
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
}

if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-fleet-runs-bridge.ps1`
Expected: FAIL — `fleet-runs-bridge.ps1` not found / `Publish-ItemRun` not recognized.

- [ ] **Step 3: Implement the bridge**

Create `scripts/fleet-runs-bridge.ps1`:

```powershell
#!/usr/bin/env pwsh
# Bridge: project one backlog item (id x model x worktree) into the legibility
# feed (~/.claude/runs/) as a single run, updated across its lifecycle. Called
# from the PARENT process of the fleet drivers — never the Start-Job worker.

. (Join-Path $PSScriptRoot 'runs-lib.ps1')

function Publish-ItemRun {
    param(
        [string]$RunsRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][ValidateSet('queued','running','done','blocked')][string]$State,
        [string]$Name,
        [string]$Project = 'coding-agent-orchestrator',
        [string]$Branch,
        [string[]]$Reasons
    )
    if (-not $Name) { $Name = $Id }
    $runId = "backlog-$Id-$Model"

    # ensemble state -> legibility status
    $status = switch ($State) {
        'queued'  { 'queued' }
        'running' { 'running' }
        'done'    { 'done' }
        'blocked' { 'failed' }
    }

    $recArgs = @{ RunsRoot = $RunsRoot; Id = $runId; Name = $Name; Model = $Model; Status = $status; Project = $Project }
    if ($Branch) { $recArgs['Tree'] = $Branch; $recArgs['Worktree'] = $true }
    if ($State -eq 'blocked' -and $Reasons -and $Reasons.Count -gt 0) {
        $recArgs['CurrentStep'] = "blocked: $($Reasons[0])"
    }
    Set-RunRecord @recArgs

    # one narration event per transition
    switch ($State) {
        'queued'  { Add-RunEvent -RunsRoot $RunsRoot -Id $runId -Kind 'action' -What "queued for $Model" }
        'running' { Add-RunEvent -RunsRoot $RunsRoot -Id $runId -Kind 'action' -What "implementing $Id" }
        'done'    { Add-RunEvent -RunsRoot $RunsRoot -Id $runId -Kind 'result' -What "merged to integration" -Status 'done' }
        'blocked' {
            $why = if ($Reasons) { ($Reasons -join '; ') } else { 'gate blocked' }
            Add-RunEvent -RunsRoot $RunsRoot -Id $runId -Kind 'result' -What "gate blocked: $Id" -Why $why -Status 'failed'
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-fleet-runs-bridge.ps1`
Expected: `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-runs-bridge.ps1 scripts/test-fleet-runs-bridge.ps1
git commit -m "feat(sp2): Publish-ItemRun bridges fleet items into the legibility feed"
```

---

## Task 6: Wire the bridge into both backlog drivers

The driver must keep working even if a feed write fails, so every bridge call is wrapped in `try { } catch { }`. The bridge is dot-sourced once at the top of `fleet-backlog.ps1`.

**Files:**
- Modify: `scripts/fleet-backlog.ps1`
- Test: `scripts/test-fleet-backlog.ps1` (verify still green — no new assertions required; the drivers are exercised with an injected implementer and the bridge writes to the default runs root harmlessly. If that suite sets `$env:ROUTING_RUNS_ROOT`, the runs land in a temp dir; otherwise they land in `~/.claude/runs` which is acceptable for a test run.)

- [ ] **Step 1: Dot-source the bridge**

In `scripts/fleet-backlog.ps1`, after the existing dot-source lines (currently `. (Join-Path $PSScriptRoot 'fleet-orchestrate.ps1')` and `. (Join-Path $PSScriptRoot 'fleet-ensemble.ps1')`), add:

```powershell
. (Join-Path $PSScriptRoot 'fleet-runs-bridge.ps1')
```

- [ ] **Step 2: Add a local helper for safe calls**

Immediately after the dot-source lines in `scripts/fleet-backlog.ps1`, add:

```powershell
function script:Publish-ItemRunSafe {
    param([hashtable]$Args)
    try { Publish-ItemRun @Args } catch { Write-Verbose "runs-feed publish failed: $_" }
}
```

- [ ] **Step 3: Wire `Invoke-Backlog` (serial driver)**

In `Invoke-Backlog`, find the initial queued-status loop (currently:
`foreach ($t in $Tasks) { Write-ItemLive -OutputDir $OutputDir -Id $t.id -Model $t.model -State 'queued' }`)
and add a bridge call alongside it so the block reads:

```powershell
        foreach ($t in $Tasks) {
            Write-ItemLive -OutputDir $OutputDir -Id $t.id -Model $t.model -State 'queued'
            Publish-ItemRunSafe @{ Id = $t.id; Model = $t.model; State = 'queued'; Name = $t.title }
        }
```

(`$t.title` is optional in the task object; `Publish-ItemRun` falls back to the id when it is `$null`.)

In `Invoke-BacklogItem` (called by the serial driver), find the `running` live write (currently `if ($OutputDir) { Write-ItemLive ... -State 'running' -Extra @{ branch = $wt.branch } }`) and add immediately after it:

```powershell
    Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'running'; Branch = $wt.branch }
```

Then find the terminal live write near the end of `Invoke-BacklogItem` (the `Write-ItemLive ... -State $state ...` block) and add immediately after it:

```powershell
    if ($res.merged) {
        Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'done'; Branch = $wt.branch }
    } else {
        Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Branch = $wt.branch; Reasons = $reasons }
    }
```

- [ ] **Step 4: Wire `Invoke-BacklogConcurrent` (concurrent driver)**

In `Invoke-BacklogConcurrent`:

(a) The initial queued loop (currently `foreach ($t in $Tasks) { Write-ItemLive -OutputDir $OutputDir -Id $t.id -Model $t.model -State 'queued' }`) — add the queued bridge call so it reads:

```powershell
        foreach ($t in $Tasks) {
            Write-ItemLive -OutputDir $OutputDir -Id $t.id -Model $t.model -State 'queued'
            Publish-ItemRunSafe @{ Id = $t.id; Model = $t.model; State = 'queued'; Name = $t.title }
        }
```

(b) Right after the job is launched (`$job = Start-Job ...; $jobs[$id] = @{ ... }`), add a running publish (the parent knows the item is now running):

```powershell
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'running'; Branch = $wt.branch }
```

(c) In the serial gate+merge loop, find the terminal `Write-ItemLive ... -State $state ...` line and add immediately after it:

```powershell
            if ($res.merged) {
                Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'done'; Branch = $info.wt.branch }
            } else {
                Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'blocked'; Branch = $info.wt.branch; Reasons = @($res.gate.reasons) }
            }
```

(d) For the no-implementer and dep-blocked early-outs in both drivers (where `Write-ItemLive ... -State 'blocked'` is written without a worktree), add a matching blocked publish after each, e.g.:

```powershell
            Publish-ItemRunSafe @{ Id = $id; Model = $byId[$id].model; State = 'blocked'; Reasons = @("dep-blocked: $($deadDep -join ', ')") }
```

and for no-implementer:

```powershell
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Reasons = @("no-implementer: '$model'") }
```

- [ ] **Step 5: Run the backlog suites to verify they still pass**

Run:
```bash
pwsh -NoProfile -File scripts/test-fleet-backlog.ps1
pwsh -NoProfile -File scripts/test-fleet-backlog-concurrent.ps1
```
Expected: both end `ALL PASS` (or existing pass marker). If either suite asserts exact file lists in an output dir, the bridge writes only under the runs root (separate dir) and must not affect those assertions; if a failure shows runs files leaking into the asserted dir, set `$env:ROUTING_RUNS_ROOT` to a temp dir at the top of the test and clear it in `finally`.

- [ ] **Step 6: Commit**

```bash
git add scripts/fleet-backlog.ps1
git commit -m "feat(sp2): emit legibility runs from both backlog drivers (parent, best-effort)"
```

---

## Task 7: `Set-CurrentRun` / `Clear-CurrentRun` + job wiring

**Files:**
- Modify: `scripts/runs-lib.ps1` (append two functions)
- Test: `scripts/test-runs-lib.ps1` (append assertions)

- [ ] **Step 1: Write the failing tests**

In `scripts/test-runs-lib.ps1`, insert before the final `finally` block:

```powershell
    # --- SP2: current-run wiring ---
    Set-CurrentRun -RunsRoot $root -Id 'job-x1' -Name 'wire SP2' -Model 'claude-opus-4-8' -Project 'coding-agent-orchestrator'
    $curPath = Join-Path $root 'current-run.json'
    Check 'current-run.json written'  (Test-Path $curPath)
    $cur = Get-Content $curPath -Raw | ConvertFrom-Json
    Check 'current id'                ($cur.id -eq 'job-x1')
    Check 'current name'              ($cur.name -eq 'wire SP2')
    $seed = Get-Content (Join-Path $root 'job-x1/run.json') -Raw | ConvertFrom-Json
    Check 'run record seeded running' ($seed.status -eq 'running')

    Clear-CurrentRun -RunsRoot $root
    Check 'current-run.json removed'  (-not (Test-Path $curPath))
    Check 'run record survives clear' (Test-Path (Join-Path $root 'job-x1/run.json'))
    # idempotent: second clear must not throw
    Clear-CurrentRun -RunsRoot $root
    Check 'clear is idempotent'       (-not (Test-Path $curPath))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-runs-lib.ps1`
Expected: FAIL — `Set-CurrentRun` not recognized.

- [ ] **Step 3: Implement the functions**

Append to `scripts/runs-lib.ps1`:

```powershell
function Set-CurrentRun {
    # Mark the conductor's own session as the active run so the PostToolUse
    # run-feed hook narrates into it. Seeds the run record as 'running'.
    param(
        [string]$RunsRoot, [Parameter(Mandatory)][string]$Id,
        [string]$Name, [string]$Model, [string]$Project
    )
    $root = Get-RunsRoot $RunsRoot
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $seed = @{ RunsRoot = $RunsRoot; Id = $Id; Status = 'running' }
    if ($Name)    { $seed['Name'] = $Name }
    if ($Model)   { $seed['Model'] = $Model }
    if ($Project) { $seed['Project'] = $Project }
    Set-RunRecord @seed
    $obj = [ordered]@{ id = $Id }
    if ($Name)    { $obj.name = $Name }
    if ($Model)   { $obj.model = $Model }
    if ($Project) { $obj.project = $Project }
    ($obj | ConvertTo-Json) | Set-Content -Path (Join-Path $root 'current-run.json') -Encoding utf8
}

function Clear-CurrentRun {
    # Remove the current-run pointer (idempotent). Leaves the run record as history.
    param([string]$RunsRoot)
    $path = Join-Path (Get-RunsRoot $RunsRoot) 'current-run.json'
    if (Test-Path $path) { Remove-Item -Force $path }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-runs-lib.ps1`
Expected: `ALL PASS`

- [ ] **Step 5: Wire into the job lifecycle commands**

The job commands live in `~/.claude/commands/` and are sourced from the repo. Find where `/job-start` and `/job-phase` are defined. Search:

Run: `pwsh -NoProfile -Command "Select-String -Path scripts/*.ps1, .claude/commands/*.md -Pattern 'job-start|job-phase' -List | Select-Object Path"`

Then, in the `/job-start` command body (after the job dir is created), add a call that sets the current run to the new job:

```powershell
& pwsh -NoProfile -Command ". '$HOME/.claude/scripts/runs-lib.ps1'; Set-CurrentRun -Id 'job-<jobid>' -Name '<title>' -Project '<project>'"
```

and in `/job-phase` when the phase transitions to `done`, add:

```powershell
& pwsh -NoProfile -Command ". '$HOME/.claude/scripts/runs-lib.ps1'; Clear-CurrentRun"
```

If `/job-start` and `/job-phase` are markdown command prompts (not scripts), add a step in each prompt instructing the agent to run the corresponding one-line `Set-CurrentRun` / `Clear-CurrentRun` command via the shell. Keep each command well under the 965-byte arg ceiling.

- [ ] **Step 6: Commit**

```bash
git add scripts/runs-lib.ps1 scripts/test-runs-lib.ps1
git commit -m "feat(sp2): Set/Clear-CurrentRun + wire conductor session into the feed"
```

Then commit any command-file edits separately:

```bash
git add .claude/commands/ scripts/job-lib.ps1
git commit -m "feat(sp2): /job-start sets current-run, /job-phase done clears it"
```

(Skip the second commit if no command files needed changes — note that plainly in the task report.)

---

## Task 8: Bootstrap deployment

**Files:**
- Modify: `scripts/bootstrap.ps1`
- Test: `scripts/test-bootstrap.ps1` (verify still green)

- [ ] **Step 1: Add the bridge to the deployed script list**

In `scripts/bootstrap.ps1`, find the script-deploy loop (the `foreach ($script in @('job-lib.ps1', ... 'runs-lib.ps1', 'statusline-feed.ps1'))` array around line 250) and add `'fleet-runs-bridge.ps1'` to the list, next to `runs-lib.ps1`:

```powershell
foreach ($script in @('job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1', 'fleet-ensemble.ps1', 'six-hats-lib.ps1', 'council-lib.ps1', 'code-lib.ps1', 'kb-lib.ps1', 'decisions-lib.ps1', 'consolidate-decisions.ps1', 'cost-lib.ps1', 'runs-lib.ps1', 'statusline-feed.ps1', 'fleet-runs-bridge.ps1')) {
```

Note: `fleet-backlog.ps1` dot-sources the bridge from `$PSScriptRoot`, so wherever the backlog scripts run from, the bridge must sit beside them. Confirm `fleet-backlog.ps1` and `fleet-orchestrate.ps1` are also deployed (or run from the repo). If the fleet scripts are deployed elsewhere in bootstrap, add `fleet-runs-bridge.ps1` to that group too; if they run only from the repo, the repo copy is already adjacent and no extra action is needed.

- [ ] **Step 2: Run the bootstrap smoke test**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: existing pass marker (smoke green). It should confirm `fleet-runs-bridge.ps1` deployed if the test enumerates deployed scripts.

- [ ] **Step 3: Run a real bootstrap (idempotent) to deploy**

Run: `pwsh -NoProfile -File scripts/bootstrap.ps1`
Expected: completes; reports the bridge copied; hook + statusLine already registered (idempotent).

- [ ] **Step 4: Commit**

```bash
git add scripts/bootstrap.ps1
git commit -m "feat(sp2): deploy fleet-runs-bridge.ps1 via bootstrap"
```

---

## Task 9: End-to-end integration test (PS producer → Python reader)

**Files:**
- Modify: `dashboard/tests/test_runs_integration.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `dashboard/tests/test_runs_integration.py`. This file currently writes its own `run.json` fixtures; this test is self-contained — it shells out to `pwsh` to drive the real `Publish-ItemRun` producer, then reads it back through Python. Add these imports at the top of the file if not already present (`import json` and `from pathlib import Path` already are): `import shutil, subprocess`, `import pytest`, and `from dashboard.readers.runs import read_assignments`.

```python
pwsh = shutil.which("pwsh")
REPO = Path(__file__).resolve().parents[2]


@pytest.mark.skipif(pwsh is None, reason="pwsh not available")
def test_publish_item_run_lifecycle_to_assignments(tmp_path: Path):
    runs_root = tmp_path / "runs"
    script = (
        f". '{REPO}/scripts/fleet-runs-bridge.ps1'; "
        f"$env:ROUTING_RUNS_ROOT='{runs_root.as_posix()}'; "
        "Publish-ItemRun -Id 'issue-22' -Model 'codex' -State 'queued' -Name 'wire bridge'; "
        "Publish-ItemRun -Id 'issue-22' -Model 'codex' -State 'running' -Branch 'auto/issue-22-codex'"
    )
    subprocess.run([pwsh, "-NoProfile", "-Command", script], check=True, cwd=REPO)

    lanes = {l.model: l for l in read_assignments(runs_root)}
    assert "codex" in lanes
    assert [r.id for r in lanes["codex"].active] == ["backlog-issue-22-codex"]
    assert lanes["codex"].active[0].tree == "auto/issue-22-codex"
```

- [ ] **Step 2: Run test to verify it fails (then passes once implemented)**

Run: `python -m pytest dashboard/tests/test_runs_integration.py::test_publish_item_run_lifecycle_to_assignments -v`
Expected: PASS (Task 5 already implemented the producer; this proves the cross-language contract — PowerShell writes the feed, Python reads it).

- [ ] **Step 3: Commit**

```bash
git add dashboard/tests/test_runs_integration.py
git commit -m "test(sp2): PS Publish-ItemRun -> Python read_assignments lifecycle"
```

---

## Final gate (run before finishing the branch)

- [ ] Python: `python -m pytest dashboard kb -q` → all green
- [ ] PowerShell:
  - `pwsh -NoProfile -File scripts/test-runs-lib.ps1`
  - `pwsh -NoProfile -File scripts/test-fleet-runs-bridge.ps1`
  - `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1`
  - `pwsh -NoProfile -File scripts/test-fleet-backlog-concurrent.ps1`
  - `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
- [ ] Manual: `python -m dashboard.main`, open `http://localhost:8765`, confirm the "Fleet assignments" section renders (lanes for the fixture models; parked lane shows the needs-you question).
- [ ] Then hand off to **superpowers:finishing-a-development-branch** (gated merge to master per the project flow).

---

## Notes for the implementer

- **Status vocabulary** is fixed: `queued | running | needs-you | idle | done | failed` (see `dashboard/models/runs.py`). The bridge maps `blocked → failed`; do not invent new statuses.
- **Partial-update guards** in `Set-RunRecord` (`$PSBoundParameters.ContainsKey`) are why `Publish-ItemRun` can safely update status without resetting cost/tokens. Do not pass `-CostUsd`/`-TokensIn`/`-TokensOut` from the bridge.
- **Parent-only emission**: never add run-feed writes inside `$script:BacklogJobWorker` (the `Start-Job` worker) — it has no dot-sourced helpers and runs in a separate process.
- **Best-effort**: the `try/catch` around every bridge call is mandatory — a feed write must never abort a real merge.
- **YAGNI**: the autonomous gate driver does not auto-park. Parked runs come only from interactive/conductor `Set-RunStatus -Status needs-you` calls.
