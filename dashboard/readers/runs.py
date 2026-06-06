from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Optional

from dashboard.models.runs import RunRecord, RunEvent, RunDetail, GlobalStrip

_ACTIVE_ORDER = {"running": 0, "queued": 1, "needs-you": 2, "idle": 3, "done": 4, "failed": 5}


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
