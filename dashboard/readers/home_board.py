"""Home shift board — attention rail, capacity strip, project cards."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from dashboard.readers.claude_quota import read_claude_quota
from dashboard.readers.cockpit_grid import read_cockpit_grid
from dashboard.readers.display_goal import sanitize_goal
from dashboard.readers.gauges import _fmt_tokens, resolve_window
from dashboard.readers.maestro_jobs import list_jobs, maestro_root
from dashboard.readers.project_economics import economics_for_projects

_ATTENTION_STATUSES = frozenset({"waiting-quota", "held"})
_LIVE_STATUSES = frozenset({"running", "admitted", "queued", "waiting-quota", "held"})
_STALL_SECONDS = 300


def _parse_ts(value: Any) -> Optional[datetime]:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _last_job_activity(jobs_dir: Path, job_id: Optional[str]) -> Optional[datetime]:
    if not job_id:
        return None
    latest: Optional[datetime] = None
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
            ts = _parse_ts(row.get("ts"))
            if ts and (latest is None or ts > latest):
                latest = ts
    job_path = jobs_dir / f"{job_id}.json"
    if job_path.is_file():
        try:
            job = json.loads(job_path.read_text(encoding="utf-8"))
            ts = _parse_ts(job.get("created_at"))
            if ts and (latest is None or ts > latest):
                latest = ts
        except (OSError, json.JSONDecodeError):
            pass
    return latest


def _seconds_ago(ts: Optional[datetime], now: datetime) -> Optional[int]:
    if ts is None:
        return None
    return max(0, int((now - ts).total_seconds()))


def _format_ago(seconds: Optional[int]) -> str:
    if seconds is None:
        return ""
    if seconds < 60:
        return f"{seconds}s ago"
    if seconds < 3600:
        return f"{seconds // 60}m ago"
    return f"{seconds // 3600}h ago"


def _attention_rank(pill: str) -> int:
    order = {
        "needs-you": 0,
        "stalled": 1,
        "waiting-quota": 2,
        "held": 3,
        "running": 4,
        "admitted": 5,
        "queued": 6,
        "idle": 7,
        "done": 8,
    }
    return order.get(pill, 9)


def _attention_pill(status: str, stalled: bool) -> str:
    if stalled and status == "running":
        return "stalled"
    if status in _ATTENTION_STATUSES:
        return "needs-you"
    return status


def read_home_header(
    *,
    baton_home: Path,
    journal_path: Path,
    jobs_root: Path,
    runs_root: Path,
    now: Optional[datetime] = None,
) -> dict[str, Any]:
    clock = now or datetime.now(timezone.utc)
    if clock.tzinfo is None:
        clock = clock.replace(tzinfo=timezone.utc)
    grid = read_cockpit_grid(baton_home, runs_root)
    jobs_dir = maestro_root(baton_home)
    window = resolve_window(baton_home, now=clock)
    economics = economics_for_projects(
        journal_path=journal_path,
        baton_home=baton_home,
        jobs_root=jobs_root,
        now=clock,
    )
    quota = read_claude_quota(baton_home, now=clock)

    attention: list[dict[str, str]] = []
    total_window_tokens = 0
    total_savings = 0.0

    for cell in grid["cells"]:
        last_at = _last_job_activity(jobs_dir, cell.get("job_id"))
        ago = _seconds_ago(last_at, clock)
        stalled = cell.get("status") == "running" and ago is not None and ago > _STALL_SECONDS
        pill = _attention_pill(str(cell.get("status") or "idle"), stalled)
        if pill in {"needs-you", "stalled", "waiting-quota", "held"}:
            label = f"{cell.get('name')}: {pill.replace('-', ' ')}"
            attention.append({"project_id": cell["project_id"], "label": label, "pill": pill})

    for econ in economics.values():
        total_window_tokens += econ.get("total_tokens") or 0
        if econ.get("savings_usd"):
            total_savings += float(econ["savings_usd"])

    claude_label = quota.get("five_hour_label") or ""
    admitted = sum(1 for j in list_jobs(jobs_dir) if j.get("status") == "admitted")
    queued = sum(1 for j in list_jobs(jobs_dir) if j.get("status") == "queued")
    next_fire = ""
    if admitted:
        next_fire = f"{admitted} admitted — next tick fires"
    elif queued:
        next_fire = f"{queued} queued — admit on tick"

    return {
        "attention": attention,
        "attention_clean": len(attention) == 0,
        "capacity": {
            "claude_label": claude_label,
            "window_label": window.get("label") or "",
            "window_tokens_display": _fmt_tokens(total_window_tokens),
            "savings_display": f"Saved ${total_savings:.2f}" if total_savings > 0.01 else "",
            "next_fire": next_fire,
        },
    }


def read_home_floor(
    *,
    baton_home: Path,
    journal_path: Path,
    jobs_root: Path,
    runs_root: Path,
    now: Optional[datetime] = None,
) -> dict[str, Any]:
    clock = now or datetime.now(timezone.utc)
    if clock.tzinfo is None:
        clock = clock.replace(tzinfo=timezone.utc)
    grid = read_cockpit_grid(baton_home, runs_root)
    jobs_dir = maestro_root(baton_home)
    economics = economics_for_projects(
        journal_path=journal_path,
        baton_home=baton_home,
        jobs_root=jobs_root,
        now=clock,
    )

    cards: list[dict[str, Any]] = []
    for cell in grid["cells"]:
        pid = cell["project_id"]
        econ = economics.get(pid) or {}
        status = str(cell.get("status") or "idle")
        live = status in _LIVE_STATUSES or cell.get("live")
        has_tokens = (econ.get("total_tokens") or 0) > 0
        if not live and status in {"idle", "done"} and not has_tokens:
            continue

        last_at = _last_job_activity(jobs_dir, cell.get("job_id"))
        ago_sec = _seconds_ago(last_at, clock)
        stalled = status == "running" and ago_sec is not None and ago_sec > _STALL_SECONDS
        pill = _attention_pill(status, stalled)
        if stalled:
            pill = "stalled"

        cards.append({
            **cell,
            "goal": sanitize_goal(str(cell.get("goal") or "")),
            "attention_pill": pill,
            "recency_display": _format_ago(ago_sec),
            "economics": econ,
            "port_collapsed": True,
        })

    cards.sort(key=lambda c: (_attention_rank(c["attention_pill"]), c.get("name", "").lower()))
    return {"cards": cards, "live_count": sum(1 for c in cards if c.get("live"))}
