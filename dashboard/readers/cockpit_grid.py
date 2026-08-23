"""OctoAlly-shaped active sessions grid — Maestro jobs × fleet runs × live tails.

Pure filesystem reader (torch-free). Used by HTMX partial and WebSocket push.
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from dashboard.readers.maestro_jobs import (
    list_jobs,
    list_registry_projects,
    maestro_root,
)
from dashboard.readers.display_goal import sanitize_goal
from dashboard.readers.runs import list_runs


_ACTIVE_RUN = frozenset({"running", "needs-you", "queued"})
_LIVE_JOB = frozenset({"running", "admitted", "queued", "waiting-quota"})
_THINKING = frozenset({"thinking", "reason", "reasoning", "thought"})
_COMMAND = frozenset({"hook", "bash", "command", "tool", "cmd", "spent"})
_OUTPUT = frozenset({"action", "output", "reply", "result", "assistant", "what", "error"})


@dataclass
class CockpitCell:
    project_id: str
    name: str
    status: str = "idle"
    job_id: Optional[str] = None
    run_id: Optional[str] = None
    provider: Optional[str] = None
    goal: str = ""
    tail: list[str] = field(default_factory=list)
    turns: list[dict[str, Any]] = field(default_factory=list)
    live: bool = False
    model: Optional[str] = None
    current_step: Optional[str] = None
    last_output: str = ""


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _latest_job_by_project(jobs: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for j in sorted(jobs, key=lambda x: x.get("created_at") or ""):
        pid = (j.get("project") or "").strip()
        if pid:
            out[pid] = j
    return out


def _active_run_by_project(runs_root: Path) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for rec in list_runs(runs_root):
        pid = (rec.project or "").strip()
        if not pid or rec.status not in _ACTIVE_RUN:
            continue
        prev = out.get(pid)
        if prev is None or (rec.updated_at and prev.updated_at and rec.updated_at > prev.updated_at):
            out[pid] = rec
    return out


def classify_event_kind(kind: str) -> str:
    k = (kind or "event").strip().lower()
    if k in _THINKING:
        return "thinking"
    if k in _COMMAND:
        return "command"
    if k in _OUTPUT:
        return "output"
    return "event"


def peek_text(text: str, max_len: int = 220) -> str:
    t = " ".join((text or "").split())
    if len(t) <= max_len:
        return t
    return t[: max_len - 1] + "…"


def last_output_from_turns(turns: list[dict[str, Any]]) -> str:
    for t in reversed(turns):
        if t.get("kind") == "output":
            return peek_text(str(t.get("detail") or ""))
    if turns:
        return peek_text(str(turns[-1].get("detail") or ""))
    return ""


def event_to_turn(kind: str, text: str) -> dict[str, Any]:
    bucket = classify_event_kind(kind)
    label = " ".join((text or kind or "").split())
    if len(label) > 88:
        label = label[:87] + "…"
    return {
        "kind": bucket,
        "raw_kind": kind or "event",
        "label": label or bucket,
        "detail": text or kind or "",
        "collapsed": bucket != "output",
    }


def _event_detail(row: dict[str, Any]) -> str:
    for key in ("what", "message", "text", "output", "preview", "content", "detail"):
        val = row.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    kind = str(row.get("kind") or "event")
    bits = [kind]
    for key in ("status", "provider", "run_id"):
        val = row.get(key)
        if val:
            bits.append(str(val))
    return " · ".join(bits)


def _maestro_event_tail(jobs_dir: Path, job_id: Optional[str], limit: int = 8) -> list[str]:
    if not job_id:
        return []
    events_path = jobs_dir / "events.jsonl"
    if not events_path.is_file():
        return []
    rows: list[str] = []
    try:
        lines = events_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for line in lines[-400:]:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("job_id") != job_id:
            continue
        rows.append(_event_detail(row))
    return rows[-limit:]


def _run_event_tail(runs_root: Path, run_id: Optional[str], limit: int = 6) -> list[str]:
    if not run_id:
        return []
    events_path = runs_root / run_id / "events.jsonl"
    if not events_path.is_file():
        return []
    rows: list[str] = []
    try:
        lines = events_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for line in lines[-120:]:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        rows.append(_event_detail(row))
    return rows[-limit:]


def _goal_snippet(goal: str, max_len: int = 120) -> str:
    return sanitize_goal(goal, max_len=max_len)


def turns_for_job(jobs_dir: Path, job_id: Optional[str], runs_root: Optional[Path] = None, run_id: Optional[str] = None, limit: int = 12) -> list[dict[str, Any]]:
    """Structured turns for the output strip — thinking/commands start collapsed."""
    turns: list[dict[str, Any]] = []
    if job_id:
        events_path = jobs_dir / "events.jsonl"
        if events_path.is_file():
            try:
                lines = events_path.read_text(encoding="utf-8").splitlines()
            except OSError:
                lines = []
            for line in lines[-400:]:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if row.get("job_id") != job_id:
                    continue
                kind = str(row.get("kind") or "event")
                turns.append(event_to_turn(kind, _event_detail(row)))
    if runs_root and run_id:
        events_path = runs_root / run_id / "events.jsonl"
        if events_path.is_file():
            try:
                lines = events_path.read_text(encoding="utf-8").splitlines()
            except OSError:
                lines = []
            for line in lines[-120:]:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                kind = str(row.get("kind") or "event")
                turns.append(event_to_turn(kind, _event_detail(row)))
    return turns[-limit:]


def read_cockpit_grid(baton_home: Path, runs_root: Path) -> dict[str, Any]:
    """Build grid cells for every Maestro registry project."""
    jobs_dir = maestro_root(baton_home)
    registry = list_registry_projects(baton_home)
    jobs = list_jobs(jobs_dir)
    job_by_project = _latest_job_by_project(jobs)
    run_by_project = _active_run_by_project(runs_root)

    cells: list[CockpitCell] = []
    for proj in registry:
        pid = proj["id"]
        name = proj.get("name") or pid
        job = job_by_project.get(pid)
        run = run_by_project.get(pid)

        status = "idle"
        job_id = run_id = provider = model = step = None
        goal = ""
        tail: list[str] = []
        turns: list[dict[str, Any]] = []
        live = False

        if job:
            status = str(job.get("status") or "queued")
            job_id = job.get("id")
            run_id = job.get("run_id") or run_id
            provider = job.get("provider")
            goal = _goal_snippet(str(job.get("goal") or ""))
            live = status in _LIVE_JOB
            tail.extend(_maestro_event_tail(jobs_dir, job_id))

        if run:
            status = run.status if status == "idle" else status
            run_id = run.id
            model = run.model
            step = run.current_step
            live = True
            tail.extend(_run_event_tail(runs_root, run.id))

        turns = turns_for_job(jobs_dir, job_id, runs_root, run_id)
        last_output = last_output_from_turns(turns)

        # De-dupe tail, keep last N
        seen: set[str] = set()
        deduped: list[str] = []
        for line in tail:
            if line in seen:
                continue
            seen.add(line)
            deduped.append(line)
        tail = deduped[-10:]

        cells.append(
            CockpitCell(
                project_id=pid,
                name=name,
                status=status,
                job_id=job_id,
                run_id=run_id,
                provider=provider or model,
                goal=goal,
                tail=tail,
                turns=turns,
                live=live,
                model=model,
                current_step=step,
                last_output=last_output,
            )
        )

    # Sort: live first, then running-ish statuses, then name
    order = {"running": 0, "needs-you": 1, "admitted": 2, "queued": 3, "waiting-quota": 4, "held": 5, "idle": 6, "done": 7}
    cells.sort(key=lambda c: (0 if c.live else 1, order.get(c.status, 9), c.name.lower()))

    payload = {
        "schema": 1,
        "updated_at": _now_iso(),
        "cells": [asdict(c) for c in cells],
        "live_count": sum(1 for c in cells if c.live),
    }
    return payload
