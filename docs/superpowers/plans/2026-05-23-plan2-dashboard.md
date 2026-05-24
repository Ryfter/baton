# Plan 2: Routing Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Multi-model execution:** This plan uses two git worktrees executed in parallel by different models:
> - **Worktree A** (branch `plan2/backend`) → dispatched to **Codex** via `/codex`
> - **Worktree B** (branch `plan2/frontend`) → dispatched to **GitHub Copilot** via `/github`
> - **Integration tasks** run on `master` after both worktrees are merged (Claude)

**Goal:** Build a FastAPI + htmx web dashboard at `http://localhost:8765` that shows live routing activity, today's API cost, a per-model leaderboard, and Ollama controls — all driven by Plan 1's journal file.

**Architecture:** FastAPI serves Jinja2 templates and a JSON stats endpoint; htmx polls three partial routes (5–30 s intervals) for live updates with no JavaScript build step; Chart.js renders a model-cost doughnut chart from the `/api/stats` JSON endpoint. All data is read from `~/.claude/model-routing-log.md` (Plan 1's journal) — no database.

**Tech Stack:** Python 3.11+, FastAPI 0.115+, uvicorn, Jinja2, htmx 2.x (CDN), Chart.js 4.x (CDN), pytest, httpx

---

## API Contract — Read Before Diverging

**Both worktrees depend on this interface. Codex implements the backend that produces it; GitHub Copilot implements the frontend that consumes it.**

### Journal Line Formats (backend reads these)

```
# Bash tool dispatch:
2026-05-23T10:00:00-06:00 | hook | bash:ollama run devstral:24b 'Hello' | 2s | exit:0

# Agent tool dispatch (has optional brief at the end):
2026-05-23T10:25:00-06:00 | hook | agent:claude-subagent | 0s | exit:0 | "spec review task"

# OTel cost event (written by parse-otel.ps1):
2026-05-23T10:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request

# Manual note (written by /log-routing command):
2026-05-23T10:10:00-06:00 | note | devstral | "used for smoke test"

# Dashboard control action (written by Plan 2 controls — append-only):
2026-05-23T10:30:00-06:00 | dashboard | ollama:stop-all | devstral:24b
```

Rules:
- Pipe characters in payload are sanitized to `¦` by the hook. Never split on `¦`.
- Lines not matching an ISO-8601 timestamp prefix are skipped (headers, blank, fences).
- The `brief` field (parts[5]) is present only when non-empty; always strip surrounding `"`.

### `GET /api/stats` — JSON Response Schema

```json
{
  "today_cost_usd": 0.47,
  "total_otel_calls": 23,
  "models": [
    {
      "name": "claude-sonnet-4-6",
      "calls": 15,
      "cost_usd": 0.38,
      "tokens_in": 45231,
      "tokens_out": 12847
    }
  ],
  "recent_hooks": [
    {
      "timestamp": "2026-05-23T10:00:00-06:00",
      "target": "bash:ollama run devstral:24b 'Hello'",
      "duration_s": 2,
      "exit_code": 0,
      "brief": null
    }
  ],
  "ollama_models": [
    { "name": "devstral:24b", "status": "running", "size": "14GB" }
  ],
  "last_updated": "2026-05-23T10:35:00-06:00"
}
```

### Template Context for `GET /`

```python
{
    "stats": DashboardStats,   # same shape as /api/stats
    "server_time": "2026-05-23 10:35:00 -0600",
}
```

### Partial Routes (htmx polling targets)

| Route | Interval | Template |
|---|---|---|
| `GET /partials/activity` | 5 s | `partials/activity_rows.html` — receives `{"stats": DashboardStats}` |
| `GET /partials/leaderboard` | 30 s | `partials/leaderboard.html` — receives `{"stats": DashboardStats}` |
| `GET /partials/spend` | 30 s | `partials/spend_today.html` — receives `{"stats": DashboardStats}` |

---

## Worktree Setup (Claude — run before dispatching)

```bash
cd D:\Dev\coding-agent-orchestrator
git worktree add .worktrees/plan2-backend -b plan2/backend
git worktree add .worktrees/plan2-frontend -b plan2/frontend
```

Then dispatch:
- `/codex` → point it at `.worktrees/plan2-backend`, execute **Worktree A tasks (1–5)**
- `/github` → point it at `.worktrees/plan2-frontend`, execute **Worktree B tasks (6–8)**

Both run in parallel. Integration tasks (9–12) run on `master` after both are merged.

---

## WORKTREE A — Backend (Codex)
*Working directory: `D:\Dev\coding-agent-orchestrator\.worktrees\plan2-backend`*

### Task 1: Project Scaffold

**Files:**
- Create: `dashboard/requirements.txt`
- Create: `dashboard/__init__.py`
- Create: `dashboard/models/__init__.py`
- Create: `dashboard/readers/__init__.py`
- Create: `dashboard/routers/__init__.py`
- Create: `dashboard/tests/__init__.py`
- Create: `dashboard/tests/conftest.py`

- [ ] **Step 1: Create directory structure**

```powershell
New-Item -ItemType Directory -Force -Path dashboard/models, dashboard/readers, dashboard/routers, dashboard/tests, dashboard/templates/partials, dashboard/static
```

- [ ] **Step 2: Write `dashboard/requirements.txt`**

```
fastapi==0.115.12
uvicorn[standard]==0.34.2
jinja2==3.1.6
httpx==0.28.1
pytest==8.3.5
pytest-asyncio==0.25.3
```

- [ ] **Step 3: Create empty `__init__.py` files**

Create these four files, all empty:
- `dashboard/__init__.py`
- `dashboard/models/__init__.py`
- `dashboard/readers/__init__.py`
- `dashboard/routers/__init__.py`
- `dashboard/tests/__init__.py`

- [ ] **Step 4: Write `dashboard/tests/conftest.py`**

```python
# dashboard/tests/conftest.py
import pytest
from pathlib import Path

SAMPLE_JOURNAL = """\
# Model Routing Log

## Activity

2026-05-23T10:00:00-06:00 | hook | bash:ollama run devstral:24b 'Hello' | 2s | exit:0
2026-05-23T10:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request
2026-05-23T10:10:00-06:00 | note | devstral | "used for smoke test"
2026-05-23T10:15:00-06:00 | otel | claude-haiku-4-5 | in:512 out:128 | $0.0011 | api_request
2026-05-23T10:20:00-06:00 | hook | bash:ollama run llava 'describe image' | 5s | exit:0
2026-05-23T10:25:00-06:00 | hook | agent:claude-subagent | 0s | exit:0 | "spec review task"
"""


@pytest.fixture
def journal_file(tmp_path: Path) -> Path:
    p = tmp_path / "model-routing-log.md"
    p.write_text(SAMPLE_JOURNAL, encoding="utf-8")
    return p
```

- [ ] **Step 5: Install dependencies**

```powershell
pip install -r dashboard/requirements.txt
```

Expected output ends with: `Successfully installed fastapi-0.115.12 ...`

- [ ] **Step 6: Verify pytest discovers tests (empty suite is fine)**

```powershell
python -m pytest dashboard/tests/ -v --collect-only
```

Expected: `no tests ran` or `collected 0 items` — no errors.

- [ ] **Step 7: Commit scaffold**

```powershell
git add dashboard/
git commit -m "chore(dashboard): project scaffold + requirements"
```

---

### Task 2: Pydantic Models

**Files:**
- Create: `dashboard/models/events.py`
- Create: `dashboard/tests/test_models.py`

- [ ] **Step 1: Write failing test**

```python
# dashboard/tests/test_models.py
import pytest
from datetime import datetime
from dashboard.models.events import (
    HookEntry, OtelEntry, NoteEntry, ModelStats, DashboardStats, OllamaModel
)


def test_hook_entry_fields():
    e = HookEntry(
        timestamp=datetime(2026, 5, 23, 10, 0, 0),
        target="bash:ollama run devstral:24b 'Hello'",
        duration_s=2,
        exit_code=0,
    )
    assert e.target == "bash:ollama run devstral:24b 'Hello'"
    assert e.duration_s == 2
    assert e.exit_code == 0
    assert e.brief is None


def test_hook_entry_with_brief():
    e = HookEntry(
        timestamp=datetime(2026, 5, 23, 10, 25, 0),
        target="agent:claude-subagent",
        duration_s=0,
        exit_code=0,
        brief="spec review task",
    )
    assert e.brief == "spec review task"


def test_otel_entry_fields():
    e = OtelEntry(
        timestamp=datetime(2026, 5, 23, 10, 5, 0),
        model="claude-sonnet-4-6",
        input_tokens=3214,
        output_tokens=892,
        cost_usd=0.0231,
    )
    assert e.model == "claude-sonnet-4-6"
    assert e.cost_usd == pytest.approx(0.0231)


def test_dashboard_stats_defaults():
    s = DashboardStats(
        today_cost_usd=0.0,
        total_otel_calls=0,
        models=[],
        recent_hooks=[],
        ollama_models=[],
        last_updated=datetime(2026, 5, 23, 10, 0, 0),
    )
    assert s.today_cost_usd == 0.0
    assert s.models == []
    assert s.ollama_models == []
```

- [ ] **Step 2: Run to verify it fails**

```powershell
python -m pytest dashboard/tests/test_models.py -v
```

Expected: `ImportError: cannot import name 'HookEntry' from 'dashboard.models.events'`

- [ ] **Step 3: Write `dashboard/models/events.py`**

```python
# dashboard/models/events.py
from __future__ import annotations
from datetime import datetime
from typing import Optional
from pydantic import BaseModel


class HookEntry(BaseModel):
    timestamp: datetime
    target: str           # "bash:ollama run devstral:24b 'Hello'" or "agent:claude-subagent"
    duration_s: int       # parsed from "2s"
    exit_code: int        # parsed from "exit:0"
    brief: Optional[str] = None   # description for agent hooks; None for bash hooks


class OtelEntry(BaseModel):
    timestamp: datetime
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float


class NoteEntry(BaseModel):
    timestamp: datetime
    target: str           # model name or other target
    text: str             # the observation text (quotes stripped)


class OllamaModel(BaseModel):
    name: str
    status: str           # "running" or "idle"
    size: str             # e.g. "14GB"


class ModelStats(BaseModel):
    name: str
    calls: int
    cost_usd: float
    tokens_in: int
    tokens_out: int


class DashboardStats(BaseModel):
    today_cost_usd: float
    total_otel_calls: int
    models: list[ModelStats]
    recent_hooks: list[HookEntry]
    ollama_models: list[OllamaModel]
    last_updated: datetime
```

- [ ] **Step 4: Run to verify it passes**

```powershell
python -m pytest dashboard/tests/test_models.py -v
```

Expected: `4 passed`

- [ ] **Step 5: Commit**

```powershell
git add dashboard/models/events.py dashboard/tests/test_models.py
git commit -m "feat(dashboard): Pydantic event models"
```

---

### Task 3: Journal Reader

**Files:**
- Create: `dashboard/readers/journal.py`
- Create: `dashboard/tests/test_journal.py`

- [ ] **Step 1: Write failing tests**

```python
# dashboard/tests/test_journal.py
import pytest
from pathlib import Path
from dashboard.readers.journal import read_journal, parse_journal_line
from dashboard.models.events import HookEntry, OtelEntry, NoteEntry


def test_parse_bash_hook_line():
    line = "2026-05-23T10:00:00-06:00 | hook | bash:ollama run devstral:24b 'Hello' | 2s | exit:0"
    entry = parse_journal_line(line)
    assert isinstance(entry, HookEntry)
    assert entry.target == "bash:ollama run devstral:24b 'Hello'"
    assert entry.duration_s == 2
    assert entry.exit_code == 0
    assert entry.brief is None


def test_parse_agent_hook_line():
    line = '2026-05-23T10:25:00-06:00 | hook | agent:claude-subagent | 0s | exit:0 | "spec review task"'
    entry = parse_journal_line(line)
    assert isinstance(entry, HookEntry)
    assert entry.target == "agent:claude-subagent"
    assert entry.duration_s == 0
    assert entry.exit_code == 0
    assert entry.brief == "spec review task"


def test_parse_otel_line():
    line = "2026-05-23T10:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request"
    entry = parse_journal_line(line)
    assert isinstance(entry, OtelEntry)
    assert entry.model == "claude-sonnet-4-6"
    assert entry.input_tokens == 3214
    assert entry.output_tokens == 892
    assert entry.cost_usd == pytest.approx(0.0231)


def test_parse_note_line():
    line = '2026-05-23T10:10:00-06:00 | note | devstral | "used for smoke test"'
    entry = parse_journal_line(line)
    assert isinstance(entry, NoteEntry)
    assert entry.target == "devstral"
    assert "smoke test" in entry.text


def test_skip_header_lines():
    assert parse_journal_line("# Model Routing Log") is None
    assert parse_journal_line("") is None
    assert parse_journal_line("## Activity") is None
    assert parse_journal_line("> append-only journal") is None


def test_read_journal_counts(journal_file: Path):
    entries = read_journal(journal_file)
    # fixture has 3 hooks + 2 otel + 1 note = 6 entries
    assert len(entries) == 6
    hooks = [e for e in entries if isinstance(e, HookEntry)]
    otels = [e for e in entries if isinstance(e, OtelEntry)]
    assert len(hooks) == 3
    assert len(otels) == 2


def test_read_journal_missing_file():
    entries = read_journal(Path("/nonexistent/path.md"))
    assert entries == []
```

- [ ] **Step 2: Run to verify failure**

```powershell
python -m pytest dashboard/tests/test_journal.py -v
```

Expected: `ImportError: cannot import name 'read_journal' from 'dashboard.readers.journal'`

- [ ] **Step 3: Write `dashboard/readers/journal.py`**

```python
# dashboard/readers/journal.py
from __future__ import annotations
import re
from datetime import datetime
from pathlib import Path
from typing import Optional, Union

from dashboard.models.events import HookEntry, OtelEntry, NoteEntry

JournalEntry = Union[HookEntry, OtelEntry, NoteEntry]

_TS_RE = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{2}:\d{2}')
_DURATION_RE = re.compile(r'(\d+)s')
_EXIT_RE = re.compile(r'exit:(-?\d+)')
_OTEL_TOKENS_RE = re.compile(r'in:(\d+)\s+out:(\d+)')
_OTEL_COST_RE = re.compile(r'\$([0-9]+(?:\.[0-9]+)?)')


def parse_journal_line(line: str) -> Optional[JournalEntry]:
    """Parse one journal line. Returns None for headers, blanks, and unrecognized formats."""
    line = line.strip()
    if not line or not _TS_RE.match(line):
        return None

    parts = [p.strip() for p in line.split('|')]
    if len(parts) < 3:
        return None

    ts_str, source = parts[0], parts[1]
    try:
        ts = datetime.fromisoformat(ts_str)
    except ValueError:
        return None

    if source == 'hook':
        if len(parts) < 5:
            return None
        target = parts[2]
        dur_m = _DURATION_RE.search(parts[3])
        exit_m = _EXIT_RE.search(parts[4])
        duration_s = int(dur_m.group(1)) if dur_m else 0
        exit_code = int(exit_m.group(1)) if exit_m else -1
        brief = parts[5].strip('"') if len(parts) > 5 and parts[5] else None
        return HookEntry(
            timestamp=ts, target=target,
            duration_s=duration_s, exit_code=exit_code, brief=brief,
        )

    if source == 'otel':
        if len(parts) < 5:
            return None
        model = parts[2]
        tok_m = _OTEL_TOKENS_RE.search(parts[3])
        cost_m = _OTEL_COST_RE.search(parts[4])
        if not tok_m:
            return None
        return OtelEntry(
            timestamp=ts,
            model=model,
            input_tokens=int(tok_m.group(1)),
            output_tokens=int(tok_m.group(2)),
            cost_usd=float(cost_m.group(1)) if cost_m else 0.0,
        )

    if source == 'note':
        target = parts[2] if len(parts) > 2 else ''
        text = parts[3].strip('"') if len(parts) > 3 else ''
        return NoteEntry(timestamp=ts, target=target, text=text)

    # 'dashboard' and unknown sources: skip
    return None


def read_journal(path: Path) -> list[JournalEntry]:
    """Read all parseable entries from a journal file. Returns [] if file missing."""
    if not path.exists():
        return []
    entries: list[JournalEntry] = []
    for line in path.read_text(encoding='utf-8').splitlines():
        entry = parse_journal_line(line)
        if entry is not None:
            entries.append(entry)
    return entries
```

- [ ] **Step 4: Run to verify it passes**

```powershell
python -m pytest dashboard/tests/test_journal.py -v
```

Expected: `8 passed`

- [ ] **Step 5: Commit**

```powershell
git add dashboard/readers/journal.py dashboard/tests/test_journal.py
git commit -m "feat(dashboard): journal reader + tests"
```

---

### Task 4: Stats Aggregator

**Files:**
- Create: `dashboard/readers/stats.py`
- Create: `dashboard/tests/test_stats.py`

- [ ] **Step 1: Write failing tests**

```python
# dashboard/tests/test_stats.py
import pytest
from pathlib import Path
from dashboard.readers.stats import compute_stats
from dashboard.models.events import DashboardStats


def test_returns_dashboard_stats(journal_file: Path):
    stats = compute_stats(journal_file)
    assert isinstance(stats, DashboardStats)


def test_model_leaderboard_names(journal_file: Path):
    stats = compute_stats(journal_file)
    names = [m.name for m in stats.models]
    assert "claude-sonnet-4-6" in names
    assert "claude-haiku-4-5" in names


def test_model_cost_sonnet(journal_file: Path):
    stats = compute_stats(journal_file)
    sonnet = next(m for m in stats.models if m.name == "claude-sonnet-4-6")
    assert sonnet.calls == 1
    assert sonnet.cost_usd == pytest.approx(0.0231)
    assert sonnet.tokens_in == 3214
    assert sonnet.tokens_out == 892


def test_total_otel_calls(journal_file: Path):
    stats = compute_stats(journal_file)
    assert stats.total_otel_calls == 2


def test_recent_hooks_count(journal_file: Path):
    stats = compute_stats(journal_file)
    # fixture has 3 hook lines
    assert len(stats.recent_hooks) == 3
    assert stats.recent_hooks[0].target == "bash:ollama run devstral:24b 'Hello'"


def test_missing_journal_returns_zeros():
    stats = compute_stats(Path("/nonexistent/log.md"))
    assert stats.today_cost_usd == 0.0
    assert stats.total_otel_calls == 0
    assert stats.models == []


def test_models_sorted_by_cost_descending(journal_file: Path):
    stats = compute_stats(journal_file)
    costs = [m.cost_usd for m in stats.models]
    assert costs == sorted(costs, reverse=True)
```

- [ ] **Step 2: Run to verify failure**

```powershell
python -m pytest dashboard/tests/test_stats.py -v
```

Expected: `ImportError: cannot import name 'compute_stats' from 'dashboard.readers.stats'`

- [ ] **Step 3: Write `dashboard/readers/stats.py`**

```python
# dashboard/readers/stats.py
from __future__ import annotations
from collections import defaultdict
from datetime import datetime, date
from pathlib import Path

from dashboard.models.events import (
    DashboardStats, ModelStats, HookEntry, OtelEntry, OllamaModel,
)
from dashboard.readers.journal import read_journal


def compute_stats(journal_path: Path) -> DashboardStats:
    """Aggregate journal entries into dashboard stats. Reads from disk every call."""
    entries = read_journal(journal_path)
    today = date.today()

    otel_entries = [e for e in entries if isinstance(e, OtelEntry)]
    hook_entries = [e for e in entries if isinstance(e, HookEntry)]

    today_cost = sum(
        e.cost_usd for e in otel_entries if e.timestamp.date() == today
    )

    # Aggregate per-model stats (all time)
    agg: dict[str, dict] = defaultdict(
        lambda: {'calls': 0, 'cost_usd': 0.0, 'tokens_in': 0, 'tokens_out': 0}
    )
    for e in otel_entries:
        agg[e.model]['calls'] += 1
        agg[e.model]['cost_usd'] += e.cost_usd
        agg[e.model]['tokens_in'] += e.input_tokens
        agg[e.model]['tokens_out'] += e.output_tokens

    models = sorted(
        [ModelStats(name=name, **data) for name, data in agg.items()],
        key=lambda m: m.cost_usd,
        reverse=True,
    )

    return DashboardStats(
        today_cost_usd=round(today_cost, 4),
        total_otel_calls=len(otel_entries),
        models=models,
        recent_hooks=hook_entries[-20:],
        ollama_models=[],          # populated live by the API route
        last_updated=datetime.now().astimezone(),
    )
```

- [ ] **Step 4: Run to verify it passes**

```powershell
python -m pytest dashboard/tests/test_stats.py -v
```

Expected: `7 passed`

- [ ] **Step 5: Commit**

```powershell
git add dashboard/readers/stats.py dashboard/tests/test_stats.py
git commit -m "feat(dashboard): stats aggregator + tests"
```

---

### Task 5: FastAPI Routes + Ollama Control

**Files:**
- Create: `dashboard/routers/api.py`
- Create: `dashboard/routers/controls.py`
- Create: `dashboard/tests/test_routes.py`

- [ ] **Step 1: Write failing tests**

```python
# dashboard/tests/test_routes.py
import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock
from fastapi import FastAPI
from fastapi.testclient import TestClient

from dashboard.routers.api import router as api_router
from dashboard.routers.controls import router as controls_router


def make_test_app(journal_file: Path) -> FastAPI:
    app = FastAPI()
    app.state.journal_path = journal_file
    app.include_router(api_router)
    app.include_router(controls_router)
    return app


def test_stats_200(journal_file: Path):
    client = TestClient(make_test_app(journal_file))
    assert client.get("/api/stats").status_code == 200


def test_stats_shape(journal_file: Path):
    data = TestClient(make_test_app(journal_file)).get("/api/stats").json()
    assert "today_cost_usd" in data
    assert "total_otel_calls" in data
    assert "models" in data
    assert "recent_hooks" in data
    assert "ollama_models" in data


def test_stats_model_names(journal_file: Path):
    data = TestClient(make_test_app(journal_file)).get("/api/stats").json()
    names = [m["name"] for m in data["models"]]
    assert "claude-sonnet-4-6" in names


def test_ollama_stop_all_200(journal_file: Path):
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = "NAME\n"   # just header line — no running models
    with patch("dashboard.routers.controls.subprocess.run", return_value=mock_result):
        resp = TestClient(make_test_app(journal_file)).post("/controls/ollama/stop-all")
    assert resp.status_code == 200
    assert "stopped" in resp.json()


def test_ollama_stop_all_stops_models(journal_file: Path):
    calls = []
    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        r = MagicMock()
        r.returncode = 0
        r.stdout = "NAME\ndevstral:24b   abc   5 GB   Running\n" if cmd == ["ollama", "ps"] else ""
        return r

    with patch("dashboard.routers.controls.subprocess.run", side_effect=fake_run):
        resp = TestClient(make_test_app(journal_file)).post("/controls/ollama/stop-all")
    assert resp.status_code == 200
    assert "devstral:24b" in resp.json()["stopped"]
```

- [ ] **Step 2: Run to verify failure**

```powershell
python -m pytest dashboard/tests/test_routes.py -v
```

Expected: `ImportError: cannot import name 'router' from 'dashboard.routers.api'`

- [ ] **Step 3: Write `dashboard/routers/api.py`**

```python
# dashboard/routers/api.py
from __future__ import annotations
from pathlib import Path
from fastapi import APIRouter, Request
from dashboard.readers.stats import compute_stats
from dashboard.models.events import DashboardStats

router = APIRouter()


def _journal_path(request: Request) -> Path:
    return getattr(
        request.app.state,
        'journal_path',
        Path.home() / '.claude' / 'model-routing-log.md',
    )


@router.get("/api/stats", response_model=DashboardStats)
async def get_stats(request: Request) -> DashboardStats:
    return compute_stats(_journal_path(request))
```

- [ ] **Step 4: Write `dashboard/routers/controls.py`**

```python
# dashboard/routers/controls.py
from __future__ import annotations
import subprocess
from fastapi import APIRouter

router = APIRouter()


@router.post("/controls/ollama/stop-all")
async def ollama_stop_all() -> dict:
    """Stop all running Ollama models by listing via `ollama ps` then stopping each."""
    result = subprocess.run(
        ["ollama", "ps"],
        capture_output=True, text=True, timeout=10,
    )
    lines = result.stdout.strip().splitlines()
    stopped: list[str] = []
    for line in lines[1:]:          # skip header row
        parts = line.split()
        if parts:
            model_name = parts[0]
            subprocess.run(
                ["ollama", "stop", model_name],
                capture_output=True, text=True, timeout=10,
            )
            stopped.append(model_name)
    return {"stopped": stopped, "count": len(stopped)}
```

- [ ] **Step 5: Run to verify it passes**

```powershell
python -m pytest dashboard/tests/test_routes.py -v
```

Expected: `5 passed`

- [ ] **Step 6: Run full backend suite**

```powershell
python -m pytest dashboard/tests/ -v
```

Expected: All tests pass (models + journal + stats + routes).

- [ ] **Step 7: Commit**

```powershell
git add dashboard/routers/api.py dashboard/routers/controls.py dashboard/tests/test_routes.py
git commit -m "feat(dashboard): API stats + Ollama controls + tests"
```

---

## WORKTREE B — Frontend (GitHub Copilot)
*Working directory: `D:\Dev\coding-agent-orchestrator\.worktrees\plan2-frontend`*

**Note:** This worktree starts from the same `master` HEAD. Do NOT run `pip install` or create Python files — the backend worktree owns those. Only create `dashboard/templates/` and `dashboard/static/`.

### Task 6: Base Template + CSS

**Files:**
- Create: `dashboard/templates/base.html`
- Create: `dashboard/static/style.css`

- [ ] **Step 1: Create directories**

```powershell
New-Item -ItemType Directory -Force -Path dashboard/templates/partials, dashboard/static
```

- [ ] **Step 2: Write `dashboard/templates/base.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{% block title %}Routing Dashboard{% endblock %}</title>
  <script src="https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.min.js"></script>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <header>
    <h1>🐙 Routing Dashboard</h1>
    <span class="server-time">{{ server_time }}</span>
  </header>
  <main>
    {% block content %}{% endblock %}
  </main>
</body>
</html>
```

- [ ] **Step 3: Write `dashboard/static/style.css`**

```css
/* dashboard/static/style.css */
*, *::before, *::after { box-sizing: border-box; }

body {
  font-family: system-ui, -apple-system, sans-serif;
  background: #0d1117;
  color: #e6edf3;
  margin: 0;
  padding: 0;
}

header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1rem 2rem;
  border-bottom: 1px solid #30363d;
  background: #161b22;
}
header h1 { margin: 0; font-size: 1.4rem; }
.server-time { color: #8b949e; font-size: 0.85rem; }

main {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1.5rem;
  padding: 1.5rem 2rem;
  max-width: 1400px;
  margin: 0 auto;
}

.card {
  background: #161b22;
  border: 1px solid #30363d;
  border-radius: 8px;
  padding: 1.25rem;
}
.card h2 {
  margin: 0 0 1rem;
  font-size: 0.875rem;
  color: #8b949e;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

/* Spend */
.spend-value { font-size: 2.5rem; font-weight: 700; color: #3fb950; }
.spend-label { color: #8b949e; font-size: 0.875rem; margin-top: 0.25rem; }

/* Leaderboard */
table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
th {
  text-align: left;
  color: #8b949e;
  padding: 0.375rem 0.5rem 0.375rem 0;
  border-bottom: 1px solid #30363d;
  font-weight: 500;
}
td { padding: 0.375rem 0.5rem 0.375rem 0; border-bottom: 1px solid #21262d; }
td.cost { color: #3fb950; font-family: monospace; }
td.model-name { font-family: monospace; font-size: 0.75rem; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

/* Activity feed */
.activity-feed { grid-column: 1 / -1; }
.activity-scroll { max-height: 260px; overflow-y: auto; }

.activity-row {
  display: grid;
  grid-template-columns: 160px 80px 1fr 80px;
  gap: 0.5rem;
  padding: 0.3rem 0;
  border-bottom: 1px solid #21262d;
  font-size: 0.75rem;
  font-family: monospace;
}
.activity-row .ts    { color: #8b949e; }
.activity-row .src   { color: #58a6ff; }
.activity-row .cmd   { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.activity-row .ok    { color: #3fb950; text-align: right; }
.activity-row .err   { color: #f85149; text-align: right; }

/* Controls */
.controls { display: flex; gap: 0.75rem; flex-wrap: wrap; }
button {
  padding: 0.5rem 1rem;
  border: 1px solid #30363d;
  border-radius: 6px;
  background: #21262d;
  color: #e6edf3;
  cursor: pointer;
  font-size: 0.875rem;
  transition: background 0.15s;
}
button:hover { background: #30363d; }
button.danger { border-color: #f85149; color: #f85149; }
button.danger:hover { background: #f851491a; }

/* Chart */
.chart-wrap { position: relative; height: 200px; }

/* Empty state */
.empty { color: #8b949e; font-size: 0.8rem; font-style: italic; margin: 0.5rem 0; }
```

- [ ] **Step 4: Commit**

```powershell
git add dashboard/templates/base.html dashboard/static/style.css
git commit -m "feat(dashboard): base template + dark-mode CSS"
```

---

### Task 7: Dashboard Page + Partials

**Files:**
- Create: `dashboard/templates/index.html`
- Create: `dashboard/templates/partials/spend_today.html`
- Create: `dashboard/templates/partials/leaderboard.html`
- Create: `dashboard/templates/partials/activity_rows.html`

**Template context reminder** (from API Contract):
- `stats.today_cost_usd` — float
- `stats.total_otel_calls` — int
- `stats.models` — list with `.name`, `.calls`, `.cost_usd`, `.tokens_in`, `.tokens_out`
- `stats.recent_hooks` — list with `.timestamp` (datetime), `.target` (str), `.duration_s` (int), `.exit_code` (int)
- `stats.ollama_models` — list with `.name`, `.status`, `.size`
- `server_time` — str (only in index context, not partials)

- [ ] **Step 1: Write `dashboard/templates/index.html`**

```html
{% extends "base.html" %}
{% block content %}

<!-- Spend Today — polls every 30s -->
<div class="card"
     hx-get="/partials/spend"
     hx-trigger="every 30s"
     hx-swap="innerHTML">
  {% include "partials/spend_today.html" %}
</div>

<!-- Model Leaderboard — polls every 30s -->
<div class="card"
     hx-get="/partials/leaderboard"
     hx-trigger="every 30s"
     hx-swap="innerHTML">
  {% include "partials/leaderboard.html" %}
</div>

<!-- Cost Doughnut Chart -->
<div class="card">
  <h2>Cost Breakdown</h2>
  <div class="chart-wrap">
    <canvas id="costChart"></canvas>
  </div>
</div>

<!-- Ollama Controls -->
<div class="card">
  <h2>Controls</h2>
  <div class="controls">
    <button class="danger"
            hx-post="/controls/ollama/stop-all"
            hx-confirm="Stop all running Ollama models?"
            hx-swap="none">
      ⛔ Stop All Ollama
    </button>
  </div>
  {% if stats.ollama_models %}
  <p style="margin: 0.75rem 0 0.25rem; color:#8b949e; font-size:0.8rem">Running:</p>
  <ul style="margin:0; padding-left:1.25rem; font-family:monospace; font-size:0.8rem">
    {% for m in stats.ollama_models %}
    <li>{{ m.name }} — {{ m.size }}</li>
    {% endfor %}
  </ul>
  {% endif %}
</div>

<!-- Live Activity — polls every 5s -->
<div class="card activity-feed"
     hx-get="/partials/activity"
     hx-trigger="every 5s"
     hx-swap="innerHTML">
  {% include "partials/activity_rows.html" %}
</div>

<!-- Inject chart data for app.js -->
<script>
  const chartLabels = {{ stats.models | map(attribute='name') | list | tojson }};
  const chartData   = {{ stats.models | map(attribute='cost_usd') | list | tojson }};
</script>
<script src="/static/app.js"></script>
{% endblock %}
```

- [ ] **Step 2: Write `dashboard/templates/partials/spend_today.html`**

```html
<h2>Today's Spend</h2>
<div class="spend-value">${{ "%.4f" | format(stats.today_cost_usd) }}</div>
<div class="spend-label">{{ stats.total_otel_calls }} API calls recorded (all time)</div>
```

- [ ] **Step 3: Write `dashboard/templates/partials/leaderboard.html`**

```html
<h2>Model Leaderboard</h2>
{% if stats.models %}
<table>
  <thead>
    <tr>
      <th>Model</th>
      <th>Calls</th>
      <th>Cost</th>
      <th>Tokens In</th>
      <th>Tokens Out</th>
    </tr>
  </thead>
  <tbody>
    {% for m in stats.models %}
    <tr>
      <td class="model-name" title="{{ m.name }}">{{ m.name }}</td>
      <td>{{ m.calls }}</td>
      <td class="cost">${{ "%.4f" | format(m.cost_usd) }}</td>
      <td>{{ m.tokens_in }}</td>
      <td>{{ m.tokens_out }}</td>
    </tr>
    {% endfor %}
  </tbody>
</table>
{% else %}
<p class="empty">No OTel events yet. Run <code>scripts\parse-otel.ps1</code> to populate.</p>
{% endif %}
```

- [ ] **Step 4: Write `dashboard/templates/partials/activity_rows.html`**

```html
<h2>Live Activity</h2>
{% if stats.recent_hooks %}
<div class="activity-scroll">
  {% for h in stats.recent_hooks | reverse %}
  <div class="activity-row">
    <span class="ts">{{ h.timestamp.strftime('%m-%d %H:%M:%S') }}</span>
    <span class="src">hook</span>
    <span class="cmd" title="{{ h.target }}">{{ h.target }}</span>
    <span class="{{ 'ok' if h.exit_code == 0 else 'err' }}">
      {{ h.duration_s }}s / {{ h.exit_code }}
    </span>
  </div>
  {% endfor %}
</div>
{% else %}
<p class="empty">No hook events yet. Run an Ollama, Codex, or Gemini command inside Claude.</p>
{% endif %}
```

- [ ] **Step 5: Commit**

```powershell
git add dashboard/templates/
git commit -m "feat(dashboard): index template + all partials"
```

---

### Task 8: Chart.js Integration

**Files:**
- Create: `dashboard/static/app.js`

`chartLabels` and `chartData` are global JS arrays injected by `index.html` (see Task 7 Step 1).

- [ ] **Step 1: Write `dashboard/static/app.js`**

```javascript
// dashboard/static/app.js
(function () {
  'use strict';

  const canvas = document.getElementById('costChart');
  if (!canvas) return;

  const PALETTE = [
    '#3fb950', '#58a6ff', '#f0883e', '#bc8cff',
    '#ff7b72', '#79c0ff', '#ffa657', '#d2a8ff',
  ];

  new Chart(canvas, {
    type: 'doughnut',
    data: {
      labels: typeof chartLabels !== 'undefined' ? chartLabels : [],
      datasets: [{
        data: typeof chartData !== 'undefined' ? chartData : [],
        backgroundColor: PALETTE,
        borderColor: '#161b22',
        borderWidth: 2,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          position: 'right',
          labels: {
            color: '#e6edf3',
            font: { size: 11 },
            padding: 12,
            boxWidth: 12,
          },
        },
        tooltip: {
          callbacks: {
            label: (ctx) => ` ${ctx.label}: $${ctx.parsed.toFixed(4)}`,
          },
        },
      },
    },
  });
}());
```

- [ ] **Step 2: Commit**

```powershell
git add dashboard/static/app.js
git commit -m "feat(dashboard): Chart.js model-cost doughnut"
```

---

## INTEGRATION — Main Branch (Claude)
*Run after both worktrees are complete.*

### Task 9: Merge Worktrees

- [ ] **Step 1: Merge backend branch**

```powershell
git checkout master
git merge plan2/backend --no-ff -m "feat(dashboard): backend — readers, models, API routes, Ollama controls"
```

- [ ] **Step 2: Merge frontend branch**

```powershell
git merge plan2/frontend --no-ff -m "feat(dashboard): frontend — templates, Chart.js, dark-mode CSS"
```

Resolve conflicts if any. The two worktrees touch entirely different directories (`dashboard/readers/`, `dashboard/models/`, `dashboard/routers/`, `dashboard/tests/` vs `dashboard/templates/`, `dashboard/static/`) — conflicts are not expected.

- [ ] **Step 3: Clean up worktrees**

```powershell
git worktree remove .worktrees/plan2-backend
git worktree remove .worktrees/plan2-frontend
git worktree prune
git branch -d plan2/backend plan2/frontend
```

---

### Task 10: App Shell

**Files:**
- Create: `dashboard/main.py`

- [ ] **Step 1: Write `dashboard/main.py`**

```python
# dashboard/main.py
from __future__ import annotations
import os
from pathlib import Path
from datetime import datetime

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from dashboard.readers.stats import compute_stats
from dashboard.routers.api import router as api_router
from dashboard.routers.controls import router as controls_router

JOURNAL_PATH = Path(
    os.environ.get('ROUTING_JOURNAL', '')
    or Path.home() / '.claude' / 'model-routing-log.md'
)

_HERE = Path(__file__).parent

app = FastAPI(title="Routing Dashboard", version="2.0.0")
app.state.journal_path = JOURNAL_PATH

app.mount("/static", StaticFiles(directory=_HERE / "static"), name="static")
templates = Jinja2Templates(directory=str(_HERE / "templates"))

app.include_router(api_router)
app.include_router(controls_router)


def _ctx(request: Request) -> dict:
    stats = compute_stats(JOURNAL_PATH)
    return {
        "request": request,
        "stats": stats,
        "server_time": datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %z'),
    }


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse("index.html", _ctx(request))


@app.get("/partials/spend", response_class=HTMLResponse)
async def partial_spend(request: Request) -> HTMLResponse:
    return templates.TemplateResponse("partials/spend_today.html", _ctx(request))


@app.get("/partials/leaderboard", response_class=HTMLResponse)
async def partial_leaderboard(request: Request) -> HTMLResponse:
    return templates.TemplateResponse("partials/leaderboard.html", _ctx(request))


@app.get("/partials/activity", response_class=HTMLResponse)
async def partial_activity(request: Request) -> HTMLResponse:
    return templates.TemplateResponse("partials/activity_rows.html", _ctx(request))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("dashboard.main:app", host="127.0.0.1", port=8765, reload=True)
```

- [ ] **Step 2: Run all tests**

```powershell
cd D:\Dev\coding-agent-orchestrator
python -m pytest dashboard/tests/ -v
```

Expected: All tests pass.

- [ ] **Step 3: Smoke test**

```powershell
python -m uvicorn dashboard.main:app --host 127.0.0.1 --port 8765 --reload
```

Open http://127.0.0.1:8765 — dashboard should load with leaderboard, spend panel, activity feed, and cost chart.

- [ ] **Step 4: Commit**

```powershell
git add dashboard/main.py
git commit -m "feat(dashboard): app shell, partial routes, Jinja2 wiring"
```

---

### Task 11: Integration Tests

**Files:**
- Create: `dashboard/tests/test_integration.py`

- [ ] **Step 1: Write `dashboard/tests/test_integration.py`**

```python
# dashboard/tests/test_integration.py
import pytest
from pathlib import Path
from fastapi.testclient import TestClient
import dashboard.main as main_module
from dashboard.main import app


@pytest.fixture
def client(journal_file: Path, monkeypatch):
    monkeypatch.setattr(main_module, "JOURNAL_PATH", journal_file)
    app.state.journal_path = journal_file
    return TestClient(app)


def test_index_html(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "Routing Dashboard" in resp.text


def test_index_shows_model(client):
    resp = client.get("/")
    assert "claude-sonnet-4-6" in resp.text


def test_partial_spend(client):
    resp = client.get("/partials/spend")
    assert resp.status_code == 200
    assert "Spend" in resp.text


def test_partial_leaderboard(client):
    resp = client.get("/partials/leaderboard")
    assert resp.status_code == 200
    assert "Model" in resp.text


def test_partial_activity(client):
    resp = client.get("/partials/activity")
    assert resp.status_code == 200
    assert "Activity" in resp.text


def test_api_stats_json(client):
    data = client.get("/api/stats").json()
    assert data["total_otel_calls"] == 2
    assert len(data["models"]) == 2
    assert data["models"][0]["name"] == "claude-sonnet-4-6"   # highest cost first
```

- [ ] **Step 2: Run integration tests**

```powershell
python -m pytest dashboard/tests/test_integration.py -v
```

Expected: `6 passed`

- [ ] **Step 3: Run full suite**

```powershell
python -m pytest dashboard/tests/ -v --tb=short
```

Expected: All passed.

- [ ] **Step 4: Commit**

```powershell
git add dashboard/tests/test_integration.py
git commit -m "test(dashboard): integration tests for all routes"
```

---

### Task 12: README + Push

**Files:**
- Create: `dashboard/README.md`

- [ ] **Step 1: Write `dashboard/README.md`**

```markdown
# Routing Dashboard (Plan 2)

FastAPI + htmx live dashboard at `http://localhost:8765`.

## Quick Start

```powershell
pip install -r dashboard/requirements.txt
python -m uvicorn dashboard.main:app --host 127.0.0.1 --port 8765 --reload
```

## Data Source

Reads `~/.claude/model-routing-log.md` — the journal written by Plan 1 hooks and `parse-otel.ps1`.

Override: `$env:ROUTING_JOURNAL = "C:\path\to\custom-log.md"`

## Panels

| Panel | Poll | Data |
|---|---|---|
| Today's Spend | 30 s | OTel cost sum for today |
| Model Leaderboard | 30 s | All-time per-model cost + tokens |
| Live Activity | 5 s | Last 20 hook dispatch events (newest first) |
| Cost Chart | page load | Model cost doughnut (Chart.js) |

## Tests

```powershell
python -m pytest dashboard/tests/ -v
```

## Controls

**Stop All Ollama** — calls `ollama ps` then `ollama stop <model>` for each running model.
```

- [ ] **Step 2: Run full suite one final time**

```powershell
python -m pytest dashboard/tests/ -v --tb=short
```

Expected: All PASSED.

- [ ] **Step 3: Commit + push**

```powershell
git add dashboard/README.md
git commit -m "docs(dashboard): Plan 2 README"
git push origin master
```

---

*End of Plan 2.*
