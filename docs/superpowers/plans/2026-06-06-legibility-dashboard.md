# Legibility Dashboard (Slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A web dashboard that shows, in plain English, what every fleet run is doing — a narrow runs gutter, a detail pane, a global status strip — plus a needs-you queue that lets you answer a parked question and un-block a run.

**Architecture:** A neutral file-based **legibility feed** under `~/.claude/runs/` (per-run `run.json` + append-only `events.jsonl`, plus a global `index.json`). PowerShell producers write it (a PostToolUse hook for narration, a status-line script for session fields); the existing FastAPI/Jinja2/htmx dashboard reads it. This mirrors the existing journal/jobs pattern (readers → pydantic models → `build_router(templates)` → partials, htmx 5s polling).

**Tech Stack:** Python 3, FastAPI, Jinja2, htmx (vendored), pydantic; PowerShell 7 for producers; pytest + PS test scripts.

**Parent spec:** [`../specs/2026-06-05-legibility-dashboard-design.md`](../specs/2026-06-05-legibility-dashboard-design.md). Decisions d018, d019.

**Note:** The permission-allowlist autonomy win (spec §4) already shipped (`.claude/settings.json` + `.claude/settings.local.json`, commit `61800f1`). This plan covers the legibility dashboard + needs-you queue.

---

## Feed contract (read this once before starting)

```
~/.claude/runs/<run_id>/run.json      # one RunRecord (the status-bar + detail header)
~/.claude/runs/<run_id>/events.jsonl  # one RunEvent per line (the plain-English timeline)
~/.claude/runs/<run_id>/answer.txt    # needs-you answer channel (written by dashboard, read by agent)
~/.claude/runs/index.json             # one GlobalStrip (account timer, spend, active count)
```

`run.json` example:
```json
{"id":"run_auth-rewrite","name":"auth-rewrite","model":"claude-opus-4-8","reasoning":"high",
 "project":"coding-agent-orchestrator","tree":"master","worktree":false,"status":"running",
 "context_pct":10,"cost_usd":12.40,"tokens_in":41000,"tokens_out":7000,
 "files_touched":["auth.ts","validator.ts"],"current_step":"implement grace window",
 "parked_question":null,"started_at":"2026-06-06T03:14:00Z","updated_at":"2026-06-06T03:31:00Z"}
```

`events.jsonl` lines:
```json
{"ts":"2026-06-06T03:15:00Z","kind":"action","what":"read auth middleware + 3 callers","why":"map blast radius before editing","status":"done"}
{"ts":"2026-06-06T03:20:00Z","kind":"question","what":"rotate tokens without invalidating logins?","why":"two viable strategies","status":"open"}
```

`status` ∈ `queued | running | needs-you | idle | done | failed`.
`kind` ∈ `action | decision | question | result`.

---

## File Structure

| File | Responsibility |
|---|---|
| `dashboard/models/runs.py` | pydantic models: `RunRecord`, `RunEvent`, `RunDetail`, `GlobalStrip` |
| `dashboard/readers/runs.py` | read the feed: `list_runs`, `read_run_detail`, `read_global_strip`, `write_run_answer` |
| `dashboard/routers/runs.py` | `build_router(templates)`: gutter, detail, live partial, answer POST |
| `dashboard/templates/partials/runs_list.html` | the gutter (run cards) + global strip include |
| `dashboard/templates/partials/global_strip.html` | the footer strip |
| `dashboard/templates/run_detail.html` | full drill-in page (htmx polls the live partial) |
| `dashboard/templates/partials/run_detail_live.html` | live region: timeline, cost, answer box |
| `dashboard/tests/test_runs_reader.py` | reader unit tests |
| `dashboard/tests/test_runs_router.py` | router/route tests |
| `dashboard/tests/conftest.py` | add `runs_root` fixture (modify) |
| `dashboard/main.py` | wire the runs router + `runs_root` state (modify) |
| `scripts/runs-lib.ps1` | PowerShell feed writer: `Add-RunEvent`, `Set-RunRecord`, `Set-RunStatus`, `Set-GlobalStrip`, `Get-RunAnswer` |
| `scripts/test-runs-lib.ps1` | PS test for the writer lib |
| `scripts/hooks/run-feed.ps1` | PostToolUse hook: append a plain-English event for the active run |
| `scripts/statusline-feed.ps1` | Claude Code statusLine: write session fields to the feed, echo a status line |

---

### Task 1: Feed data models

**Files:**
- Create: `dashboard/models/runs.py`
- Test: `dashboard/tests/test_runs_reader.py` (created here, grows in Task 2)

- [ ] **Step 1: Write the failing test**

Create `dashboard/tests/test_runs_reader.py`:
```python
from datetime import datetime

from dashboard.models.runs import RunRecord, RunEvent, RunDetail, GlobalStrip


def test_run_record_defaults():
    r = RunRecord(id="run_x", name="x", model="claude-opus-4-8", status="running")
    assert r.cost_usd == 0.0
    assert r.tokens_in == 0
    assert r.files_touched == []
    assert r.parked_question is None
    assert r.worktree is False


def test_run_event_minimal():
    e = RunEvent(ts=datetime(2026, 6, 6, 3, 15), kind="action", what="read file")
    assert e.why is None
    assert e.kind == "action"


def test_run_detail_and_strip():
    rec = RunRecord(id="r", name="r", model="m", status="idle")
    d = RunDetail(record=rec, events=[])
    assert d.events == []
    s = GlobalStrip()
    assert s.spend_today_usd == 0.0
    assert s.active_runs == 0
    assert s.rate_limit_pct is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest dashboard/tests/test_runs_reader.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'dashboard.models.runs'`

- [ ] **Step 3: Write minimal implementation**

Create `dashboard/models/runs.py`:
```python
from __future__ import annotations

from datetime import datetime
from typing import Optional

from pydantic import BaseModel


class RunRecord(BaseModel):
    id: str
    name: str
    model: str
    status: str                      # queued | running | needs-you | idle | done | failed
    reasoning: Optional[str] = None
    project: Optional[str] = None
    tree: Optional[str] = None
    worktree: bool = False
    context_pct: Optional[int] = None
    cost_usd: float = 0.0
    tokens_in: int = 0
    tokens_out: int = 0
    files_touched: list[str] = []
    current_step: Optional[str] = None
    parked_question: Optional[str] = None
    started_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None


class RunEvent(BaseModel):
    ts: datetime
    kind: str                        # action | decision | question | result
    what: str
    why: Optional[str] = None
    status: Optional[str] = None


class RunDetail(BaseModel):
    record: RunRecord
    events: list[RunEvent] = []


class GlobalStrip(BaseModel):
    rate_limit_pct: Optional[int] = None
    rate_limit_resets_at: Optional[str] = None
    spend_today_usd: float = 0.0
    active_runs: int = 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest dashboard/tests/test_runs_reader.py -q`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add dashboard/models/runs.py dashboard/tests/test_runs_reader.py
git commit -m "feat(dashboard): add legibility-feed data models"
```

---

### Task 2: Feed reader

**Files:**
- Create: `dashboard/readers/runs.py`
- Modify: `dashboard/tests/conftest.py` (add `runs_root` fixture)
- Test: `dashboard/tests/test_runs_reader.py` (extend)

- [ ] **Step 1: Add the `runs_root` fixture**

Append to `dashboard/tests/conftest.py`:
```python
@pytest.fixture
def runs_root(tmp_path: Path) -> Path:
    """Two fake runs + a global index under a temporary runs root."""
    import json
    root = tmp_path / "runs"
    root.mkdir()

    r1 = root / "run_auth-rewrite"
    r1.mkdir()
    (r1 / "run.json").write_text(json.dumps({
        "id": "run_auth-rewrite", "name": "auth-rewrite",
        "model": "claude-opus-4-8", "reasoning": "high",
        "project": "coding-agent-orchestrator", "tree": "master", "worktree": False,
        "status": "running", "context_pct": 10, "cost_usd": 12.40,
        "tokens_in": 41000, "tokens_out": 7000, "files_touched": ["auth.ts"],
        "current_step": "implement grace window", "parked_question": None,
        "started_at": "2026-06-06T03:14:00+00:00", "updated_at": "2026-06-06T03:31:00+00:00",
    }), encoding="utf-8")
    (r1 / "events.jsonl").write_text(
        '{"ts":"2026-06-06T03:15:00+00:00","kind":"action","what":"read auth middleware","why":"map blast radius","status":"done"}\n'
        '{"ts":"2026-06-06T03:20:00+00:00","kind":"action","what":"wrote failing test","why":"lock the contract","status":"done"}\n',
        encoding="utf-8",
    )

    r2 = root / "run_fix-login"
    r2.mkdir()
    (r2 / "run.json").write_text(json.dumps({
        "id": "run_fix-login", "name": "fix-login", "model": "codex",
        "project": "coding-agent-orchestrator", "tree": "wt/fix-14", "worktree": True,
        "status": "needs-you", "context_pct": 22, "cost_usd": 0.40,
        "parked_question": "rotate tokens without invalidating logins?",
        "updated_at": "2026-06-06T03:25:00+00:00",
    }), encoding="utf-8")
    (r2 / "events.jsonl").write_text(
        '{"ts":"2026-06-06T03:25:00+00:00","kind":"question","what":"rotate tokens without invalidating logins?","why":"two strategies","status":"open"}\n',
        encoding="utf-8",
    )

    (root / "index.json").write_text(json.dumps({
        "rate_limit_pct": 37, "rate_limit_resets_at": "21:30",
        "spend_today_usd": 128.64, "active_runs": 2,
    }), encoding="utf-8")
    return root
```

- [ ] **Step 2: Write the failing reader tests**

Append to `dashboard/tests/test_runs_reader.py`:
```python
from pathlib import Path

from dashboard.readers.runs import (
    list_runs, read_run_detail, read_global_strip, write_run_answer,
)


def test_list_runs_sorted_active_first(runs_root: Path):
    runs = list_runs(runs_root)
    assert [r.id for r in runs] == ["run_auth-rewrite", "run_fix-login"]
    assert runs[1].status == "needs-you"


def test_list_runs_missing_root(tmp_path: Path):
    assert list_runs(tmp_path / "nope") == []


def test_list_runs_skips_corrupt(runs_root: Path):
    bad = runs_root / "run_bad"
    bad.mkdir()
    (bad / "run.json").write_text("{ not json", encoding="utf-8")
    runs = list_runs(runs_root)
    assert all(r.id != "run_bad" for r in runs)
    assert len(runs) == 2


def test_read_run_detail(runs_root: Path):
    d = read_run_detail(runs_root, "run_auth-rewrite")
    assert d.record.name == "auth-rewrite"
    assert len(d.events) == 2
    assert d.events[0].why == "map blast radius"


def test_read_run_detail_missing(runs_root: Path):
    import pytest
    with pytest.raises(FileNotFoundError):
        read_run_detail(runs_root, "run_nope")


def test_read_global_strip(runs_root: Path):
    s = read_global_strip(runs_root)
    assert s.rate_limit_pct == 37
    assert s.spend_today_usd == 128.64


def test_read_global_strip_missing_falls_back(tmp_path: Path):
    root = tmp_path / "runs"; root.mkdir()
    s = read_global_strip(root)
    assert s.spend_today_usd == 0.0
    assert s.rate_limit_pct is None


def test_write_run_answer(runs_root: Path):
    write_run_answer(runs_root, "run_fix-login", "use a grace window")
    assert (runs_root / "run_fix-login" / "answer.txt").read_text(encoding="utf-8") == "use a grace window"


def test_write_run_answer_missing_run(runs_root: Path):
    import pytest
    with pytest.raises(FileNotFoundError):
        write_run_answer(runs_root, "run_nope", "x")
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `python -m pytest dashboard/tests/test_runs_reader.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'dashboard.readers.runs'`

- [ ] **Step 4: Write minimal implementation**

Create `dashboard/readers/runs.py`:
```python
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Optional

from dashboard.models.runs import RunRecord, RunEvent, RunDetail, GlobalStrip

_ACTIVE_ORDER = {"needs-you": 0, "running": 1, "queued": 2, "idle": 3, "done": 4, "failed": 5}


def _read_record(run_dir: Path) -> Optional[RunRecord]:
    rj = run_dir / "run.json"
    if not rj.exists():
        return None
    try:
        return RunRecord(**json.loads(rj.read_text(encoding="utf-8")))
    except (json.JSONDecodeError, ValueError, TypeError):
        return None


def _sort_key(r: RunRecord):
    updated = r.updated_at or datetime.min
    # active states first; within a state, most-recently-updated first
    return (_ACTIVE_ORDER.get(r.status, 9), -updated.timestamp() if r.updated_at else 0)


def list_runs(runs_root: Path) -> list[RunRecord]:
    if not runs_root.exists():
        return []
    records: list[RunRecord] = []
    for d in runs_root.iterdir():
        if not d.is_dir():
            continue
        rec = _read_record(d)
        if rec is not None:
            records.append(rec)
    records.sort(key=_sort_key)
    return records


def _read_events(run_dir: Path) -> list[RunEvent]:
    ej = run_dir / "events.jsonl"
    if not ej.exists():
        return []
    events: list[RunEvent] = []
    for line in ej.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(RunEvent(**json.loads(line)))
        except (json.JSONDecodeError, ValueError, TypeError):
            continue
    return events


def read_run_detail(runs_root: Path, run_id: str) -> RunDetail:
    run_dir = runs_root / run_id
    rec = _read_record(run_dir)
    if rec is None:
        raise FileNotFoundError(f"No such run: {run_id}")
    return RunDetail(record=rec, events=_read_events(run_dir))


def read_global_strip(runs_root: Path) -> GlobalStrip:
    idx = runs_root / "index.json"
    if not idx.exists():
        # fall back: compute active count from runs present, leave the rest defaulted
        active = sum(1 for r in list_runs(runs_root) if r.status in ("running", "needs-you", "queued"))
        return GlobalStrip(active_runs=active)
    try:
        return GlobalStrip(**json.loads(idx.read_text(encoding="utf-8")))
    except (json.JSONDecodeError, ValueError, TypeError):
        return GlobalStrip()


def write_run_answer(runs_root: Path, run_id: str, answer: str) -> None:
    run_dir = runs_root / run_id
    if not (run_dir / "run.json").exists():
        raise FileNotFoundError(f"No such run: {run_id}")
    (run_dir / "answer.txt").write_text(answer, encoding="utf-8")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest dashboard/tests/test_runs_reader.py -q`
Expected: PASS (all reader + model tests green)

- [ ] **Step 6: Commit**

```bash
git add dashboard/readers/runs.py dashboard/tests/test_runs_reader.py dashboard/tests/conftest.py
git commit -m "feat(dashboard): add legibility-feed reader"
```

---

### Task 3: Runs router + templates (gutter · detail · global strip)

**Files:**
- Create: `dashboard/routers/runs.py`
- Create: `dashboard/templates/partials/runs_list.html`
- Create: `dashboard/templates/partials/global_strip.html`
- Create: `dashboard/templates/run_detail.html`
- Create: `dashboard/templates/partials/run_detail_live.html`
- Test: `dashboard/tests/test_runs_router.py`

- [ ] **Step 1: Write the failing router tests**

Create `dashboard/tests/test_runs_router.py`:
```python
from pathlib import Path
from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.routers.runs import build_router


def make_app(runs_root: Path) -> FastAPI:
    app = FastAPI()
    app.state.runs_root = runs_root
    here = Path(__file__).parent.parent
    templates = Jinja2Templates(directory=str(here / "templates"))
    app.include_router(build_router(templates))
    return app


def test_partial_runs_gutter(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.get("/partials/runs")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "auth-rewrite" in resp.text
    assert "fix-login" in resp.text
    # global strip rendered in the same response
    assert "128.64" in resp.text
    assert "21:30" in resp.text


def test_run_detail_full_page(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.get("/runs/run_auth-rewrite")
    assert resp.status_code == 200
    assert "implement grace window" in resp.text       # current_step
    assert "map blast radius" in resp.text             # event why
    # wires htmx polling to the live partial
    assert 'hx-get="/partials/runs/run_auth-rewrite"' in resp.text
    assert 'hx-trigger="every 5s"' in resp.text


def test_run_detail_404(runs_root: Path):
    client = TestClient(make_app(runs_root))
    assert client.get("/runs/run_nope").status_code == 404


def test_run_detail_live_partial(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.get("/partials/runs/run_auth-rewrite")
    assert resp.status_code == 200
    assert "wrote failing test" in resp.text
    assert "<!DOCTYPE html>" not in resp.text          # no base chrome


def test_needs_you_shows_answer_box(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.get("/partials/runs/run_fix-login")
    assert resp.status_code == 200
    assert "rotate tokens" in resp.text                # the parked question
    assert 'name="answer"' in resp.text                # the answer box


def test_post_answer_writes_file(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.post("/runs/run_fix-login/answer", data={"answer": "use a grace window"})
    assert resp.status_code == 200
    assert (runs_root / "run_fix-login" / "answer.txt").read_text(encoding="utf-8") == "use a grace window"


def test_post_answer_404(runs_root: Path):
    client = TestClient(make_app(runs_root))
    assert client.post("/runs/run_nope/answer", data={"answer": "x"}).status_code == 404
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest dashboard/tests/test_runs_router.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'dashboard.routers.runs'`

- [ ] **Step 3: Write the router**

Create `dashboard/routers/runs.py`:
```python
from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.readers.runs import (
    list_runs, read_run_detail, read_global_strip, write_run_answer,
)


def build_router(templates: Jinja2Templates) -> APIRouter:
    """Constructor pattern so the router shares templates with the main app."""
    router = APIRouter()

    def _runs_root(req: Request) -> Path:
        return getattr(req.app.state, "runs_root", Path.home() / ".claude" / "runs")

    @router.get("/partials/runs", response_class=HTMLResponse)
    async def partial_runs(request: Request) -> HTMLResponse:
        root = _runs_root(request)
        return templates.TemplateResponse("partials/runs_list.html", {
            "request": request,
            "runs": list_runs(root),
            "strip": read_global_strip(root),
        })

    @router.get("/runs/{run_id}", response_class=HTMLResponse)
    async def run_detail(run_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such run: {run_id}")
        return templates.TemplateResponse("run_detail.html", {
            "request": request, "detail": detail,
        })

    @router.get("/partials/runs/{run_id}", response_class=HTMLResponse)
    async def partial_run_detail(run_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such run: {run_id}")
        return templates.TemplateResponse("partials/run_detail_live.html", {
            "request": request, "detail": detail,
        })

    @router.post("/runs/{run_id}/answer", response_class=HTMLResponse)
    async def post_answer(run_id: str, request: Request, answer: str = Form(...)) -> HTMLResponse:
        try:
            write_run_answer(_runs_root(request), run_id, answer)
            detail = read_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such run: {run_id}")
        return templates.TemplateResponse("partials/run_detail_live.html", {
            "request": request, "detail": detail,
        })

    return router
```

- [ ] **Step 4: Write the templates**

Create `dashboard/templates/partials/global_strip.html`:
```html
<div class="global-strip">
  <span>⏱ 5h
    {% if strip.rate_limit_pct is not none %}{{ strip.rate_limit_pct }}%{% else %}—{% endif %}
    {% if strip.rate_limit_resets_at %}→ {{ strip.rate_limit_resets_at }}{% endif %}
  </span>
  <span>· today ${{ "%.2f"|format(strip.spend_today_usd) }}</span>
  <span>· {{ strip.active_runs }} runs</span>
</div>
```

Create `dashboard/templates/partials/runs_list.html`:
```html
<div class="runs-gutter">
  {% for r in runs %}
  <a class="run-card status-{{ r.status }}" href="/runs/{{ r.id }}"
     hx-get="/partials/runs/{{ r.id }}" hx-target="#run-detail">
    <div class="run-name">{{ r.name }}
      {% if r.status == 'needs-you' %}⏳{% elif r.status == 'running' %}🟢{% elif r.status == 'idle' %}💤{% elif r.status == 'done' %}✓{% elif r.status == 'failed' %}✗{% endif %}
    </div>
    <div class="run-meta">{{ r.model }}{% if r.tree %} · {{ r.tree }}{% endif %}</div>
    <div class="run-meta">
      {% if r.context_pct is not none %}ctx{{ r.context_pct }}%{% endif %}
      · ${{ "%.2f"|format(r.cost_usd) }}
    </div>
  </a>
  {% else %}
  <p class="muted">No runs yet.</p>
  {% endfor %}
</div>
{% include "partials/global_strip.html" %}
```

Create `dashboard/templates/partials/run_detail_live.html`:
```html
<div class="run-detail">
  <h2>{{ detail.record.name }} · {{ detail.record.model }}{% if detail.record.reasoning %}·{{ detail.record.reasoning }}{% endif %}
      {% if detail.record.tree %} · {{ detail.record.tree }}{% endif %}</h2>

  {% if detail.record.current_step %}
  <p class="now">Now: {{ detail.record.current_step }}</p>
  {% endif %}

  <ol class="timeline">
    {% for e in detail.events %}
    <li class="ev-{{ e.kind }}">
      <span class="what">{{ e.what }}</span>
      {% if e.why %}<span class="why"> — {{ e.why }}</span>{% endif %}
    </li>
    {% endfor %}
  </ol>

  <p class="cost">{{ detail.record.tokens_in }}k in / {{ detail.record.tokens_out }}k out ·
     ${{ "%.2f"|format(detail.record.cost_usd) }}
     {% if detail.record.files_touched %}· {{ detail.record.files_touched|join(", ") }}{% endif %}</p>

  {% if detail.record.status == 'needs-you' and detail.record.parked_question %}
  <div class="needs-you">
    <p class="question">⏳ Needs you: {{ detail.record.parked_question }}</p>
    <form hx-post="/runs/{{ detail.record.id }}/answer" hx-target="#run-detail">
      <input type="text" name="answer" placeholder="Your answer…" autocomplete="off">
      <button type="submit">Answer &amp; un-block</button>
    </form>
  </div>
  {% endif %}
</div>
```

Create `dashboard/templates/run_detail.html`:
```html
{% extends "base.html" %}
{% block content %}
<p><a href="/">← Back to dashboard</a></p>
<div id="run-detail"
     hx-get="/partials/runs/{{ detail.record.id }}"
     hx-trigger="every 5s">
  {% include "partials/run_detail_live.html" %}
</div>
{% endblock %}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest dashboard/tests/test_runs_router.py -q`
Expected: PASS (7 passed)

If `base.html` uses a different block name than `content`, open `dashboard/templates/base.html`, find the `{% block %}` name, and match it in `run_detail.html`.

- [ ] **Step 6: Commit**

```bash
git add dashboard/routers/runs.py dashboard/templates/partials/runs_list.html dashboard/templates/partials/global_strip.html dashboard/templates/run_detail.html dashboard/templates/partials/run_detail_live.html dashboard/tests/test_runs_router.py
git commit -m "feat(dashboard): runs gutter, detail, global strip, needs-you answer"
```

---

### Task 4: Wire the router into the app + add gutter to the home page

**Files:**
- Modify: `dashboard/main.py`
- Test: `dashboard/tests/test_runs_router.py` (add a wiring assertion)

- [ ] **Step 1: Write the failing test**

Append to `dashboard/tests/test_runs_router.py`:
```python
def test_app_registers_runs_routes():
    from dashboard.main import app
    paths = {r.path for r in app.routes}
    assert "/partials/runs" in paths
    assert "/runs/{run_id}" in paths
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest dashboard/tests/test_runs_router.py::test_app_registers_runs_routes -q`
Expected: FAIL (assert `/partials/runs` in paths)

- [ ] **Step 3: Wire the router + state in `dashboard/main.py`**

After the `ENSEMBLES_ROOT = Path(...)` block (around line 35), add:
```python
RUNS_ROOT = Path(
    os.environ.get('ROUTING_RUNS_ROOT', '')
    or Path.home() / '.claude' / 'runs'
)
```
After `app.state.ensembles_root = ENSEMBLES_ROOT` (around line 43), add:
```python
app.state.runs_root = RUNS_ROOT
```
After the kb router include (around line 58), add:
```python
from dashboard.routers.runs import build_router as build_runs_router
app.include_router(build_runs_router(templates))
```

- [ ] **Step 4: Run to verify it passes**

Run: `python -m pytest dashboard/tests/test_runs_router.py::test_app_registers_runs_routes -q`
Expected: PASS

- [ ] **Step 5: Add the gutter to the home page**

In `dashboard/templates/index.html`, add a region that loads the gutter on page load and polls (match the existing htmx pattern used by other partials on that page):
```html
<section class="runs-section">
  <h2>Runs</h2>
  <div id="runs-gutter" hx-get="/partials/runs" hx-trigger="load, every 5s"></div>
  <div id="run-detail"><p class="muted">Select a run to see what it's doing.</p></div>
</section>
```

- [ ] **Step 6: Run the full dashboard suite**

Run: `python -m pytest dashboard -q`
Expected: PASS (all green, no regressions)

- [ ] **Step 7: Commit**

```bash
git add dashboard/main.py dashboard/templates/index.html dashboard/tests/test_runs_router.py
git commit -m "feat(dashboard): register runs router and surface gutter on home"
```

---

### Task 5: PowerShell feed writer library

**Files:**
- Create: `scripts/runs-lib.ps1`
- Test: `scripts/test-runs-lib.ps1`

- [ ] **Step 1: Write the failing PS test**

Create `scripts/test-runs-lib.ps1`:
```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/runs-lib.ps1"

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("runs-test-" + [guid]::NewGuid().ToString('N'))
$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "PASS: $name" }
    else { Write-Host "FAIL: $name"; $script:fail++ }
}

try {
    Set-RunRecord -RunsRoot $root -Id 'run_t' -Name 't' -Model 'claude-opus-4-8' -Status 'running'
    $rj = Join-Path $root 'run_t/run.json'
    Check 'run.json written' (Test-Path $rj)
    $rec = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'name persisted' ($rec.name -eq 't')
    Check 'status persisted' ($rec.status -eq 'running')

    Add-RunEvent -RunsRoot $root -Id 'run_t' -Kind 'action' -What 'read file' -Why 'map blast radius'
    $ej = Join-Path $root 'run_t/events.jsonl'
    Check 'events.jsonl written' (Test-Path $ej)
    $ev = (Get-Content $ej | Select-Object -First 1) | ConvertFrom-Json
    Check 'event what' ($ev.what -eq 'read file')
    Check 'event why' ($ev.why -eq 'map blast radius')

    Set-RunStatus -RunsRoot $root -Id 'run_t' -Status 'needs-you' -ParkedQuestion 'which strategy?'
    $rec2 = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'status updated' ($rec2.status -eq 'needs-you')
    Check 'question set' ($rec2.parked_question -eq 'which strategy?')

    Set-GlobalStrip -RunsRoot $root -SpendTodayUsd 12.5 -ActiveRuns 3
    $idx = Join-Path $root 'index.json'
    Check 'index.json written' (Test-Path $idx)

    Check 'answer absent -> null' ($null -eq (Get-RunAnswer -RunsRoot $root -Id 'run_t'))
    Set-Content -Path (Join-Path $root 'run_t/answer.txt') -Value 'use a grace window' -NoNewline
    Check 'answer read back' ((Get-RunAnswer -RunsRoot $root -Id 'run_t') -eq 'use a grace window')
}
finally {
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
}

if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-runs-lib.ps1`
Expected: FAIL — `runs-lib.ps1` not found / functions undefined.

- [ ] **Step 3: Write the writer library**

Create `scripts/runs-lib.ps1`:
```powershell
#!/usr/bin/env pwsh
# Writer library for the legibility feed (~/.claude/runs/). Producers (hooks,
# status line, fleet dispatch) call these. Reads are done in Python by the dashboard.

function Get-RunsRoot([string]$RunsRoot) {
    if ($RunsRoot) { return $RunsRoot }
    if ($env:ROUTING_RUNS_ROOT) { return $env:ROUTING_RUNS_ROOT }
    return (Join-Path $HOME '.claude/runs')
}

function Ensure-RunDir([string]$RunsRoot, [string]$Id) {
    $dir = Join-Path (Get-RunsRoot $RunsRoot) $Id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Now-Iso { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Set-RunRecord {
    param(
        [string]$RunsRoot, [Parameter(Mandatory)][string]$Id, [string]$Name,
        [string]$Model, [string]$Status, [string]$Reasoning, [string]$Project,
        [string]$Tree, [bool]$Worktree = $false, [object]$ContextPct,
        [double]$CostUsd = 0, [int]$TokensIn = 0, [int]$TokensOut = 0,
        [string]$CurrentStep, [object]$ParkedQuestion
    )
    $dir = Ensure-RunDir $RunsRoot $Id
    $path = Join-Path $dir 'run.json'
    $rec = if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { [pscustomobject]@{ id = $Id; started_at = (Now-Iso) } }
    $rec | Add-Member -NotePropertyName id -NotePropertyValue $Id -Force
    if ($Name)        { $rec | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force }
    if ($Model)       { $rec | Add-Member -NotePropertyName model -NotePropertyValue $Model -Force }
    if ($Status)      { $rec | Add-Member -NotePropertyName status -NotePropertyValue $Status -Force }
    if ($Reasoning)   { $rec | Add-Member -NotePropertyName reasoning -NotePropertyValue $Reasoning -Force }
    if ($Project)     { $rec | Add-Member -NotePropertyName project -NotePropertyValue $Project -Force }
    if ($Tree)        { $rec | Add-Member -NotePropertyName tree -NotePropertyValue $Tree -Force }
    $rec | Add-Member -NotePropertyName worktree -NotePropertyValue $Worktree -Force
    if ($null -ne $ContextPct)     { $rec | Add-Member -NotePropertyName context_pct -NotePropertyValue ([int]$ContextPct) -Force }
    $rec | Add-Member -NotePropertyName cost_usd -NotePropertyValue $CostUsd -Force
    $rec | Add-Member -NotePropertyName tokens_in -NotePropertyValue $TokensIn -Force
    $rec | Add-Member -NotePropertyName tokens_out -NotePropertyValue $TokensOut -Force
    if ($CurrentStep) { $rec | Add-Member -NotePropertyName current_step -NotePropertyValue $CurrentStep -Force }
    if ($null -ne $ParkedQuestion) { $rec | Add-Member -NotePropertyName parked_question -NotePropertyValue $ParkedQuestion -Force }
    $rec | Add-Member -NotePropertyName updated_at -NotePropertyValue (Now-Iso) -Force
    $rec | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding utf8
}

function Add-RunEvent {
    param(
        [string]$RunsRoot, [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$What,
        [string]$Why, [string]$Status
    )
    $dir = Ensure-RunDir $RunsRoot $Id
    $obj = [ordered]@{ ts = (Now-Iso); kind = $Kind; what = $What }
    if ($Why)    { $obj.why = $Why }
    if ($Status) { $obj.status = $Status }
    ($obj | ConvertTo-Json -Compress) | Add-Content -Path (Join-Path $dir 'events.jsonl') -Encoding utf8
}

function Set-RunStatus {
    param([string]$RunsRoot, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Status, [object]$ParkedQuestion)
    Set-RunRecord -RunsRoot $RunsRoot -Id $Id -Status $Status -ParkedQuestion $ParkedQuestion
}

function Set-GlobalStrip {
    param([string]$RunsRoot, [object]$RateLimitPct, [string]$RateLimitResetsAt, [double]$SpendTodayUsd = 0, [int]$ActiveRuns = 0)
    $root = Get-RunsRoot $RunsRoot
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $obj = [ordered]@{ spend_today_usd = $SpendTodayUsd; active_runs = $ActiveRuns }
    if ($null -ne $RateLimitPct) { $obj.rate_limit_pct = [int]$RateLimitPct }
    if ($RateLimitResetsAt)      { $obj.rate_limit_resets_at = $RateLimitResetsAt }
    ($obj | ConvertTo-Json) | Set-Content -Path (Join-Path $root 'index.json') -Encoding utf8
}

function Get-RunAnswer {
    param([string]$RunsRoot, [Parameter(Mandatory)][string]$Id)
    $path = Join-Path (Get-RunsRoot $RunsRoot) "$Id/answer.txt"
    if (Test-Path $path) { return (Get-Content $path -Raw).TrimEnd("`r","`n") }
    return $null
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-runs-lib.ps1`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/runs-lib.ps1 scripts/test-runs-lib.ps1
git commit -m "feat(scripts): PowerShell writer library for the legibility feed"
```

---

### Task 6: PostToolUse hook — plain-English narration for the active run

**Files:**
- Create: `scripts/hooks/run-feed.ps1`
- Test: `scripts/test-run-feed-hook.ps1`

The hook reads the Claude Code PostToolUse JSON on stdin. If a pointer file
`~/.claude/current-run.json` names an active run, it appends one plain-English
event derived from the tool name + input. It never crashes Claude Code.

- [ ] **Step 1: Write the failing PS test**

Create `scripts/test-run-feed-hook.ps1`:
```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$hook = "$PSScriptRoot/hooks/run-feed.ps1"
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("runfeed-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$pointer = Join-Path $root 'current-run.json'
Set-Content -Path $pointer -Value '{"id":"run_t"}' -Encoding utf8
$fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    $evt = '{"tool_name":"Read","tool_input":{"file_path":"D:/x/auth.ts"},"tool_response":{"exit_code":0}}'
    $evt | & pwsh -NoProfile -File $hook -RunsRoot $root -PointerPath $pointer
    $ej = Join-Path $root 'run_t/events.jsonl'
    Check 'event appended' (Test-Path $ej)
    $ev = (Get-Content $ej | Select-Object -Last 1) | ConvertFrom-Json
    Check 'plain-english what' ($ev.what -like '*auth.ts*')

    # No pointer -> no crash, no event
    Remove-Item $pointer
    '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | & pwsh -NoProfile -File $hook -RunsRoot $root -PointerPath $pointer
    Check 'no pointer = no new run dir' (-not (Test-Path (Join-Path $root 'run_none')))
}
finally { if (Test-Path $root) { Remove-Item -Recurse -Force $root } }
if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-run-feed-hook.ps1`
Expected: FAIL — hook missing.

- [ ] **Step 3: Write the hook**

Create `scripts/hooks/run-feed.ps1`:
```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  PostToolUse hook: append a plain-English event for the active run to the
  legibility feed. No-ops unless ~/.claude/current-run.json names a run.
#>
param(
    [string]$RunsRoot    = $(if ($env:ROUTING_RUNS_ROOT) { $env:ROUTING_RUNS_ROOT } else { Join-Path $HOME '.claude/runs' }),
    [string]$PointerPath = (Join-Path $HOME '.claude/current-run.json'),
    [string]$ErrorPath   = (Join-Path $HOME '.claude/hooks/run-feed.err.log')
)
$ErrorActionPreference = 'Continue'  # never crash Claude Code

function Write-ErrLog($m) {
    try {
        $d = Split-Path -Parent $ErrorPath
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Add-Content -Path $ErrorPath -Value ((Get-Date -Format o) + " | " + $m)
    } catch { }
}

function Narrate($tool, $input) {
    switch ($tool) {
        'Read'      { return "read $(Split-Path -Leaf $input.file_path)" }
        'Write'     { return "wrote $(Split-Path -Leaf $input.file_path)" }
        'Edit'      { return "edited $(Split-Path -Leaf $input.file_path)" }
        'Grep'      { return "searched for `"$($input.pattern)`"" }
        'Glob'      { return "listed files matching $($input.pattern)" }
        'Bash'      { $c = "$($input.command)"; if ($c.Length -gt 60) { $c = $c.Substring(0,60) + '…' }; return "ran: $c" }
        'PowerShell'{ $c = "$($input.command)"; if ($c.Length -gt 60) { $c = $c.Substring(0,60) + '…' }; return "ran: $c" }
        'Agent'     { return "dispatched a subagent: $($input.description)" }
        default     { return $null }
    }
}

try {
    . "$PSScriptRoot/../runs-lib.ps1"
    if (-not (Test-Path $PointerPath)) { exit 0 }
    $ptr = Get-Content $PointerPath -Raw | ConvertFrom-Json
    if (-not $ptr.id) { exit 0 }

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $evt = $raw | ConvertFrom-Json
    $what = Narrate $evt.tool_name $evt.tool_input
    if (-not $what) { exit 0 }
    $status = if ($null -ne $evt.tool_response.exit_code -and $evt.tool_response.exit_code -ne 0) { 'failed' } else { 'done' }
    Add-RunEvent -RunsRoot $RunsRoot -Id $ptr.id -Kind 'action' -What $what -Status $status
    exit 0
} catch {
    Write-ErrLog "run-feed hook: $($_.Exception.Message)"
    exit 0
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-run-feed-hook.ps1`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/run-feed.ps1 scripts/test-run-feed-hook.ps1
git commit -m "feat(hooks): plain-English run narration PostToolUse hook"
```

---

### Task 7: Status-line feed script (session fields → feed)

**Files:**
- Create: `scripts/statusline-feed.ps1`
- Test: `scripts/test-statusline-feed.ps1`

Claude Code's `statusLine` command receives a JSON payload on stdin and prints a
one-line status string to stdout. This script does both: writes session fields
into the active run + global strip, and echoes the status line. **Known unknown
(spec §6):** the exact payload field names. The script reads defensively from the
documented shape and falls back to `—`; integration verifies the real fields.

- [ ] **Step 1: Write the failing PS test**

Create `scripts/test-statusline-feed.ps1`:
```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$script = "$PSScriptRoot/statusline-feed.ps1"
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("sl-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$pointer = Join-Path $root 'current-run.json'
Set-Content -Path $pointer -Value '{"id":"run_t"}' -Encoding utf8
$fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    $payload = '{"model":{"id":"claude-opus-4-8","display_name":"Opus"},"workspace":{"current_dir":"D:/Dev/coding-agent-orchestrator"},"cost":{"total_cost_usd":1.23}}'
    $out = $payload | & pwsh -NoProfile -File $script -RunsRoot $root -PointerPath $pointer
    Check 'prints a status line' ($out -and $out.Length -gt 0)
    $rj = Join-Path $root 'run_t/run.json'
    Check 'run.json updated' (Test-Path $rj)
    $rec = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'model captured' ($rec.model -eq 'claude-opus-4-8')

    # Empty/garbage payload must not crash and still print something
    $out2 = '' | & pwsh -NoProfile -File $script -RunsRoot $root -PointerPath $pointer
    Check 'survives empty stdin' ($LASTEXITCODE -eq 0)
}
finally { if (Test-Path $root) { Remove-Item -Recurse -Force $root } }
if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-statusline-feed.ps1`
Expected: FAIL — script missing.

- [ ] **Step 3: Write the status-line script**

Create `scripts/statusline-feed.ps1`:
```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Claude Code statusLine command. Writes session fields into the active run +
  global strip, then prints a one-line status string. Never throws.

.NOTE
  Field names follow Claude Code's statusLine payload; unknown/absent fields
  render as '—'. The 5-hour rate-limit timer is not assumed present (spec §6).
#>
param(
    [string]$RunsRoot    = $(if ($env:ROUTING_RUNS_ROOT) { $env:ROUTING_RUNS_ROOT } else { Join-Path $HOME '.claude/runs' }),
    [string]$PointerPath = (Join-Path $HOME '.claude/current-run.json')
)
$ErrorActionPreference = 'Continue'

function Field($obj, [string[]]$names) {
    foreach ($n in $names) {
        if ($obj -and ($obj.PSObject.Properties.Name -contains $n)) { return $obj.$n }
    }
    return $null
}

$model = '—'; $folder = '—'; $cost = $null
try {
    . "$PSScriptRoot/runs-lib.ps1"
    $raw = [Console]::In.ReadToEnd()
    if ($raw) {
        $p = $raw | ConvertFrom-Json
        $modelObj = Field $p @('model')
        $model    = (Field $modelObj @('id','display_name')) ; if (-not $model) { $model = '—' }
        $ws       = Field $p @('workspace')
        $dir      = Field $ws @('current_dir','cwd')
        if ($dir) { $folder = Split-Path -Leaf $dir }
        $costObj  = Field $p @('cost')
        $cost     = Field $costObj @('total_cost_usd')

        if (Test-Path $PointerPath) {
            $ptr = Get-Content $PointerPath -Raw | ConvertFrom-Json
            if ($ptr.id) {
                $args = @{ RunsRoot = $RunsRoot; Id = $ptr.id }
                if ($model -ne '—') { $args.Model = $model }
                if ($folder -ne '—') { $args.Project = $folder }
                if ($null -ne $cost) { $args.CostUsd = [double]$cost }
                Set-RunRecord @args
            }
        }
        if ($null -ne $cost) { Set-GlobalStrip -RunsRoot $RunsRoot -SpendTodayUsd ([double]$cost) -ActiveRuns 0 }
    }
} catch { }

$costStr = if ($null -ne $cost) { '$' + ('{0:N2}' -f [double]$cost) } else { '$—' }
Write-Output "$model · $costStr · 📁 $folder"
exit 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-statusline-feed.ps1`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/statusline-feed.ps1 scripts/test-statusline-feed.ps1
git commit -m "feat(scripts): statusLine feed writer with defensive field parsing"
```

---

### Task 8: End-to-end integration test + deploy wiring

**Files:**
- Create: `dashboard/tests/test_runs_integration.py`
- Modify: `scripts/bootstrap.ps1` (deploy the two new scripts + hook; register the run-feed hook and statusLine)
- Modify: `README.md` (one line under Tests)

- [ ] **Step 1: Write the lifecycle integration test (Python drives the feed via files)**

Create `dashboard/tests/test_runs_integration.py`:
```python
import json
from pathlib import Path
from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.routers.runs import build_router


def make_app(runs_root: Path) -> FastAPI:
    app = FastAPI()
    app.state.runs_root = runs_root
    here = Path(__file__).parent.parent
    app.include_router(build_router(Jinja2Templates(directory=str(here / "templates"))))
    return app


def _write_run(root: Path, rid: str, **fields):
    d = root / rid; d.mkdir(parents=True, exist_ok=True)
    base = {"id": rid, "name": rid, "model": "m", "status": "running"}
    base.update(fields)
    (d / "run.json").write_text(json.dumps(base), encoding="utf-8")


def test_full_lifecycle(tmp_path: Path):
    root = tmp_path / "runs"; root.mkdir()
    client = TestClient(make_app(root))

    # queued -> running with an event
    _write_run(root, "run_e", status="running", current_step="building")
    (root / "run_e" / "events.jsonl").write_text(
        '{"ts":"2026-06-06T03:00:00+00:00","kind":"action","what":"started","status":"done"}\n',
        encoding="utf-8")
    assert "run_e" in client.get("/partials/runs").text

    # becomes needs-you
    _write_run(root, "run_e", status="needs-you", parked_question="ship it?")
    detail = client.get("/partials/runs/run_e")
    assert "ship it?" in detail.text and 'name="answer"' in detail.text

    # user answers -> answer.txt written
    resp = client.post("/runs/run_e/answer", data={"answer": "yes"})
    assert resp.status_code == 200
    assert (root / "run_e" / "answer.txt").read_text(encoding="utf-8") == "yes"

    # agent resumes -> done
    _write_run(root, "run_e", status="done", current_step="finished")
    assert "run_e" in client.get("/partials/runs").text
```

- [ ] **Step 2: Run to verify it passes**

Run: `python -m pytest dashboard/tests/test_runs_integration.py -q`
Expected: PASS (1 passed)

- [ ] **Step 3: Run the entire suite (Python + the three PS tests)**

Run:
```
python -m pytest dashboard kb -q
pwsh -NoProfile -File scripts/test-runs-lib.ps1
pwsh -NoProfile -File scripts/test-run-feed-hook.ps1
pwsh -NoProfile -File scripts/test-statusline-feed.ps1
```
Expected: all green.

- [ ] **Step 4: Add deploy wiring to `scripts/bootstrap.ps1`**

Find where existing hooks/scripts are copied to `~/.claude/` (the deploy section that already handles `scripts/hooks/*.ps1` and `scripts/*.ps1`). Confirm `runs-lib.ps1`, `hooks/run-feed.ps1`, and `statusline-feed.ps1` are included by the existing copy globs; if the globs are explicit lists, add these three filenames. Then register the run-feed hook in the PostToolUse array using the existing `Add-HookEntry` helper (the same one that registers `log-tool-call.ps1`), pointing at `~/.claude/scripts/hooks/run-feed.ps1`. Add a `statusLine` settings entry pointing at `~/.claude/scripts/statusline-feed.ps1` only if one is not already present (idempotent, like the other settings writes). Do not remove the existing `log-tool-call.ps1` hook — both run.

- [ ] **Step 5: Verify bootstrap still passes its smoke test**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS (existing smoke test green; the new files deploy without error).

- [ ] **Step 6: Add the PS tests + a doc line, then commit**

Add under the README "Tests" PowerShell list:
```
pwsh -NoProfile -File scripts\test-runs-lib.ps1
pwsh -NoProfile -File scripts\test-run-feed-hook.ps1
pwsh -NoProfile -File scripts\test-statusline-feed.ps1
```

```bash
git add dashboard/tests/test_runs_integration.py scripts/bootstrap.ps1 README.md
git commit -m "test+deploy: legibility feed lifecycle test and bootstrap wiring"
```

---

## Done criteria (verify against spec §1)

1. Gutter (cards) + detail pane + global strip render and live-poll — Tasks 3, 4. ✓
2. Detail reads as plain English (what + why) — Tasks 2, 3, 6. ✓
3. `⏳ needs-you` shows the parked question + answer box; POST writes `answer.txt` to un-block — Tasks 3, 8. ✓
4. Permission allowlist — shipped pre-plan (commit `61800f1`). ✓
5. Offline: no network calls in the render path; the LMS network is already patched off in tests — preserved. ✓

## Notes for the implementer

- **Run the Python suite with** `python -m pytest dashboard -q` from the repo root (the package imports are absolute, e.g. `dashboard.readers.runs`).
- **Token display:** the detail template prints `tokens_in`/`tokens_out` as raw integers with a "k" suffix label; if you want true thousands you can divide in the reader later — out of scope for Slice 1, keep it simple.
- **The status-line field names are the one known unknown.** Task 7 is written to tolerate missing fields. When you wire it for real, run `claude` with the statusLine configured, capture one payload, and confirm `model`, `workspace.current_dir`, and `cost.total_cost_usd` exist; adjust `Field` lookups if Claude Code uses different names. The 5-hour rate-limit timer stays `—` until confirmed available.
- **`current-run.json` pointer:** Slice 1 narrates whatever run the pointer names. Wiring fleet dispatch to set/clear that pointer per dispatched run is a thin follow-up (it belongs with the dispatch scripts, not this dashboard slice).
- **Card click loads the partial, not the full page:** gutter cards `hx-get="/partials/runs/{id}"` into `#run-detail`; the `href="/runs/{id}"` is the no-JS / deep-link fallback (full page, which polls itself). The home-page detail pane shows a snapshot until re-clicked; only the standalone `/runs/{id}` page auto-polls — acceptable for Slice 1.
- **Styling is a deliberate follow-up.** The templates reference new CSS classes (`.runs-gutter`, `.run-card`, `.run-meta`, `.global-strip`, `.run-detail`, `.timeline`, `.needs-you`, `.status-*`) that don't exist in `dashboard/static/style.css` yet — the feature is functional but unstyled until added. Because look-and-feel (the narrow gutter, the per-status glyphs, eventually the pixel sprites) is a stated priority, do the styling pass **with the `frontend-design` skill** after the functional tasks are green, rather than baking blind CSS into this plan. The gutter should be a narrow fixed-width column; the detail pane fills the rest; the global strip pins to the bottom.
