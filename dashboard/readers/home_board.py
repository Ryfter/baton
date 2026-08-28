"""Home shift board — attention rail, capacity strip, project cards."""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from dashboard.readers.agent_observability import (
    observability_attention_items,
    observability_for_project,
)
from dashboard.readers.claude_quota import read_claude_quota
from dashboard.readers.cockpit_grid import read_cockpit_grid
from dashboard.readers.display_goal import sanitize_goal
from dashboard.readers.gauges import _fmt_tokens, resolve_window
from dashboard.readers.maestro_jobs import list_jobs, maestro_root
from dashboard.readers.pane_truth import permission_attention_items
from dashboard.readers.project_economics import economics_for_projects

_ATTENTION_STATUSES = frozenset({"waiting-quota", "held"})
_LIVE_STATUSES = frozenset({"running", "admitted", "queued", "waiting-quota", "held"})
_STALL_SECONDS = 300
_STALE_SECONDS = 43200  # 12h — backlog from yesterday, not a live lockup
_LIFECYCLE_RE = re.compile(
    r"^(created|admitted|queued|running|held|waiting-quota|done)\s*[·•]\s*",
    re.IGNORECASE,
)


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
        "stale": 7,
        "idle": 8,
        "done": 9,
    }
    return order.get(pill, 10)


def _resolve_pill(status: str, ago_sec: Optional[int]) -> str:
    if status == "running":
        if ago_sec is not None and ago_sec > _STALE_SECONDS:
            return "stale"
        if ago_sec is not None and ago_sec > _STALL_SECONDS:
            return "stalled"
    if status in _ATTENTION_STATUSES:
        if ago_sec is not None and ago_sec > _STALE_SECONDS and status in {"held"}:
            return "stale"
        return "needs-you"
    return status


def _classify_activity(cell: dict[str, Any], last_output: str) -> dict[str, str]:
    turns = cell.get("turns") or []
    has_stdout = any(str(t.get("kind") or "") == "output" for t in turns)
    text = " ".join((last_output or "").split())
    if has_stdout and text:
        return {"kind": "stdout", "text": text}
    if text and (_LIFECYCLE_RE.match(text) or not has_stdout):
        status = str(cell.get("status") or "idle").replace("-", " ")
        return {"kind": "lifecycle", "text": text, "status_label": status.title()}
    if text:
        return {"kind": "stdout", "text": text}
    status = str(cell.get("status") or "idle").replace("-", " ")
    return {"kind": "lifecycle", "text": "", "status_label": status.title()}


def _dedupe_attention(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    """Collapse duplicate rail rows by project_id + kind/pill + label."""
    seen: set[tuple[str, str, str]] = set()
    out: list[dict[str, str]] = []
    for row in rows:
        key = (
            str(row.get("project_id") or ""),
            str(row.get("kind") or row.get("pill") or ""),
            str(row.get("label") or ""),
        )
        if key in seen:
            continue
        seen.add(key)
        out.append(row)
    return out


def _format_window_label(raw: str) -> str:
    label = (raw or "").strip()
    if not label:
        return "Rolling 5h window"
    if label.lower().startswith("fallback"):
        return "Rolling 5h window"
    return label


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
    stale_count = 0
    total_window_tokens = 0
    total_savings = 0.0

    for cell in grid["cells"]:
        last_at = _last_job_activity(jobs_dir, cell.get("job_id"))
        ago = _seconds_ago(last_at, clock)
        pill = _resolve_pill(str(cell.get("status") or "idle"), ago)
        if pill == "stale":
            stale_count += 1
            continue
        if pill in {"needs-you", "stalled", "waiting-quota", "held"}:
            label = f"{cell.get('name')}: {pill.replace('-', ' ')}"
            attention.append({"project_id": cell["project_id"], "label": label, "pill": pill})

        attention.extend(
            permission_attention_items(
                baton_home=baton_home,
                project_id=cell["project_id"],
                project_name=str(cell.get("name") or cell["project_id"]),
                job_id=cell.get("job_id"),
                job_status=str(cell.get("status") or ""),
                now=clock,
            )
        )

        if cell.get("status") in {"running", "admitted"}:
            attention.extend(
                observability_attention_items(
                    baton_home=baton_home,
                    project_id=cell["project_id"],
                    project_name=str(cell.get("name") or cell["project_id"]),
                    jobs_dir=jobs_dir,
                    job_id=cell.get("job_id"),
                    now=clock,
                )
            )

    for econ in economics.values():
        total_window_tokens += econ.get("total_tokens") or 0
        if econ.get("savings_usd"):
            total_savings += float(econ["savings_usd"])

    attention = _dedupe_attention(attention)

    claude_label = quota.get("five_hour_label") or "open"
    admitted = sum(1 for j in list_jobs(jobs_dir) if j.get("status") == "admitted")
    queued = sum(1 for j in list_jobs(jobs_dir) if j.get("status") == "queued")
    next_fire = ""
    if admitted:
        next_fire = f"{admitted} admitted"
    elif queued:
        next_fire = f"{queued} queued"

    return {
        "attention": attention,
        "attention_clean": len(attention) == 0 and stale_count == 0,
        "stale_count": stale_count,
        "capacity": {
            "claude_label": claude_label,
            "window_label": _format_window_label(str(window.get("label") or "")),
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
        pill = _resolve_pill(status, ago_sec)
        activity = _classify_activity(cell, str(cell.get("last_output") or ""))

        obs = observability_for_project(
            baton_home=baton_home,
            project_id=pid,
            jobs_dir=jobs_dir,
            job_id=cell.get("job_id"),
            now=clock,
        )
        if obs.get("trajectory", {}).get("needs_attention"):
            pill = "needs-you"

        cards.append({
            **cell,
            "goal": sanitize_goal(str(cell.get("goal") or "")),
            "attention_pill": pill,
            "recency_display": _format_ago(ago_sec),
            "activity_kind": activity["kind"],
            "activity_text": activity.get("text") or "",
            "activity_status": activity.get("status_label") or "",
            "economics": econ,
            "port_collapsed": True,
            "observability": obs,
        })

    cards.sort(key=lambda c: (_attention_rank(c["attention_pill"]), c.get("name", "").lower()))
    return {"cards": cards, "live_count": sum(1 for c in cards if c.get("live"))}
