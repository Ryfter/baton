"""Pane-truth — detect needs-permission beyond Maestro status JSON."""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from dashboard.readers.maestro_jobs import maestro_root

_PERMISSION_KINDS = frozenset({
    "permission",
    "needs-permission",
    "needs_permission",
    "user-input",
    "user_input",
    "approval",
    "approve",
    "blocked-permission",
})
_PERMISSION_TEXT = re.compile(
    r"\b(needs?\s+(your\s+)?permission|waiting\s+(on|for)\s+(you|approval|input)|"
    r"approve\s+this|permission\s+denied|user\s+input\s+required)\b",
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


def _read_pane_truth_sidecar(baton_home: Path) -> list[dict[str, Any]]:
    path = baton_home / "observability" / "pane-truth.json"
    if not path.is_file():
        return []
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    rows = doc if isinstance(doc, list) else doc.get("items") or doc.get("permissions") or []
    out: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        if not row.get("project_id") and not row.get("project"):
            continue
        out.append(row)
    return out


def _scan_maestro_events(
    jobs_dir: Path,
    *,
    project_id: str,
    job_id: Optional[str],
    now: datetime,
    max_age_sec: int = 7200,
) -> Optional[dict[str, str]]:
    if not job_id:
        return None
    events_path = jobs_dir / "events.jsonl"
    if not events_path.is_file():
        return None
    try:
        lines = events_path.read_text(encoding="utf-8").splitlines()[-200:]
    except OSError:
        return None

    for line in reversed(lines):
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
        if ts and (now - ts).total_seconds() > max_age_sec:
            continue
        kind = str(row.get("kind") or "").lower()
        text = " ".join(
            str(row.get(k) or "")
            for k in ("what", "message", "text", "reason", "detail")
        ).strip()
        if kind in _PERMISSION_KINDS or _PERMISSION_TEXT.search(text):
            label = text or kind.replace("-", " ")
            return {
                "project_id": project_id,
                "label": label[:120],
                "pill": "needs-you",
                "kind": "permission",
                "source": "events",
            }
    return None


def permission_attention_items(
    *,
    baton_home: Path,
    project_id: str,
    project_name: str,
    job_id: Optional[str] = None,
    job_status: Optional[str] = None,
    now: Optional[datetime] = None,
) -> list[dict[str, str]]:
    """Return attention-rail rows when an agent needs human permission."""
    clock = now or datetime.now(timezone.utc)
    if clock.tzinfo is None:
        clock = clock.replace(tzinfo=timezone.utc)
    jobs_dir = maestro_root(baton_home)
    items: list[dict[str, str]] = []

    if job_status in {"needs-you", "held"}:
        items.append({
            "project_id": project_id,
            "label": f"{project_name}: needs permission",
            "pill": "needs-you",
            "kind": "permission",
            "source": "status",
        })

    hit = _scan_maestro_events(
        jobs_dir, project_id=project_id, job_id=job_id, now=clock,
    )
    if hit:
        hit["label"] = f"{project_name}: {hit['label']}"
        items.append(hit)

    for row in _read_pane_truth_sidecar(baton_home):
        pid = str(row.get("project_id") or row.get("project") or "")
        if pid != project_id:
            continue
        msg = str(row.get("message") or row.get("label") or row.get("reason") or "needs permission")
        items.append({
            "project_id": project_id,
            "label": f"{project_name}: {msg[:100]}",
            "pill": "needs-you",
            "kind": "permission",
            "source": "pane-truth",
        })

    return items
