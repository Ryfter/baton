"""Gauges board — 5h project burn + real cap snapshots (no stubs)."""
from __future__ import annotations

import json
import re
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional
from zoneinfo import ZoneInfo

from dashboard.models.events import OtelEntry
from dashboard.readers.claude_quota import _label, _parse_dt, format_remaining, read_claude_quota
from dashboard.readers.journal import read_journal
from dashboard.readers.maestro_jobs import list_registry_projects, maestro_root

LOCAL_TZ = ZoneInfo("America/Boise")
WINDOW = timedelta(hours=5)
UNASSIGNED = "__unassigned__"
_MANIFEST_LINE_RE = re.compile(r'^([a-zA-Z_]+):\s*"?([^"]+?)"?\s*$')


def _ensure_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        text = f"{n / 1_000_000:.1f}M"
        return text.replace(".0M", "M")
    if n >= 1_000:
        return f"{round(n / 1_000)}k"
    return str(n)


def _fmt_cost(usd: float) -> str:
    return f"${usd:.2f}"


def _fmt_clock_time(dt: datetime) -> str:
    return _ensure_utc(dt).astimezone(LOCAL_TZ).strftime("%H:%M")


def _parse_manifest(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = _MANIFEST_LINE_RE.match(line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def _claude_window_end(baton_home: Path, now: datetime) -> Optional[datetime]:
    snap = baton_home / "claude-quota.json"
    if not snap.is_file():
        return None
    try:
        doc = json.loads(snap.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(doc, dict):
        return None
    five = doc.get("five_hour") or {}
    if five.get("resets_at") is None and five.get("resets_at_unix") is None:
        return None
    reset = _parse_dt(five.get("resets_at") or five.get("resets_at_unix"))
    if reset is None or reset <= now:
        return None
    return reset


def _read_claude_snapshot(baton_home: Path) -> dict[str, Any]:
    snap = baton_home / "claude-quota.json"
    if not snap.is_file():
        return {}
    try:
        doc = json.loads(snap.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(doc, dict):
        return {}
    return doc


def resolve_window(baton_home: Path, *, now: Optional[datetime] = None) -> dict[str, Any]:
    clock = _ensure_utc(now or datetime.now(timezone.utc))
    end = _claude_window_end(baton_home, clock)
    claude_clock = end is not None
    if end is None:
        end = clock
        start = clock - WINDOW
        label = "fallback — rolling 5h"
    else:
        start = end - WINDOW
        label = "5h window"
    return {
        "start": start,
        "end": end,
        "start_display": _fmt_clock_time(start),
        "end_display": _fmt_clock_time(end),
        "label": label,
        "is_claude_clock": claude_clock,
    }


def build_job_project_map(
    jobs_root: Path,
    maestro_jobs_root: Path,
) -> dict[str, str]:
    mapping: dict[str, str] = {}
    if maestro_jobs_root.is_dir():
        for path in maestro_jobs_root.glob("mj-*.json"):
            try:
                job = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            job_id = str(job.get("id") or "").strip()
            project = str(job.get("project") or "").strip()
            if job_id and project:
                mapping[job_id] = project
    if jobs_root.is_dir():
        for job_dir in jobs_root.iterdir():
            if not job_dir.is_dir():
                continue
            manifest = _parse_manifest(job_dir / "manifest.yaml")
            project = (manifest.get("project") or "").strip()
            job_id = (manifest.get("id") or job_dir.name).strip()
            if job_id and project:
                mapping[job_id] = project
    return mapping


def _in_window(ts: datetime, start: datetime, end: datetime) -> bool:
    ts = _ensure_utc(ts)
    start = _ensure_utc(start)
    end = _ensure_utc(end)
    return start < ts <= end


def fold_project_needles(
    journal_path: Path,
    window: dict[str, Any],
    job_projects: dict[str, str],
    registry_names: dict[str, str],
) -> tuple[list[dict[str, Any]], int, float]:
    entries = read_journal(journal_path)
    start = window["start"]
    end = window["end"]

    by_project: dict[str, dict[str, Any]] = {}
    model_tokens: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    total_tokens = 0
    total_cost = 0.0

    for entry in entries:
        if not isinstance(entry, OtelEntry):
            continue
        if not _in_window(entry.timestamp, start, end):
            continue
        tokens = entry.input_tokens + entry.output_tokens
        total_tokens += tokens
        total_cost += entry.cost_usd

        project_id = UNASSIGNED
        if entry.job_id and entry.job_id in job_projects:
            project_id = job_projects[entry.job_id]

        bucket = by_project.setdefault(
            project_id,
            {"tokens": 0, "cost_usd": 0.0},
        )
        bucket["tokens"] += tokens
        bucket["cost_usd"] += entry.cost_usd
        model_tokens[project_id][entry.model] += tokens

    needles: list[dict[str, Any]] = []
    for project_id, agg in by_project.items():
        if project_id == UNASSIGNED:
            name = "Unassigned"
        else:
            name = registry_names.get(project_id, project_id)
        tokens = agg["tokens"]
        share = (tokens / total_tokens) if total_tokens else 0.0
        models_sorted = sorted(
            model_tokens[project_id].items(),
            key=lambda item: item[1],
            reverse=True,
        )
        needles.append({
            "id": project_id,
            "name": name,
            "tokens": tokens,
            "tokens_display": _fmt_tokens(tokens),
            "cost_usd": round(agg["cost_usd"], 4),
            "cost_display": _fmt_cost(agg["cost_usd"]),
            "models": [m for m, _ in models_sorted],
            "share_pct": round(share * 100, 1),
            "share_fill": share,
        })
    needles.sort(key=lambda n: n["tokens"], reverse=True)
    return needles, total_tokens, round(total_cost, 4)


def _obs_label(obs: dict[str, Any], now: datetime) -> str:
    reset = _parse_dt(obs.get("reset_at"))
    used = obs.get("used_pct")
    if reset is not None:
        return _label(used, reset, now)
    scope = str(obs.get("scope") or "")
    if scope == "paid_credit":
        allowance = obs.get("allowance")
        consumed = obs.get("consumed")
        try:
            allow_f = float(allowance) if allowance is not None else None
            spent_f = float(consumed) if consumed is not None else None
        except (TypeError, ValueError):
            allow_f = spent_f = None
        if allow_f is not None and spent_f is not None:
            remaining = max(0.0, allow_f - spent_f)
            return f"${remaining:.2f} left"
    return ""


def _fresh_probe_observations(
    cache_path: Path,
    now: datetime,
) -> dict[tuple[str, str], dict[str, Any]]:
    if not cache_path.is_file():
        return {}
    out: dict[tuple[str, str], dict[str, Any]] = {}
    for line in cache_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(row, dict):
            continue
        worker = str(row.get("worker") or "")
        observed = _parse_dt(row.get("observed_at"))
        if observed is None:
            continue
        try:
            ttl = int(row.get("ttl") or 0)
        except (TypeError, ValueError):
            ttl = 0
        if ttl <= 0:
            continue
        if now >= observed + timedelta(seconds=ttl):
            continue
        observations = row.get("observations") or []
        if not isinstance(observations, list):
            continue
        for raw in observations:
            if not isinstance(raw, dict):
                continue
            scope = str(raw.get("scope") or "")
            if not scope:
                continue
            key = (worker, scope)
            prev = out.get(key)
            if prev is None or observed > prev.get("_observed_at", datetime.min.replace(tzinfo=timezone.utc)):
                out[key] = {**raw, "_observed_at": observed, "_worker": worker}
    return out


def _journal_prepaid(baton_home: Path, now: datetime) -> Optional[dict[str, Any]]:
    path = baton_home / "usage-journal.jsonl"
    if not path.is_file():
        return None
    latest: Optional[dict[str, Any]] = None
    latest_at = datetime.min.replace(tzinfo=timezone.utc)
    for line in path.read_text(encoding="utf-8").splitlines()[-400:]:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if str(row.get("scope") or "") != "paid_credit":
            continue
        worker = str(row.get("worker") or "")
        if "openrouter" not in worker.lower():
            continue
        ts = _parse_dt(row.get("ts") or row.get("observed_at"))
        if ts is None or ts > latest_at:
            if ts is not None:
                latest_at = ts
            latest = row
    return latest


def _cap_from_pct(title: str, cap_id: str, used_pct: Any, label: str) -> Optional[dict[str, Any]]:
    if not label:
        return None
    try:
        pct = float(used_pct) if used_pct is not None else None
    except (TypeError, ValueError):
        pct = None
    if pct is None:
        fill = 0.0
        pct_display = None
    else:
        pct = max(0.0, min(100.0, pct))
        fill = pct / 100.0
        pct_display = round(pct)
    return {
        "id": cap_id,
        "title": title,
        "used_pct": pct_display,
        "label": label,
        "fill": fill,
    }


def read_cap_gauges(baton_home: Path, *, now: Optional[datetime] = None) -> list[dict[str, Any]]:
    clock = _ensure_utc(now or datetime.now(timezone.utc))
    caps: list[dict[str, Any]] = []

    quota = read_claude_quota(baton_home, now=clock)
    snap = _read_claude_snapshot(baton_home)
    five = snap.get("five_hour") or {}
    week = snap.get("seven_day") or {}
    reset5 = _parse_dt(five.get("resets_at") or five.get("resets_at_unix"))
    reset7 = _parse_dt(week.get("resets_at") or week.get("resets_at_unix"))

    if quota.get("five_hour_label") and reset5 is not None and five.get("used_pct") is not None:
        cap = _cap_from_pct("Claude 5h", "claude_5h", five.get("used_pct"), quota["five_hour_label"])
        if cap:
            caps.append(cap)
    if quota.get("seven_day_label") and reset7 is not None and week.get("used_pct") is not None:
        cap = _cap_from_pct("Claude week", "claude_week", week.get("used_pct"), quota["seven_day_label"])
        if cap:
            caps.append(cap)

    probe_obs = _fresh_probe_observations(baton_home / "usage-probe-cache.jsonl", clock)

    codex_five = None
    codex_week = None
    for (worker, scope), obs in probe_obs.items():
        if "codex" not in worker.lower():
            continue
        if scope == "five_hour":
            codex_five = obs
        elif scope == "weekly":
            codex_week = obs

    if codex_five and _parse_dt(codex_five.get("reset_at")):
        label = _obs_label(codex_five, clock)
        cap = _cap_from_pct("Codex 5h", "codex_5h", codex_five.get("used_pct"), label)
        if cap:
            caps.append(cap)
    if codex_week and _parse_dt(codex_week.get("reset_at")):
        label = _obs_label(codex_week, clock)
        cap = _cap_from_pct("Codex week", "codex_week", codex_week.get("used_pct"), label)
        if cap:
            caps.append(cap)

    or_obs = None
    for (worker, scope), obs in probe_obs.items():
        if scope != "paid_credit":
            continue
        if "openrouter" in worker.lower():
            or_obs = obs
            break
    if or_obs is None:
        journal_row = _journal_prepaid(baton_home, clock)
        if journal_row:
            or_obs = journal_row

    if or_obs:
        label = _obs_label(or_obs, clock)
        if label and (or_obs.get("allowance") is not None or or_obs.get("used_pct") is not None):
            cap = _cap_from_pct("OpenRouter", "openrouter", or_obs.get("used_pct"), label)
            if cap:
                caps.append(cap)

    return caps


def read_gauges(
    *,
    journal_path: Path,
    baton_home: Path,
    jobs_root: Path,
    maestro_jobs_root: Optional[Path] = None,
    now: Optional[datetime] = None,
) -> dict[str, Any]:
    clock = _ensure_utc(now or datetime.now(timezone.utc))
    window = resolve_window(baton_home, now=clock)
    mroot = maestro_jobs_root or maestro_root(baton_home)
    job_projects = build_job_project_map(jobs_root, mroot)
    registry = {p["id"]: p["name"] for p in list_registry_projects(baton_home)}

    projects, total_tokens, total_cost = fold_project_needles(
        journal_path,
        window,
        job_projects,
        registry,
    )
    caps = read_cap_gauges(baton_home, now=clock)

    empty_message = ""
    if not projects:
        empty_message = "No token lines in this window."

    return {
        "schema": 1,
        "clock": {
            **window,
            "total_tokens": total_tokens,
            "total_tokens_display": _fmt_tokens(total_tokens),
            "total_cost_usd": total_cost,
            "total_cost_display": _fmt_cost(total_cost),
        },
        "projects": projects,
        "caps": caps,
        "empty_message": empty_message,
    }
