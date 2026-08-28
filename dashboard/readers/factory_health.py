"""Factory health alerts — loop + regression signals for Gauges banner (Siddique pattern)."""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from dashboard.readers.agent_observability import observability_attention_items
from dashboard.readers.cockpit_grid import read_cockpit_grid
from dashboard.readers.maestro_jobs import list_registry_projects, maestro_root


def read_factory_health_alerts(
    *,
    baton_home: Path,
    runs_root: Path,
    now: Optional[datetime] = None,
) -> dict[str, Any]:
    """Aggregate per-project loop/regression/blocked signals for the Gauges banner."""
    clock = now or datetime.now(timezone.utc)
    if clock.tzinfo is None:
        clock = clock.replace(tzinfo=timezone.utc)
    jobs_dir = maestro_root(baton_home)
    grid = read_cockpit_grid(baton_home, runs_root)
    active = {
        str(c["project_id"]): c
        for c in grid["cells"]
        if str(c.get("status") or "") in {"running", "admitted", "queued", "waiting-quota", "held"}
    }
    registry = {p["id"]: p.get("name") or p["id"] for p in list_registry_projects(baton_home)}

    loops: list[dict[str, str]] = []
    regressions: list[dict[str, str]] = []
    blocked: list[dict[str, str]] = []

    for pid, cell in active.items():
        name = str(cell.get("name") or registry.get(pid) or pid)
        for item in observability_attention_items(
            baton_home=baton_home,
            project_id=pid,
            project_name=name,
            jobs_dir=jobs_dir,
            job_id=cell.get("job_id"),
            now=clock,
        ):
            kind = str(item.get("kind") or "")
            row = {
                "project_id": pid,
                "project_name": name,
                "label": str(item.get("label") or name),
                "kind": kind,
            }
            if kind == "trajectory":
                loops.append(row)
            elif kind == "regression":
                regressions.append(row)
            elif kind == "blocked":
                blocked.append(row)

    has_alerts = bool(loops or regressions or blocked)
    parts: list[str] = []
    if loops:
        parts.append(f"{len(loops)} loop{'s' if len(loops) != 1 else ''}")
    if regressions:
        parts.append(f"{len(regressions)} regression{'s' if len(regressions) != 1 else ''}")
    if blocked:
        parts.append(f"{len(blocked)} blocked")
    summary = " · ".join(parts) if parts else ""

    return {
        "loops": loops[:6],
        "regressions": regressions[:6],
        "blocked": blocked[:6],
        "has_alerts": has_alerts,
        "summary": summary,
    }
