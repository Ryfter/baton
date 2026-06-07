from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Optional

from dashboard.models.runs import RunRecord, RunEvent, RunDetail, GlobalStrip, AgentLane

_ACTIVE_ORDER = {"needs-you": 0, "running": 1, "queued": 2, "idle": 3, "done": 4, "failed": 5}

_INVALID_RUN_ID_CHARS = {"/", "\\"}


def _validate_run_id(run_id: str) -> None:
    """Raise FileNotFoundError if run_id could escape the runs_root directory.

    Rejects: empty string, absolute paths, any id containing path separators
    or the parent-directory component '..'.
    """
    if not run_id:
        raise FileNotFoundError(f"Invalid run_id: {run_id!r}")
    if any(ch in run_id for ch in _INVALID_RUN_ID_CHARS):
        raise FileNotFoundError(f"Invalid run_id: {run_id!r}")
    # Split on both separators to catch disguised traversal like 'a/..\\b'
    parts = run_id.replace("\\", "/").split("/")
    if ".." in parts:
        raise FileNotFoundError(f"Invalid run_id: {run_id!r}")
    # Reject absolute paths (e.g. '/etc/passwd' or 'C:\\Windows')
    from pathlib import PurePosixPath, PureWindowsPath
    if PurePosixPath(run_id).is_absolute() or PureWindowsPath(run_id).is_absolute():
        raise FileNotFoundError(f"Invalid run_id: {run_id!r}")


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
    _validate_run_id(run_id)
    run_dir = runs_root / run_id
    rec = _read_record(run_dir)
    if rec is None:
        raise FileNotFoundError(f"No such run: {run_id}")
    return RunDetail(record=rec, events=_read_events(run_dir))


def read_global_strip(runs_root: Path) -> GlobalStrip:
    # Always compute active_runs from actual disk state — never trust index.json for this.
    active = sum(1 for r in list_runs(runs_root) if r.status in ("running", "needs-you", "queued"))
    idx = runs_root / "index.json"
    if not idx.exists():
        return GlobalStrip(active_runs=active)
    try:
        data = json.loads(idx.read_text(encoding="utf-8"))
        # Override whatever active_runs index.json claims with the computed value.
        data["active_runs"] = active
        return GlobalStrip(**data)
    except (json.JSONDecodeError, ValueError, TypeError):
        return GlobalStrip(active_runs=active)


def write_run_answer(runs_root: Path, run_id: str, answer: str) -> None:
    _validate_run_id(run_id)
    run_dir = runs_root / run_id
    if not (run_dir / "run.json").exists():
        raise FileNotFoundError(f"No such run: {run_id}")
    (run_dir / "answer.txt").write_text(answer, encoding="utf-8")


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
