"""Claude 5h / 7d remaining — from a statusline snapshot, never a 5h stub.

Claude Code already has rate_limits.five_hour.resets_at on every statusline
tick. statusline.sh writes $BATON_HOME/claude-quota.json. This reader turns
that (or a still-future usage-journal reset) into "resets in 47m".
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


def _parse_dt(value: Any) -> Optional[datetime]:
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        ts = float(value)
        if ts > 1e12:
            ts = ts / 1000.0
        return datetime.fromtimestamp(ts, tz=timezone.utc)
    text = str(value).strip()
    if text.isdigit():
        return _parse_dt(int(text))
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def format_remaining(reset_at: datetime, now: datetime) -> str:
    if reset_at.tzinfo is None:
        reset_at = reset_at.replace(tzinfo=timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    seconds = int((reset_at - now).total_seconds())
    if seconds <= 0:
        return "reset"
    minutes = seconds // 60
    hours = minutes // 60
    mins = minutes % 60
    if hours <= 0:
        return "<1m" if mins <= 0 else f"{mins}m"
    if mins == 0:
        return f"{hours}h"
    return f"{hours}h {mins}m"


def _label(used_pct: Any, reset_at: Optional[datetime], now: datetime) -> str:
    if reset_at is None:
        return ""
    remain = format_remaining(reset_at, now)
    if remain == "reset":
        return "open"
    try:
        pct = float(used_pct) if used_pct is not None and used_pct != "" else None
    except (TypeError, ValueError):
        pct = None
    if pct is None:
        return f"resets in {remain}"
    if pct >= 99:
        return f"empty · resets in {remain}"
    return f"{pct:.0f}% · resets in {remain}"


def _from_snapshot(path: Path, now: datetime) -> dict[str, Any]:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(doc, dict):
        return {}
    five = doc.get("five_hour") or {}
    week = doc.get("seven_day") or {}
    reset5 = _parse_dt(five.get("resets_at") or five.get("resets_at_unix"))
    reset7 = _parse_dt(week.get("resets_at") or week.get("resets_at_unix"))
    return {
        "five_hour_label": _label(five.get("used_pct"), reset5, now),
        "seven_day_label": _label(week.get("used_pct"), reset7, now),
        "five_hour_reset": reset5,
        "seven_day_reset": reset7,
    }


def _from_usage_journal(path: Path, now: datetime) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    latest: Optional[dict[str, Any]] = None
    for line in lines[-400:]:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        worker = str(row.get("worker") or "")
        if worker not in {"claude-cli", "claude-sonnet", "claude-haiku", "claude"}:
            continue
        reset = _parse_dt(row.get("reset_at"))
        if reset is None or reset <= now:
            continue
        latest = row
        latest["_reset"] = reset
    if not latest:
        return {}
    return {
        "five_hour_label": _label(latest.get("used_pct"), latest["_reset"], now),
        "seven_day_label": "",
        "five_hour_reset": latest["_reset"],
        "seven_day_reset": None,
    }


def read_claude_quota(baton_home: Path, *, now: Optional[datetime] = None) -> dict[str, Any]:
    clock = now or datetime.now(timezone.utc)
    if clock.tzinfo is None:
        clock = clock.replace(tzinfo=timezone.utc)
    empty = {
        "five_hour_label": "",
        "seven_day_label": "",
        "five_hour_reset": None,
        "seven_day_reset": None,
    }
    snap = baton_home / "claude-quota.json"
    if snap.is_file():
        got = _from_snapshot(snap, clock)
        if got.get("five_hour_label"):
            return {**empty, **got}
    journal = _from_usage_journal(baton_home / "usage-journal.jsonl", clock)
    if journal.get("five_hour_label"):
        return {**empty, **journal}
    return empty
