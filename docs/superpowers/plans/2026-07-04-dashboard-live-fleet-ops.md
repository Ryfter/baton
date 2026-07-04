# Dashboard — Live Fleet Ops + Model Leaderboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two new read-only dashboard pages — `/fleet` (Live Fleet Ops: worker governor states, recent conductor runs, prompt-pool one-liner) and `/fleet/leaderboard` (per-worker effective-cost board with learned-routing explainability) — fed by the PS CLI `--json` surfaces via a TTL-cached subprocess reader.

**Architecture:** Extend the existing FastAPI dashboard (`dashboard/`). Two new readers: `pscli.py` (subprocess → PS CLI JSON, 15 s TTL cache, typed fail-open results) and `fleet_runs.py` (direct scan of `$BATON_HOME/runs/go-*/` artifacts). One new router (`routers/fleet.py`, build_router pattern), new Jinja2 templates + a new `static/fleet.css`. One small PS addition: a `learned` subcommand on `fleet-effective-cost.ps1` exposing `Get-LearnedCostAdjustment` as JSON (so Python never re-implements a fold). Slice 1 = Tasks 1–3 (Live Fleet Ops), Slice 2 = Tasks 4–5 (leaderboard), Task 6 = docs/version/sweep.

**Tech Stack:** Python 3.12 / FastAPI / Jinja2 / pydantic / pytest (existing dashboard stack); htmx (already vendored); PowerShell 7 for the one CLI addition.

## Global Constraints

- **The existing 124-test dashboard pytest suite must stay green.** Run `python -m pytest dashboard/tests -q` after every task that touches `dashboard/`.
- **No fold re-implementation in Python.** Worker-state folding, forecast, leaderboard confidence gating, and learned adjustments come ONLY from the PS CLIs' JSON output. Python may read run *artifact files* (plain JSON under `$BATON_HOME/runs/go-*/`) directly.
- **Per-panel fail-open:** a failing pwsh subprocess or malformed file degrades that one panel to an "unavailable"/"no data yet" block — never a 500, never an unhandled exception in a route.
- **No real pwsh in tests.** Every router/reader test monkeypatches `dashboard.readers.pscli.run_ps_json` (or `pscli._invoke`); `fleet_runs` tests use `tmp_path` fixture dirs.
- **Read-only.** No new POST/PUT/DELETE endpoints; no writes to `$BATON_HOME`.
- **Do not modify `dashboard/static/style.css`** (Kevin's design file). All new styling goes in the NEW `dashboard/static/fleet.css`.
- **Subprocess argument lists are fixed literals** — never interpolate request input into the command line. PS switch syntax is `-Json` / `-Pool` (PowerShell binding), not `--json`.
- **Known PS serialization traps to code around (do not "fix" the PS side in slice 1):** `fleet-usage.ps1 forecast -Json` pipes into `ConvertTo-Json`, so a 1-worker fleet yields a bare JSON *object*, not a 1-element array — the Python reader must wrap `dict → [dict]`. `fleet-effective-cost.ps1 report -Json` uses `-InputObject @(...)` and is always a real array.
- **Prompt-pool honesty:** `fleet-optimize-prompt.ps1 -Pool -Json` emits the RAW pool object (no verdict fold). The pool panel shows raw facts (champion, challenger, gated-run counts, shadow on/off) and points at `/baton:optimize-prompt --pool` for the dollars verdict. Do NOT compute promote/retire/stalemate in Python.
- **Windows/UTF-8:** subprocess reads with `encoding="utf-8", errors="replace"`; all new files written UTF-8.
- Plugin version bump `1.8.0 → 1.9.0-rc.1` happens ONCE, in Task 6. (The spec's per-slice-RC language is resolved in favor of the execution directive: single bump at the end; if Kevin ships slice 1 alone, move the Task 6 bump commit to the slice-1 boundary.)

## Grounded data shapes (verified against the code — parse EXACTLY these fields)

- `fleet-usage.ps1 status -Json` → `{"conserve_mode": bool, "workers": [{"worker","state","reset_at","eta_human","reason"}]}`; `state ∈ available|limited|exhausted|cooling_down|waiting_for_reset` (`scripts/fleet-usage.ps1:54-66`, `usage-lib.ps1:89-134`).
- `fleet-usage.ps1 forecast -Json` → array (or bare object when 1 worker) of `{"worker","unit","days_with_data","run_rate","status"}` plus, when status is `ok`: `budget`, `days_to_exhaustion` (`usage-lib.ps1:220+`).
- `fleet-effective-cost.ps1 report -Json` → array of `{"worker","n_runs","eff_cost_mean","single_producer_runs","confidence"}`, sorted cheapest-first (`effective-cost-lib.ps1:196-206`).
- `fleet-optimize-prompt.ps1 -Pool -Json` → raw pool `{"schema":1,"champion":"p001","candidates":[{"id","status","live":{"accept","polish","reject","realized_cost_usd",...},"promote_recommended_at",...}], "shadow": <'off' only when kill-switched; absent = on>}` — exits 2 when no pool exists (honest-absent; the panel shows "no prompt pool yet").
- Run artifacts under `$BATON_HOME/runs/go-*/` (same root as `app.state.runs_root`; the OLD runs reader keys on `run.json`, which go-* dirs never contain, so the two readers cannot collide):
  - `plan.json` `{"run_id","goal","budget_cap","tasks":[{"id","desc","command","capability","est_cost_tier",...}]}`
  - `report.md` — line 4 is literally `**Status:** <status>` (`conductor-lib.ps1:183`)
  - `acceptance.json` — gate dict; strip needs only `verdict` (`accept|polish|reject`)
  - `effective-cost.json` `{"run_id","verdict","quality","cost","cost_basis","attempts","effective_cost","workers":[{"worker","share"}],"single_producer"}` (`effective-cost-lib.ps1:105-115`)
  - `shadow.json` `{"variant_id","role","challenger_id","assigned"}` (`conductor-lib.ps1:347-350`)
  - `events.jsonl` lines `{"ts","level","task_id","kind","message"}` (`conductor-lib.ps1:121-127`)
  - `decisions.jsonl` lines `{"ts","task_id","chose","alternatives","why","cost_tier"}` (`conductor-lib.ps1:140-147`)

---

## SLICE 1 — Live Fleet Ops

### Task 1: `pscli` subprocess reader

**Files:**
- Create: `dashboard/readers/pscli.py`
- Test: `dashboard/tests/test_pscli.py`

**Interfaces:**
- Produces: `PsResult` dataclass (`ok: bool, data: Any, error: Optional[str]`); `run_ps_json(script: str, args: Sequence[str], ttl: float = 15.0, timeout: float = 20.0, now=time.monotonic) -> PsResult`; `clear_cache() -> None`; module-private `_invoke(script, args, timeout) -> PsResult` (the monkeypatch seam). Tasks 3 and 5 consume `run_ps_json`.

- [ ] **Step 1: Write the failing tests**

Create `dashboard/tests/test_pscli.py`:

```python
from __future__ import annotations

import subprocess

import dashboard.readers.pscli as pscli


def setup_function() -> None:
    pscli.clear_cache()


def test_cache_ttl_honored(monkeypatch):
    calls: list[tuple] = []

    def fake_invoke(script, args, timeout):
        calls.append((script, args))
        return pscli.PsResult(ok=True, data={"n": len(calls)})

    monkeypatch.setattr(pscli, "_invoke", fake_invoke)
    clock = [100.0]
    now = lambda: clock[0]  # noqa: E731

    r1 = pscli.run_ps_json("fleet-usage.ps1", ("status", "-Json"), ttl=15.0, now=now)
    r2 = pscli.run_ps_json("fleet-usage.ps1", ("status", "-Json"), ttl=15.0, now=now)
    assert r1.data == {"n": 1}
    assert r2.data == {"n": 1}          # served from cache, no second invoke
    assert len(calls) == 1

    clock[0] += 15.1                     # TTL expired
    r3 = pscli.run_ps_json("fleet-usage.ps1", ("status", "-Json"), ttl=15.0, now=now)
    assert r3.data == {"n": 2}
    assert len(calls) == 2


def test_distinct_args_are_distinct_cache_entries(monkeypatch):
    calls: list[tuple] = []

    def fake_invoke(script, args, timeout):
        calls.append((script, args))
        return pscli.PsResult(ok=True, data=list(args))

    monkeypatch.setattr(pscli, "_invoke", fake_invoke)
    a = pscli.run_ps_json("fleet-usage.ps1", ("status", "-Json"))
    b = pscli.run_ps_json("fleet-usage.ps1", ("forecast", "-Json"))
    assert a.data == ["status", "-Json"]
    assert b.data == ["forecast", "-Json"]
    assert len(calls) == 2


def test_error_results_are_cached_too(monkeypatch):
    calls: list[int] = []

    def fake_invoke(script, args, timeout):
        calls.append(1)
        return pscli.PsResult(ok=False, error="exit 2: boom")

    monkeypatch.setattr(pscli, "_invoke", fake_invoke)
    clock = [50.0]
    now = lambda: clock[0]  # noqa: E731
    r1 = pscli.run_ps_json("fleet-usage.ps1", ("status", "-Json"), ttl=15.0, now=now)
    r2 = pscli.run_ps_json("fleet-usage.ps1", ("status", "-Json"), ttl=15.0, now=now)
    assert not r1.ok and not r2.ok
    assert len(calls) == 1               # a broken CLI is not hammered every request


def test_invoke_missing_script_is_error():
    r = pscli._invoke("no-such-script-xyz.ps1", (), timeout=1.0)
    assert not r.ok
    assert "not found" in r.error


def test_invoke_nonzero_exit_is_error(monkeypatch):
    class P:
        returncode = 2
        stdout = ""
        stderr = "no pool manifest"

    monkeypatch.setattr(pscli.subprocess, "run", lambda *a, **k: P())
    r = pscli._invoke("fleet-usage.ps1", ("status", "-Json"), timeout=1.0)
    assert not r.ok
    assert "exit 2" in r.error
    assert "no pool manifest" in r.error


def test_invoke_bad_json_is_error(monkeypatch):
    class P:
        returncode = 0
        stdout = "conserve_mode: False"    # text-mode output, not JSON
        stderr = ""

    monkeypatch.setattr(pscli.subprocess, "run", lambda *a, **k: P())
    r = pscli._invoke("fleet-usage.ps1", ("status", "-Json"), timeout=1.0)
    assert not r.ok
    assert "bad JSON" in r.error


def test_invoke_timeout_is_error(monkeypatch):
    def boom(*a, **k):
        raise subprocess.TimeoutExpired(cmd="pwsh", timeout=1.0)

    monkeypatch.setattr(pscli.subprocess, "run", boom)
    r = pscli._invoke("fleet-usage.ps1", ("status", "-Json"), timeout=1.0)
    assert not r.ok
    assert "TimeoutExpired" in r.error
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest dashboard/tests/test_pscli.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'dashboard.readers.pscli'`

- [ ] **Step 3: Write the implementation**

Create `dashboard/readers/pscli.py`:

```python
"""Run a Baton PS CLI with a JSON flag and return parsed output.

The PS CLIs are the single source of truth for fold semantics (usage-journal
fold, leaderboard confidence gating) — this module never re-implements them.
Results are TTL-cached (default 15 s) to amortize pwsh startup; error results
are cached too so a broken CLI is not hammered on every page render.
"""
from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Optional, Sequence

# dashboard/readers/pscli.py -> repo root -> scripts/
SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent / "scripts"
DEFAULT_TTL = 15.0
DEFAULT_TIMEOUT = 20.0


@dataclass
class PsResult:
    ok: bool
    data: Any = None
    error: Optional[str] = None


_cache: dict[tuple, tuple[float, PsResult]] = {}


def clear_cache() -> None:
    _cache.clear()


def _invoke(script: str, args: tuple[str, ...], timeout: float) -> PsResult:
    script_path = SCRIPTS_DIR / script
    if not script_path.exists():
        return PsResult(ok=False, error=f"script not found: {script_path}")
    # Fixed argument list — request input is never interpolated into the command.
    cmd = ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(script_path), *args]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            encoding="utf-8", errors="replace",
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return PsResult(ok=False, error=f"{type(exc).__name__}: {exc}")
    if proc.returncode != 0:
        snippet = (proc.stderr or proc.stdout or "").strip()[:400]
        return PsResult(ok=False, error=f"exit {proc.returncode}: {snippet}")
    try:
        return PsResult(ok=True, data=json.loads(proc.stdout))
    except json.JSONDecodeError as exc:
        return PsResult(ok=False, error=f"bad JSON from {script}: {exc}")


def run_ps_json(
    script: str,
    args: Sequence[str],
    ttl: float = DEFAULT_TTL,
    timeout: float = DEFAULT_TIMEOUT,
    now: Callable[[], float] = time.monotonic,
) -> PsResult:
    key = (script, tuple(args))
    t = now()
    hit = _cache.get(key)
    if hit is not None and (t - hit[0]) < ttl:
        return hit[1]
    result = _invoke(script, tuple(args), timeout)
    _cache[key] = (t, result)
    return result
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest dashboard/tests/test_pscli.py -q`
Expected: `7 passed`

- [ ] **Step 5: Run the whole dashboard suite (regression)**

Run: `python -m pytest dashboard/tests -q`
Expected: all pass (124 existing + 7 new)

- [ ] **Step 6: Commit**

```bash
git add dashboard/readers/pscli.py dashboard/tests/test_pscli.py
git commit -m "feat(dashboard): pscli subprocess reader with TTL cache and typed fail-open results"
```

### Task 2: go-run artifacts reader + models

**Files:**
- Create: `dashboard/models/fleet.py`
- Create: `dashboard/readers/fleet_runs.py`
- Test: `dashboard/tests/test_fleet_runs_reader.py`

**Interfaces:**
- Consumes: nothing from Task 1 (pure file reads).
- Produces: pydantic models `GoRunRow`, `GoRunEvent`, `GoRunDecision`, `GoRunDetail`; `list_go_runs(runs_root: Path, limit: int = 10) -> list[GoRunRow]` (newest-first); `read_go_run_detail(runs_root: Path, run_id: str) -> GoRunDetail` (raises `FileNotFoundError` on bad/missing id). Task 3 consumes all of these.

- [ ] **Step 1: Write the failing tests**

Create `dashboard/tests/test_fleet_runs_reader.py`:

```python
from __future__ import annotations

import json
from pathlib import Path

import pytest

from dashboard.readers.fleet_runs import list_go_runs, read_go_run_detail


@pytest.fixture
def go_runs_root(tmp_path: Path) -> Path:
    root = tmp_path / "runs"
    root.mkdir()

    # Full run: gated, shadowed, complete artifacts.
    r1 = root / "go-2026-07-01T10-00-00"
    r1.mkdir()
    (r1 / "plan.json").write_text(json.dumps({
        "run_id": "go-2026-07-01T10-00-00",
        "goal": "add retry logic to the fetcher",
        "budget_cap": None,
        "tasks": [
            {"id": "t1", "desc": "write test", "command": "codex", "est_cost_tier": "free"},
            {"id": "t2", "desc": "implement", "command": "codex", "est_cost_tier": "free"},
        ],
    }), encoding="utf-8")
    (r1 / "report.md").write_text(
        "# Conductor run — go-2026-07-01T10-00-00\n\n"
        "**Goal:** add retry logic to the fetcher\n"
        "**Status:** completed\n"
        "**Spend:** 0.10\n",
        encoding="utf-8",
    )
    (r1 / "acceptance.json").write_text(json.dumps({
        "verdict": "polish", "counts": {"critical": 0, "important": 1, "minor": 2},
    }), encoding="utf-8")
    (r1 / "effective-cost.json").write_text(json.dumps({
        "run_id": "go-2026-07-01T10-00-00", "verdict": "polish", "quality": 0.65,
        "cost": 0.10, "cost_basis": "measured", "attempts": 1,
        "effective_cost": 0.1538,
        "workers": [{"worker": "codex", "share": 1.0}], "single_producer": True,
    }), encoding="utf-8")
    (r1 / "shadow.json").write_text(json.dumps({
        "variant_id": "p002", "role": "challenger",
        "challenger_id": "p002", "assigned": "2026-07-01T10:00:01Z",
    }), encoding="utf-8")
    (r1 / "events.jsonl").write_text(
        '{"ts":"2026-07-01T10:00:00Z","level":"info","task_id":"","kind":"started","message":"plan: 2 tasks"}\n'
        '{"ts":"2026-07-01T10:05:00Z","level":"info","task_id":"t1","kind":"task","message":"t1 done"}\n'
        "not json at all\n",
        encoding="utf-8",
    )
    (r1 / "decisions.jsonl").write_text(
        '{"ts":"2026-07-01T10:01:00Z","task_id":"t1","chose":"codex","alternatives":["claude-haiku"],"why":"cheapest capable","cost_tier":"free"}\n',
        encoding="utf-8",
    )

    # Gate-less run: no acceptance/effective-cost/shadow.
    r2 = root / "go-2026-07-02T11-00-00"
    r2.mkdir()
    (r2 / "plan.json").write_text(json.dumps({
        "run_id": "go-2026-07-02T11-00-00", "goal": "ungated quick fix", "tasks": [],
    }), encoding="utf-8")
    (r2 / "report.md").write_text("# Conductor run\n\n**Goal:** ungated quick fix\n**Status:** completed\n", encoding="utf-8")

    # In-flight/broken run: no report.md, corrupt effective-cost.json.
    r3 = root / "go-2026-07-03T12-00-00"
    r3.mkdir()
    (r3 / "plan.json").write_text(json.dumps({
        "run_id": "go-2026-07-03T12-00-00", "goal": "still running", "tasks": [],
    }), encoding="utf-8")
    (r3 / "effective-cost.json").write_text("{ not json", encoding="utf-8")

    # A NON-conductor run dir (the other dashboard's schema) must be excluded.
    other = root / "run_auth-rewrite"
    other.mkdir()
    (other / "run.json").write_text("{}", encoding="utf-8")

    return root


def test_list_newest_first_and_go_only(go_runs_root: Path):
    rows = list_go_runs(go_runs_root)
    assert [r.run_id for r in rows] == [
        "go-2026-07-03T12-00-00",
        "go-2026-07-02T11-00-00",
        "go-2026-07-01T10-00-00",
    ]


def test_full_run_row_fields(go_runs_root: Path):
    rows = {r.run_id: r for r in list_go_runs(go_runs_root)}
    r = rows["go-2026-07-01T10-00-00"]
    assert r.goal == "add retry logic to the fetcher"
    assert r.status == "completed"
    assert r.verdict == "polish"
    assert r.cost == 0.10
    assert r.cost_basis == "measured"
    assert r.effective_cost == 0.1538
    assert r.shadow_role == "challenger"
    assert r.shadow_variant == "p002"
    assert r.task_count == 2
    assert r.has_report is True


def test_gateless_run_has_no_verdict_or_cost(go_runs_root: Path):
    rows = {r.run_id: r for r in list_go_runs(go_runs_root)}
    r = rows["go-2026-07-02T11-00-00"]
    assert r.verdict is None
    assert r.cost is None
    assert r.effective_cost is None
    assert r.status == "completed"


def test_corrupt_artifact_degrades_not_crashes(go_runs_root: Path):
    rows = {r.run_id: r for r in list_go_runs(go_runs_root)}
    r = rows["go-2026-07-03T12-00-00"]
    assert r.status == "in-flight"        # no report.md yet
    assert r.effective_cost is None       # corrupt JSON skipped
    assert r.goal == "still running"


def test_limit_respected(go_runs_root: Path):
    assert len(list_go_runs(go_runs_root, limit=2)) == 2


def test_missing_root_is_empty(tmp_path: Path):
    assert list_go_runs(tmp_path / "nope") == []


def test_detail_reads_report_events_decisions(go_runs_root: Path):
    d = read_go_run_detail(go_runs_root, "go-2026-07-01T10-00-00")
    assert "**Status:** completed" in d.report_md
    assert len(d.events) == 2             # malformed third line skipped
    assert d.events[1].task_id == "t1"
    assert len(d.decisions) == 1
    assert d.decisions[0].chose == "codex"
    assert d.row.verdict == "polish"


def test_detail_missing_run_raises(go_runs_root: Path):
    with pytest.raises(FileNotFoundError):
        read_go_run_detail(go_runs_root, "go-1999-01-01T00-00-00")


@pytest.mark.parametrize("bad_id", ["", "..", "a/../b", "go-x/../../etc", "C:\\Windows", "/etc/passwd", "run_auth-rewrite"])
def test_detail_rejects_traversal_and_non_go_ids(go_runs_root: Path, bad_id: str):
    with pytest.raises(FileNotFoundError):
        read_go_run_detail(go_runs_root, bad_id)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest dashboard/tests/test_fleet_runs_reader.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'dashboard.readers.fleet_runs'`

- [ ] **Step 3: Write the models**

Create `dashboard/models/fleet.py`:

```python
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel


class GoRunRow(BaseModel):
    run_id: str
    goal: str = ""
    status: str = "unknown"              # parsed from report.md; 'in-flight' when absent
    verdict: Optional[str] = None        # accept | polish | reject
    cost: Optional[float] = None
    cost_basis: Optional[str] = None     # estimate | measured
    effective_cost: Optional[float] = None
    shadow_role: Optional[str] = None    # champion | challenger
    shadow_variant: Optional[str] = None
    task_count: int = 0
    has_report: bool = False


class GoRunEvent(BaseModel):
    ts: str = ""
    level: str = "info"
    task_id: str = ""
    kind: str = ""
    message: str = ""


class GoRunDecision(BaseModel):
    ts: str = ""
    task_id: str = ""
    chose: str = ""
    alternatives: list[str] = []
    why: str = ""
    cost_tier: str = ""


class GoRunDetail(BaseModel):
    row: GoRunRow
    report_md: str = ""
    events: list[GoRunEvent] = []
    decisions: list[GoRunDecision] = []
```

- [ ] **Step 4: Write the reader**

Create `dashboard/readers/fleet_runs.py`:

```python
"""Scan $BATON_HOME/runs/go-*/ conductor-run artifacts (plain data files —
folds stay in the PS CLIs; see readers/pscli.py). Every artifact read is
individually fail-open: a corrupt file degrades to missing fields, never an
exception out of list_go_runs."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Optional

from dashboard.models.fleet import GoRunRow, GoRunEvent, GoRunDecision, GoRunDetail

_STATUS_RE = re.compile(r"^\*\*Status:\*\* (.+)$", re.MULTILINE)


def _validate_go_run_id(run_id: str) -> None:
    """FileNotFoundError on anything that is not a plain go-* directory name."""
    if not run_id or not run_id.startswith("go-"):
        raise FileNotFoundError(f"Invalid run_id: {run_id!r}")
    if "/" in run_id or "\\" in run_id:
        raise FileNotFoundError(f"Invalid run_id: {run_id!r}")
    if ".." in run_id.replace("\\", "/").split("/"):
        raise FileNotFoundError(f"Invalid run_id: {run_id!r}")


def _read_json(path: Path) -> Optional[Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, ValueError):
        return None


def _read_text(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def _as_float(value: Any) -> Optional[float]:
    try:
        if value is None:
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def _build_row(run_dir: Path) -> GoRunRow:
    row = GoRunRow(run_id=run_dir.name)

    plan = _read_json(run_dir / "plan.json")
    if isinstance(plan, dict):
        row.goal = str(plan.get("goal") or "")
        tasks = plan.get("tasks")
        row.task_count = len(tasks) if isinstance(tasks, list) else 0

    report = _read_text(run_dir / "report.md")
    if report is not None:
        row.has_report = True
        m = _STATUS_RE.search(report)
        row.status = m.group(1).strip() if m else "finished"
    else:
        row.status = "in-flight"

    acc = _read_json(run_dir / "acceptance.json")
    if isinstance(acc, dict) and acc.get("verdict"):
        row.verdict = str(acc["verdict"])

    eff = _read_json(run_dir / "effective-cost.json")
    if isinstance(eff, dict):
        row.cost = _as_float(eff.get("cost"))
        row.effective_cost = _as_float(eff.get("effective_cost"))
        if eff.get("cost_basis"):
            row.cost_basis = str(eff["cost_basis"])

    shadow = _read_json(run_dir / "shadow.json")
    if isinstance(shadow, dict):
        if shadow.get("role"):
            row.shadow_role = str(shadow["role"])
        if shadow.get("variant_id"):
            row.shadow_variant = str(shadow["variant_id"])

    return row


def list_go_runs(runs_root: Path, limit: int = 10) -> list[GoRunRow]:
    if not runs_root.exists():
        return []
    # Run ids embed a sortable timestamp (go-yyyy-MM-ddTHH-mm-ss):
    # lexicographic desc == newest first.
    dirs = sorted(
        (p for p in runs_root.iterdir() if p.is_dir() and p.name.startswith("go-")),
        key=lambda p: p.name,
        reverse=True,
    )
    return [_build_row(d) for d in dirs[:limit]]


def _read_jsonl(path: Path) -> list[dict]:
    text = _read_text(path)
    if text is None:
        return []
    out: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def read_go_run_detail(runs_root: Path, run_id: str) -> GoRunDetail:
    _validate_go_run_id(run_id)
    run_dir = runs_root / run_id
    if not run_dir.is_dir() or not (run_dir / "plan.json").exists():
        raise FileNotFoundError(f"No such conductor run: {run_id}")

    events: list[GoRunEvent] = []
    for obj in _read_jsonl(run_dir / "events.jsonl"):
        try:
            events.append(GoRunEvent(**obj))
        except (ValueError, TypeError):
            continue

    decisions: list[GoRunDecision] = []
    for obj in _read_jsonl(run_dir / "decisions.jsonl"):
        try:
            decisions.append(GoRunDecision(**obj))
        except (ValueError, TypeError):
            continue

    return GoRunDetail(
        row=_build_row(run_dir),
        report_md=_read_text(run_dir / "report.md") or "",
        events=events,
        decisions=decisions,
    )
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest dashboard/tests/test_fleet_runs_reader.py -q`
Expected: `14 passed` (8 named + parametrized traversal cases)

- [ ] **Step 6: Full dashboard suite (regression)**

Run: `python -m pytest dashboard/tests -q`
Expected: all pass

- [ ] **Step 7: Commit**

```bash
git add dashboard/models/fleet.py dashboard/readers/fleet_runs.py dashboard/tests/test_fleet_runs_reader.py
git commit -m "feat(dashboard): go-run artifacts reader + fleet models (fail-open per artifact)"
```

### Task 3: Live Fleet Ops page (router, templates, CSS, wiring)

**Files:**
- Create: `dashboard/routers/fleet.py`
- Create: `dashboard/templates/fleet_ops.html`
- Create: `dashboard/templates/partials/fleet_ops_body.html`
- Create: `dashboard/templates/partials/fleet_worker_board.html`
- Create: `dashboard/templates/partials/fleet_runs_strip.html`
- Create: `dashboard/templates/partials/fleet_pool_line.html`
- Create: `dashboard/templates/go_run_detail.html`
- Create: `dashboard/static/fleet.css`
- Modify: `dashboard/templates/base.html` (nav link + head block — two lines)
- Modify: `dashboard/main.py` (router include — two lines)
- Test: `dashboard/tests/test_fleet_router.py`

**Interfaces:**
- Consumes: `pscli.run_ps_json` (Task 1); `list_go_runs` / `read_go_run_detail` + models (Task 2); `app.state.runs_root` (existing).
- Produces: routes `GET /fleet`, `GET /partials/fleet-ops`, `GET /fleet/runs/{run_id}`; `build_router(templates) -> APIRouter`. Task 5 extends this same router file.

- [ ] **Step 1: Write the failing tests**

Create `dashboard/tests/test_fleet_router.py`:

```python
from __future__ import annotations

import json
from pathlib import Path

from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

import dashboard.readers.pscli as pscli
from dashboard.routers.fleet import build_router


USAGE_OK = pscli.PsResult(ok=True, data={
    "conserve_mode": False,
    "workers": [
        {"worker": "claude-haiku", "state": "available", "reset_at": None, "eta_human": None, "reason": None},
        {"worker": "github-models", "state": "waiting_for_reset", "reset_at": "2026-07-05T01:00:00Z", "eta_human": "in 2h 59m", "reason": "429"},
    ],
})
FORECAST_OK = pscli.PsResult(ok=True, data=[
    {"worker": "github-models", "unit": "requests", "days_with_data": 3,
     "run_rate": 12.0, "status": "ok", "budget": 50, "days_to_exhaustion": 3.1},
])
POOL_OK = pscli.PsResult(ok=True, data={
    "schema": 1, "champion": "p001",
    "candidates": [
        {"id": "p001", "status": "champion",
         "live": {"accept": 4, "polish": 1, "reject": 0, "realized_cost_usd": 1.2}},
        {"id": "p002", "status": "candidate",
         "live": {"accept": 2, "polish": 0, "reject": 1, "realized_cost_usd": 0.4}},
    ],
})


def fake_ps(responses: dict):
    def run(script, args, **kw):
        return responses.get((script, tuple(args)),
                             pscli.PsResult(ok=False, error="unexpected call"))
    return run


def make_app(runs_root: Path) -> FastAPI:
    app = FastAPI()
    app.state.runs_root = runs_root
    here = Path(__file__).parent.parent
    templates = Jinja2Templates(directory=str(here / "templates"))
    app.include_router(build_router(templates))
    return app


def seed_go_run(root: Path) -> None:
    d = root / "go-2026-07-01T10-00-00"
    d.mkdir(parents=True)
    (d / "plan.json").write_text(json.dumps(
        {"run_id": d.name, "goal": "add retry logic", "tasks": [{"id": "t1", "desc": "x", "command": "codex", "est_cost_tier": "free"}]},
    ), encoding="utf-8")
    (d / "report.md").write_text("# Conductor run\n\n**Goal:** add retry logic\n**Status:** completed\n", encoding="utf-8")
    (d / "acceptance.json").write_text(json.dumps({"verdict": "accept"}), encoding="utf-8")
    (d / "events.jsonl").write_text('{"ts":"2026-07-01T10:00:00Z","level":"info","task_id":"","kind":"started","message":"plan: 1 tasks"}\n', encoding="utf-8")


ALL_OK = {
    ("fleet-usage.ps1", ("status", "-Json")): USAGE_OK,
    ("fleet-usage.ps1", ("forecast", "-Json")): FORECAST_OK,
    ("fleet-optimize-prompt.ps1", ("-Pool", "-Json")): POOL_OK,
}


def test_fleet_page_renders_all_panels(tmp_path, monkeypatch):
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(ALL_OK))
    seed_go_run(tmp_path)
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet")
    assert resp.status_code == 200
    # worker board
    assert "claude-haiku" in resp.text and "available" in resp.text
    assert "waiting_for_reset" in resp.text and "in 2h 59m" in resp.text
    assert "3.1" in resp.text                       # days_to_exhaustion joined by worker
    # runs strip
    assert "add retry logic" in resp.text
    assert "accept" in resp.text
    assert 'href="/fleet/runs/go-2026-07-01T10-00-00"' in resp.text
    # pool line: raw facts + honest pointer, no verdict fold
    assert "p001" in resp.text and "p002" in resp.text
    assert "--pool" in resp.text                    # points at the CLI for the verdict


def test_conserve_banner(tmp_path, monkeypatch):
    conserve = pscli.PsResult(ok=True, data={"conserve_mode": True, "workers": []})
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps({**ALL_OK, ("fleet-usage.ps1", ("status", "-Json")): conserve}))
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet")
    assert resp.status_code == 200
    assert "CONSERVE" in resp.text


def test_panel_degrades_without_500(tmp_path, monkeypatch):
    broken = {
        ("fleet-usage.ps1", ("status", "-Json")): pscli.PsResult(ok=False, error="exit 1: pwsh exploded"),
        ("fleet-usage.ps1", ("forecast", "-Json")): pscli.PsResult(ok=False, error="exit 1"),
        ("fleet-optimize-prompt.ps1", ("-Pool", "-Json")): pscli.PsResult(ok=False, error="exit 2: no pool"),
    }
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(broken))
    seed_go_run(tmp_path)
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet")
    assert resp.status_code == 200
    assert "pwsh exploded" in resp.text             # stderr snippet surfaced
    assert "add retry logic" in resp.text           # runs strip unaffected


def test_single_worker_forecast_bare_object(tmp_path, monkeypatch):
    # fleet-usage forecast pipes to ConvertTo-Json: 1 worker => bare object, not array.
    bare = pscli.PsResult(ok=True, data={"worker": "github-models", "unit": "requests",
                                         "days_with_data": 3, "run_rate": 12.0,
                                         "status": "ok", "budget": 50, "days_to_exhaustion": 3.1})
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps({**ALL_OK, ("fleet-usage.ps1", ("forecast", "-Json")): bare}))
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet")
    assert resp.status_code == 200
    assert "3.1" in resp.text


def test_partial_endpoint_no_base_chrome(tmp_path, monkeypatch):
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(ALL_OK))
    client = TestClient(make_app(tmp_path))
    resp = client.get("/partials/fleet-ops")
    assert resp.status_code == 200
    assert "<!DOCTYPE html>" not in resp.text


def test_run_detail_page(tmp_path, monkeypatch):
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(ALL_OK))
    seed_go_run(tmp_path)
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet/runs/go-2026-07-01T10-00-00")
    assert resp.status_code == 200
    assert "**Status:** completed" in resp.text     # report.md shown verbatim in <pre>
    assert "plan: 1 tasks" in resp.text             # event message


def test_run_detail_404(tmp_path, monkeypatch):
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(ALL_OK))
    client = TestClient(make_app(tmp_path))
    assert client.get("/fleet/runs/go-1999-01-01T00-00-00").status_code == 404
    assert client.get("/fleet/runs/..%2F..%2Fetc").status_code == 404
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest dashboard/tests/test_fleet_router.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'dashboard.routers.fleet'`

- [ ] **Step 3: Write the router**

Create `dashboard/routers/fleet.py`:

```python
"""Live Fleet Ops (read-only). Fold data comes from the PS CLIs via pscli;
run rows come from fleet_runs. Every panel is individually fail-open."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers import pscli
from dashboard.readers.fleet_runs import list_go_runs, read_go_run_detail


def _usage_panel() -> dict:
    res = pscli.run_ps_json("fleet-usage.ps1", ("status", "-Json"))
    if not res.ok:
        return {"ok": False, "error": res.error}
    data = res.data if isinstance(res.data, dict) else {}
    workers = data.get("workers") or []
    if isinstance(workers, dict):        # defensive: 1-element PS array unroll
        workers = [workers]
    return {"ok": True, "conserve": bool(data.get("conserve_mode")), "workers": workers}


def _forecast_by_worker() -> dict[str, dict]:
    res = pscli.run_ps_json("fleet-usage.ps1", ("forecast", "-Json"))
    if not res.ok:
        return {}
    data = res.data
    if isinstance(data, dict):           # 1-worker fleet: bare object, not array
        data = [data]
    if not isinstance(data, list):
        return {}
    out: dict[str, dict] = {}
    for f in data:
        if isinstance(f, dict) and f.get("worker"):
            out[str(f["worker"])] = f
    return out


def _gated_count(candidate: Optional[dict]) -> int:
    live = (candidate or {}).get("live") or {}
    total = 0
    for k in ("accept", "polish", "reject"):
        try:
            total += int(live.get(k) or 0)
        except (TypeError, ValueError):
            pass
    return total


def _pool_panel() -> dict:
    res = pscli.run_ps_json("fleet-optimize-prompt.ps1", ("-Pool", "-Json"))
    if not res.ok:
        return {"ok": False, "error": res.error}
    pool = res.data if isinstance(res.data, dict) else {}
    cands = pool.get("candidates") or []
    if isinstance(cands, dict):
        cands = [cands]
    champion_id = str(pool.get("champion") or "")
    champion = next((c for c in cands if isinstance(c, dict) and c.get("id") == champion_id), None)
    challenger = next((c for c in cands if isinstance(c, dict) and c.get("status") == "candidate"), None)
    shadow_off = str(pool.get("shadow") or "").lower() == "off"
    return {
        "ok": True,
        "champion": champion_id,
        "champion_gated": _gated_count(champion),
        "challenger": (challenger or {}).get("id"),
        "challenger_gated": _gated_count(challenger) if challenger else None,
        "shadow_on": not shadow_off,
    }


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter()

    def _runs_root(req: Request) -> Path:
        return getattr(req.app.state, "runs_root", baton_home() / "runs")

    def _ops_ctx(request: Request) -> dict[str, Any]:
        return {
            "request": request,
            "usage": _usage_panel(),
            "forecast": _forecast_by_worker(),
            "pool": _pool_panel(),
            "runs": list_go_runs(_runs_root(request)),
        }

    @router.get("/fleet", response_class=HTMLResponse)
    async def fleet_ops(request: Request) -> HTMLResponse:
        return templates.TemplateResponse(request, "fleet_ops.html", _ops_ctx(request))

    @router.get("/partials/fleet-ops", response_class=HTMLResponse)
    async def partial_fleet_ops(request: Request) -> HTMLResponse:
        return templates.TemplateResponse(request, "partials/fleet_ops_body.html", _ops_ctx(request))

    @router.get("/fleet/runs/{run_id}", response_class=HTMLResponse)
    async def go_run_detail(run_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_go_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such conductor run: {run_id}")
        return templates.TemplateResponse(request, "go_run_detail.html", {
            "request": request, "detail": detail,
        })

    return router
```

- [ ] **Step 4: Write the templates**

Modify `dashboard/templates/base.html` — add a `head` block before `</head>` and a Fleet nav link. The `<head>` section gains one line after the existing stylesheet link:

```html
  <link rel="stylesheet" href="/static/style.css">
  {% block head %}{% endblock %}
```

and the nav gains one link after Portfolio:

```html
      <a href="/projects" class="{% if request.url.path.startswith('/projects') %}active{% endif %}">Portfolio</a>
      <a href="/fleet" class="{% if request.url.path.startswith('/fleet') %}active{% endif %}">Fleet</a>
```

Create `dashboard/templates/fleet_ops.html`:

```html
{% extends "base.html" %}
{% block title %}Live Fleet Ops{% endblock %}
{% block head %}<link rel="stylesheet" href="/static/fleet.css">{% endblock %}
{% block content %}
<h2>Live Fleet Ops</h2>
<div class="fleet-ops" hx-get="/partials/fleet-ops" hx-trigger="every 30s" hx-swap="innerHTML">
  {% include "partials/fleet_ops_body.html" %}
</div>
{% endblock %}
```

Create `dashboard/templates/partials/fleet_ops_body.html`:

```html
{% include "partials/fleet_worker_board.html" %}
{% include "partials/fleet_pool_line.html" %}
{% include "partials/fleet_runs_strip.html" %}
```

Create `dashboard/templates/partials/fleet_worker_board.html`:

```html
<section class="panel worker-board">
  <h3>Workers</h3>
  {% if not usage.ok %}
    <p class="panel-degraded">Usage governor unavailable: {{ usage.error }}</p>
  {% else %}
    {% if usage.conserve %}<p class="conserve-banner">CONSERVE MODE ON — economy routing enforced</p>{% endif %}
    {% if not usage.workers %}
      <p class="panel-empty">No usage data yet — workers appear after their first governed dispatch.</p>
    {% else %}
      <table class="fleet-table">
        <thead><tr><th>Worker</th><th>State</th><th>ETA / reason</th><th>Budget</th><th>Rate</th><th>Days left</th></tr></thead>
        <tbody>
        {% for w in usage.workers %}
          {% set fc = forecast.get(w.worker) %}
          <tr>
            <td>{{ w.worker }}</td>
            <td><span class="state state-{{ w.state }}">{{ w.state }}</span></td>
            <td>{{ w.eta_human or w.reason or '' }}</td>
            <td>{{ fc.budget if fc and fc.get('budget') is not none else '—' }}</td>
            <td>{% if fc %}{{ fc.run_rate }}/{{ fc.unit }}{% else %}—{% endif %}</td>
            <td>{{ fc.days_to_exhaustion if fc and fc.get('days_to_exhaustion') is not none else '—' }}</td>
          </tr>
        {% endfor %}
        </tbody>
      </table>
    {% endif %}
  {% endif %}
</section>
```

Create `dashboard/templates/partials/fleet_pool_line.html`:

```html
<section class="panel pool-line">
  <h3>Prompt pool</h3>
  {% if not pool.ok %}
    <p class="panel-empty">No prompt pool yet ({{ pool.error }}). Seed it with /baton:optimize-prompt.</p>
  {% else %}
    <p>
      Champion <strong>{{ pool.champion }}</strong> ({{ pool.champion_gated }} gated runs)
      {% if pool.challenger %}
        vs challenger <strong>{{ pool.challenger }}</strong> ({{ pool.challenger_gated }} gated runs)
      {% else %}
        — no active challenger
      {% endif %}
      · shadow {{ 'ON' if pool.shadow_on else 'OFF' }}
      · dollars verdict: <code>/baton:optimize-prompt --pool</code>
    </p>
  {% endif %}
</section>
```

Create `dashboard/templates/partials/fleet_runs_strip.html`:

```html
<section class="panel runs-strip">
  <h3>Recent conductor runs</h3>
  {% if not runs %}
    <p class="panel-empty">No conductor runs yet — <code>/baton:go</code> writes them here.</p>
  {% else %}
    <table class="fleet-table">
      <thead><tr><th>Run</th><th>Goal</th><th>Status</th><th>Verdict</th><th>Cost</th><th>Eff. cost</th><th>Shadow</th></tr></thead>
      <tbody>
      {% for r in runs %}
        <tr>
          <td><a href="/fleet/runs/{{ r.run_id }}">{{ r.run_id }}</a></td>
          <td>{{ r.goal }}</td>
          <td><span class="state state-{{ r.status | replace(' ', '-') }}">{{ r.status }}</span></td>
          <td>{% if r.verdict %}<span class="verdict verdict-{{ r.verdict }}">{{ r.verdict }}</span>{% else %}—{% endif %}</td>
          <td>{% if r.cost is not none %}{{ '%.2f' | format(r.cost) }} <small>({{ r.cost_basis }})</small>{% else %}—{% endif %}</td>
          <td>{% if r.effective_cost is not none %}{{ '%.4f' | format(r.effective_cost) }}{% else %}—{% endif %}</td>
          <td>{% if r.shadow_role %}{{ r.shadow_role }} {{ r.shadow_variant }}{% else %}—{% endif %}</td>
        </tr>
      {% endfor %}
      </tbody>
    </table>
  {% endif %}
</section>
```

Create `dashboard/templates/go_run_detail.html`:

```html
{% extends "base.html" %}
{% block title %}{{ detail.row.run_id }}{% endblock %}
{% block head %}<link rel="stylesheet" href="/static/fleet.css">{% endblock %}
{% block content %}
<h2>{{ detail.row.run_id }}</h2>
<p class="run-summary">
  <strong>{{ detail.row.goal }}</strong> ·
  status <span class="state state-{{ detail.row.status | replace(' ', '-') }}">{{ detail.row.status }}</span>
  {% if detail.row.verdict %} · verdict <span class="verdict verdict-{{ detail.row.verdict }}">{{ detail.row.verdict }}</span>{% endif %}
  {% if detail.row.cost is not none %} · cost {{ '%.2f' | format(detail.row.cost) }} ({{ detail.row.cost_basis }}){% endif %}
</p>

<section class="panel">
  <h3>Report</h3>
  {% if detail.report_md %}<pre class="report">{{ detail.report_md }}</pre>
  {% else %}<p class="panel-empty">No report yet — run still in flight.</p>{% endif %}
</section>

<section class="panel">
  <h3>Events ({{ detail.events | length }})</h3>
  {% if detail.events %}
  <table class="fleet-table">
    <thead><tr><th>ts</th><th>level</th><th>task</th><th>kind</th><th>message</th></tr></thead>
    <tbody>
    {% for e in detail.events %}
      <tr class="level-{{ e.level }}"><td>{{ e.ts }}</td><td>{{ e.level }}</td><td>{{ e.task_id }}</td><td>{{ e.kind }}</td><td>{{ e.message }}</td></tr>
    {% endfor %}
    </tbody>
  </table>
  {% else %}<p class="panel-empty">No events recorded.</p>{% endif %}
</section>

<section class="panel">
  <h3>Decisions ({{ detail.decisions | length }})</h3>
  {% if detail.decisions %}
  <table class="fleet-table">
    <thead><tr><th>ts</th><th>task</th><th>chose</th><th>why</th><th>alternatives</th></tr></thead>
    <tbody>
    {% for d in detail.decisions %}
      <tr><td>{{ d.ts }}</td><td>{{ d.task_id }}</td><td><strong>{{ d.chose }}</strong></td><td>{{ d.why }}</td><td>{{ d.alternatives | join(', ') }}</td></tr>
    {% endfor %}
    </tbody>
  </table>
  {% else %}<p class="panel-empty">No autonomous decisions recorded.</p>{% endif %}
</section>
{% endblock %}
```

Create `dashboard/static/fleet.css`:

```css
/* Live Fleet Ops / leaderboard styling — NEW file; style.css is Kevin's and
   is never edited by this feature. Obsidian Command look: dark panels,
   state chips, verdict badges. */
.fleet-ops .panel, .panel {
  background: #16161d;
  border: 1px solid #2a2a35;
  border-radius: 8px;
  padding: 12px 16px;
  margin: 12px 0;
}
.panel h3 { margin: 0 0 8px 0; color: #c8c8d8; font-size: 0.95rem; letter-spacing: 0.04em; text-transform: uppercase; }
.fleet-table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
.fleet-table th { text-align: left; color: #8888a0; font-weight: 600; padding: 4px 8px; border-bottom: 1px solid #2a2a35; }
.fleet-table td { padding: 4px 8px; border-bottom: 1px solid #1e1e28; }
.state { padding: 1px 8px; border-radius: 10px; font-size: 0.8rem; white-space: nowrap; }
.state-available { background: #103a24; color: #4ade80; }
.state-limited { background: #3a3210; color: #facc15; }
.state-cooling_down, .state-waiting_for_reset { background: #1e2a3a; color: #60a5fa; }
.state-exhausted { background: #3a1010; color: #f87171; }
.state-completed { background: #103a24; color: #4ade80; }
.state-rejected, .state-failed, .state-plan-failed, .state-plan-invalid { background: #3a1010; color: #f87171; }
.state-in-flight { background: #1e2a3a; color: #60a5fa; }
.verdict { padding: 1px 8px; border-radius: 4px; font-size: 0.8rem; font-weight: 700; }
.verdict-accept { background: #103a24; color: #4ade80; }
.verdict-polish { background: #3a3210; color: #facc15; }
.verdict-reject { background: #3a1010; color: #f87171; }
.conserve-banner { background: #3a1010; color: #f87171; padding: 6px 10px; border-radius: 6px; font-weight: 700; }
.panel-degraded { color: #f87171; font-style: italic; }
.panel-empty { color: #8888a0; font-style: italic; }
pre.report { background: #0e0e14; border: 1px solid #2a2a35; border-radius: 6px; padding: 12px; overflow-x: auto; white-space: pre-wrap; color: #c8c8d8; }
tr.level-warn td, tr.level-error td { color: #facc15; }
```

- [ ] **Step 5: Wire the router into the app**

Modify `dashboard/main.py` — after the existing runs-router include, add:

```python
from dashboard.routers.fleet import build_router as build_fleet_router
app.include_router(build_fleet_router(templates))
```

- [ ] **Step 6: Run the new tests, then the full suite**

Run: `python -m pytest dashboard/tests/test_fleet_router.py -q`
Expected: `8 passed`
Run: `python -m pytest dashboard/tests -q`
Expected: all pass (base.html edits must not break existing page tests — if a test asserts exact nav contents, update it to include the Fleet link)

- [ ] **Step 7: Commit (SLICE 1 boundary)**

```bash
git add dashboard/routers/fleet.py dashboard/templates dashboard/static/fleet.css dashboard/main.py dashboard/tests/test_fleet_router.py
git commit -m "feat(dashboard): Live Fleet Ops page — worker board, conductor runs strip, pool line (slice 1)"
```

---

## SLICE 2 — Model Leaderboard

### Task 4: `learned` subcommand on fleet-effective-cost.ps1

**Files:**
- Modify: `scripts/fleet-effective-cost.ps1`
- Test: `scripts/test-fleet-effective-cost.ps1` (append checks C16–C19)

**Interfaces:**
- Consumes: `Get-WorkerEffectiveCost`, `Get-LearnedRoutingEnabled -FleetPath` (mandatory param), `Get-LearnedCostAdjustment -Worker -Board` — all existing in `effective-cost-lib.ps1`.
- Produces: `fleet-effective-cost.ps1 learned -Json` → `{"learned_routing": bool, "workers": [{"worker","adjust","confidence","reason"}]}`. Task 5's leaderboard page consumes this. Rationale: the dashboard must never re-implement the learned-adjustment fold in Python; this makes the CLI the contract.

- [ ] **Step 1: Add the failing checks**

In `scripts/test-fleet-effective-cost.ps1`, insert BEFORE the closing `}` of the `try` block (after the C15 check):

```powershell
    # C16-C19: 'learned' subcommand — learned-routing adjustments as JSON.
    # Fixture fleet WITH the switch on; the 3-record board is low-confidence,
    # so adjustments are honestly inert (adjust = 0) — the shape is the contract.
    $fleetOn = Join-Path $tmp 'fleet-on.yaml'
    Set-Content -LiteralPath $fleetOn -Value "learned_routing: true`nproviders: []`n" -Encoding utf8NoBOM
    $learnedJson = (& pwsh -NoProfile -File $cli learned -RunsRoot $runsRoot -FleetPath $fleetOn -Json 2>$null | Out-String)
    Check 'C16 learned -Json exit 0' ($LASTEXITCODE -eq 0)
    $lp = $learnedJson | ConvertFrom-Json
    Check 'C17 learned reports the switch + per-worker adjust rows' (
        ($lp.learned_routing -eq $true) -and
        (@($lp.workers).Count -eq 2) -and
        (@($lp.workers).worker -contains 'cheapw') -and
        ($null -ne (@($lp.workers)[0].PSObject.Properties['adjust']))
    )

    $fleetOff = Join-Path $tmp 'fleet-off.yaml'
    Set-Content -LiteralPath $fleetOff -Value "providers: []`n" -Encoding utf8NoBOM
    $offJson = (& pwsh -NoProfile -File $cli learned -RunsRoot $runsRoot -FleetPath $fleetOff -Json 2>$null | Out-String)
    Check 'C18 learned honest when switch absent' ((($offJson | ConvertFrom-Json).learned_routing) -eq $false)

    $emptyLearned = (& pwsh -NoProfile -File $cli learned -RunsRoot $emptyRoot -FleetPath $fleetOff -Json 2>$null | Out-String)
    Check 'C19 learned on empty board is a valid empty workers array' (@(($emptyLearned | ConvertFrom-Json).workers).Count -eq 0)
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-fleet-effective-cost.ps1`
Expected: C1–C15 PASS; C16 FAILS (unknown subcommand exits 2)

- [ ] **Step 3: Implement the subcommand**

In `scripts/fleet-effective-cost.ps1`:

(a) Add a `-FleetPath` parameter to the `param(...)` block, after `$RunsRoot`:

```powershell
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
```

(b) Add a `'learned'` case to the `switch ($Subcommand)` block, before `default`:

```powershell
    'learned' {
        # Learned-routing explainability: the d060 adjustment per board worker.
        # The dashboard consumes this JSON — the fold stays here, never in Python.
        $records = if ($Runs) { Read-EffectiveCostRecords -Glob $Runs } else { Read-EffectiveCostRecords -RunsRoot $RunsRoot }
        $board = Get-WorkerEffectiveCost -Records @($records) -MinConfidenceRuns $MinConfidenceRuns
        $enabled = Get-LearnedRoutingEnabled -FleetPath $FleetPath
        $rows = @(foreach ($r in @($board)) {
            $adj = Get-LearnedCostAdjustment -Worker ([string]$r.worker) -Board @($board)
            [ordered]@{
                worker     = [string]$r.worker
                adjust     = [double]$adj.adjust
                confidence = [double]$adj.confidence
                reason     = $adj.reason
            }
        })
        $out = [ordered]@{ learned_routing = [bool]$enabled; workers = @($rows) }
        if ($Json) { ConvertTo-Json -InputObject $out -Depth 6 }
        else {
            Write-Host ("learned_routing: {0}" -f $enabled)
            foreach ($r in $rows) {
                $why = if ($r.reason) { $r.reason } else { 'inert' }
                Write-Host ("{0,-18} adjust={1,7:0.0000}  {2}" -f $r.worker, $r.adjust, $why)
            }
        }
        return
    }
```

(c) Update the `default` case's usage string to `(use report|learned)`.

- [ ] **Step 4: Run the suite to verify all checks pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-effective-cost.ps1`
Expected: `ALL CHECKS PASS` (C1–C19)

- [ ] **Step 5: Regression — the untouched lib suite**

Run: `pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1`
Expected: `ALL CHECKS PASS`

- [ ] **Step 6: Commit**

```bash
git add scripts/fleet-effective-cost.ps1 scripts/test-fleet-effective-cost.ps1
git commit -m "feat(effective-cost): learned subcommand — learned-routing adjustments as a JSON CLI surface"
```

### Task 5: Model Leaderboard page

**Files:**
- Modify: `dashboard/routers/fleet.py` (add `/fleet/leaderboard` route + two panel helpers)
- Create: `dashboard/templates/fleet_leaderboard.html` (NOT `leaderboard.html` — `partials/leaderboard.html` already exists for the routing-journal board; the distinct name avoids confusion)
- Test: append to `dashboard/tests/test_fleet_router.py`

**Interfaces:**
- Consumes: `pscli.run_ps_json` with `("report", "-Json")` and `("learned", "-Json")` against `fleet-effective-cost.ps1` (Task 4's surface); board row fields `worker/n_runs/eff_cost_mean/single_producer_runs/confidence`.
- Produces: route `GET /fleet/leaderboard`.

- [ ] **Step 1: Write the failing tests**

Append to `dashboard/tests/test_fleet_router.py`:

```python
BOARD_OK = pscli.PsResult(ok=True, data=[
    {"worker": "claude-haiku", "n_runs": 6, "eff_cost_mean": 0.0714,
     "single_producer_runs": 6, "confidence": 1.0},
    {"worker": "claude-sonnet", "n_runs": 2, "eff_cost_mean": 1.4863,
     "single_producer_runs": 1, "confidence": 0.3},
])
LEARNED_ON = pscli.PsResult(ok=True, data={
    "learned_routing": True,
    "workers": [
        {"worker": "claude-haiku", "adjust": -0.62, "confidence": 1.0,
         "reason": "learned eff_cost 0.07 vs fleet median 1.49 (conf 1.00) -> -0.62 tier"},
        {"worker": "claude-sonnet", "adjust": 0.0, "confidence": 0.3, "reason": None},
    ],
})
LEADER_OK = {
    ("fleet-effective-cost.ps1", ("report", "-Json")): BOARD_OK,
    ("fleet-effective-cost.ps1", ("learned", "-Json")): LEARNED_ON,
}


def test_leaderboard_renders_ranked_rows(tmp_path, monkeypatch):
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(LEADER_OK))
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet/leaderboard")
    assert resp.status_code == 200
    assert resp.text.index("claude-haiku") < resp.text.index("claude-sonnet")  # cheapest first
    assert "0.0714" in resp.text
    assert "tentative" in resp.text                  # confidence 0.3 < 0.5 flagged


def test_leaderboard_learned_column_when_on(tmp_path, monkeypatch):
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(LEADER_OK))
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet/leaderboard")
    assert "-0.62" in resp.text
    assert "fleet median" in resp.text               # the why string


def test_leaderboard_learned_column_hidden_when_off(tmp_path, monkeypatch):
    learned_off = pscli.PsResult(ok=True, data={"learned_routing": False, "workers": []})
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(
        {**LEADER_OK, ("fleet-effective-cost.ps1", ("learned", "-Json")): learned_off}))
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet/leaderboard")
    assert resp.status_code == 200
    assert "learned routing: off" in resp.text.lower()


def test_leaderboard_empty_board(tmp_path, monkeypatch):
    empty = {
        ("fleet-effective-cost.ps1", ("report", "-Json")): pscli.PsResult(ok=True, data=[]),
        ("fleet-effective-cost.ps1", ("learned", "-Json")): pscli.PsResult(ok=True, data={"learned_routing": False, "workers": []}),
    }
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(empty))
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet/leaderboard")
    assert resp.status_code == 200
    assert "No effective-cost records" in resp.text


def test_leaderboard_degrades_without_500(tmp_path, monkeypatch):
    broken = {
        ("fleet-effective-cost.ps1", ("report", "-Json")): pscli.PsResult(ok=False, error="exit 1: kaput"),
        ("fleet-effective-cost.ps1", ("learned", "-Json")): pscli.PsResult(ok=False, error="exit 1: kaput"),
    }
    monkeypatch.setattr(pscli, "run_ps_json", fake_ps(broken))
    client = TestClient(make_app(tmp_path))
    resp = client.get("/fleet/leaderboard")
    assert resp.status_code == 200
    assert "kaput" in resp.text
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest dashboard/tests/test_fleet_router.py -q`
Expected: the 5 new tests FAIL with 404 on `/fleet/leaderboard`; the 8 slice-1 tests still pass

- [ ] **Step 3: Implement**

In `dashboard/routers/fleet.py`, add two module-level helpers after `_pool_panel`:

```python
def _board_panel() -> dict:
    res = pscli.run_ps_json("fleet-effective-cost.ps1", ("report", "-Json"))
    if not res.ok:
        return {"ok": False, "error": res.error}
    rows = res.data if isinstance(res.data, list) else []
    return {"ok": True, "rows": [r for r in rows if isinstance(r, dict)]}


def _learned_panel() -> dict:
    res = pscli.run_ps_json("fleet-effective-cost.ps1", ("learned", "-Json"))
    if not res.ok:
        return {"ok": False, "error": res.error, "enabled": False, "by_worker": {}}
    data = res.data if isinstance(res.data, dict) else {}
    workers = data.get("workers") or []
    if isinstance(workers, dict):
        workers = [workers]
    by_worker = {str(w["worker"]): w for w in workers if isinstance(w, dict) and w.get("worker")}
    return {"ok": True, "enabled": bool(data.get("learned_routing")), "by_worker": by_worker}
```

and a route inside `build_router` (before `return router`):

```python
    @router.get("/fleet/leaderboard", response_class=HTMLResponse)
    async def fleet_leaderboard(request: Request) -> HTMLResponse:
        return templates.TemplateResponse(request, "fleet_leaderboard.html", {
            "request": request,
            "board": _board_panel(),
            "learned": _learned_panel(),
        })
```

Create `dashboard/templates/fleet_leaderboard.html`:

```html
{% extends "base.html" %}
{% block title %}Model Leaderboard{% endblock %}
{% block head %}<link rel="stylesheet" href="/static/fleet.css">{% endblock %}
{% block content %}
<h2>Model Leaderboard <small>(effective cost = realized cost ÷ realized quality; lower is better)</small></h2>

<section class="panel">
  {% if not board.ok %}
    <p class="panel-degraded">Leaderboard unavailable: {{ board.error }}</p>
  {% elif not board.rows %}
    <p class="panel-empty">No effective-cost records yet. Run <code>/baton:go</code> with a gate (<code>--gate-artifact</code> / <code>--gate-diff</code>) to produce them.</p>
  {% else %}
    <p>Learned routing: <strong>{{ 'ON' if learned.enabled else 'off' }}</strong>{% if not learned.ok %} <span class="panel-degraded">(adjustments unavailable: {{ learned.error }})</span>{% endif %}</p>
    <table class="fleet-table">
      <thead><tr><th>#</th><th>Worker</th><th>Eff. cost (mean)</th><th>Runs</th><th>Solo runs</th><th>Confidence</th>{% if learned.enabled %}<th>Learned adjust</th><th>Why</th>{% endif %}</tr></thead>
      <tbody>
      {% for r in board.rows %}
        {% set adj = learned.by_worker.get(r.worker) %}
        <tr>
          <td>{{ loop.index }}</td>
          <td>{{ r.worker }}{% if r.confidence < 0.5 %} <span class="state state-limited">tentative</span>{% endif %}</td>
          <td>{{ '%.4f' | format(r.eff_cost_mean) }}</td>
          <td>{{ r.n_runs }}</td>
          <td>{{ r.single_producer_runs }}</td>
          <td>{{ '%.2f' | format(r.confidence) }}</td>
          {% if learned.enabled %}
            <td>{% if adj %}{{ '%.2f' | format(adj.adjust) }}{% else %}—{% endif %}</td>
            <td>{% if adj and adj.reason %}{{ adj.reason }}{% else %}inert{% endif %}</td>
          {% endif %}
        </tr>
      {% endfor %}
      </tbody>
    </table>
  {% endif %}
</section>
{% endblock %}
```

Also add a nav link on the fleet page: in `dashboard/templates/fleet_ops.html`, after the `<h2>` line add:

```html
<p><a href="/fleet/leaderboard">→ Model Leaderboard</a></p>
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest dashboard/tests/test_fleet_router.py -q`
Expected: `13 passed`

- [ ] **Step 5: Full dashboard suite**

Run: `python -m pytest dashboard/tests -q`
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add dashboard/routers/fleet.py dashboard/templates/fleet_leaderboard.html dashboard/templates/fleet_ops.html dashboard/tests/test_fleet_router.py
git commit -m "feat(dashboard): model leaderboard page with learned-routing explainability (slice 2)"
```

### Task 6: Docs, version bump, full sweep

**Files:**
- Modify: `.claude-plugin/plugin.json` (version `1.8.0` → `1.9.0-rc.1`)
- Modify: `docs/COMMANDS.md` (new Dashboard section)

- [ ] **Step 1: Bump the plugin version**

In `.claude-plugin/plugin.json`, change `"version": "1.8.0"` to `"version": "1.9.0-rc.1"`.

- [ ] **Step 2: Document the dashboard pages**

Append to `docs/COMMANDS.md`:

```markdown
## Dashboard — Live Fleet Ops + Model Leaderboard

The FastAPI dashboard (start with `python -m dashboard.main`, then open
`http://127.0.0.1:8765`) gains two read-only pages:

- **`/fleet` — Live Fleet Ops:** every fleet worker with its usage-governor
  state (available/limited/exhausted/cooling_down/waiting_for_reset), the
  conserve banner, budget/run-rate/forecast where present; the last 10
  `/baton:go` conductor runs (status, gate verdict, realized + effective
  cost, shadow A/B variant) with click-through to the full report, events,
  and autonomous-decision ledgers; and a prompt-pool one-liner
  (champion/challenger/gated-run counts — the dollars verdict stays in
  `/baton:optimize-prompt --pool`).
- **`/fleet/leaderboard` — Model Leaderboard:** the per-worker
  effective-cost board (`/baton:effective-cost` data), cheapest
  quality-adjusted worker first, low-confidence rows flagged tentative;
  when `learned_routing` is on, each worker's live routing adjustment and
  its plain-language why.

Data honesty: all folded numbers come from the Baton PS CLIs' `--json`
surfaces (cached 15 s); the dashboard never re-implements a fold. A broken
CLI degrades that one panel, never the page. Read-only: the dashboard
writes nothing to `$BATON_HOME`.
```

- [ ] **Step 3: Full verification sweep**

Run, expecting every one green:

```bash
python -m pytest dashboard/tests -q
pwsh -NoProfile -File scripts/test-fleet-effective-cost.ps1
pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1
```

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json docs/COMMANDS.md
git commit -m "docs: dashboard Live Fleet Ops + leaderboard; bump 1.8.0 -> 1.9.0-rc.1"
```

---

## Execution Handoff

Branch: `feature/dashboard-live-fleet-ops` (from master). Subagent-driven
(superpowers:subagent-driven-development), streamlined ceremony per Kevin's
standing rule: NO per-task reviewers; one opus final whole-branch review at
the end. Model ladder per task:

| Task | What | Model |
|------|------|-------|
| 1 | pscli reader (complete code above — transcription + run tests) | haiku |
| 2 | fleet_runs reader + models (complete code above) | haiku |
| 3 | Live Fleet Ops page (multi-file wiring, template/CSS integration, base.html touch) | sonnet |
| 4 | PS `learned` subcommand + suite checks (complete code above) | haiku |
| 5 | Leaderboard page (router extension + template integration) | sonnet |
| 6 | Docs + version bump + sweep | haiku |
| Final | Whole-branch review (READY TO MERGE gate before PR) | opus |

Slice boundary: Task 3's commit ends Slice 1 (Live Fleet Ops); Tasks 4–5 are
Slice 2 (leaderboard). Single PR by default; if Kevin wants the spec's
slice-per-PR shape, cut the first PR after Task 3 and move Task 6's version
bump into it.

Reminders for the controller: implementers must NOT touch
`dashboard/static/style.css`; all tests monkeypatch pscli (no real pwsh in
pytest); PS suite runs happen only in Tasks 4/6 via child pwsh.
