"""Maestro job store — $BATON_HOME/maestro/jobs/<id>.json + events.jsonl.

Slice 1 of docs/superpowers/specs/2026-08-15-maestro-front-door-design.md §5.
Admission math stays stubbed (queued → admitted); Conductor fire is later.
"""
from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Optional

VALID_STATUSES = frozenset(
    {"queued", "admitted", "running", "waiting-quota", "held", "done"}
)
VALID_STAKES = frozenset({"low", "standard", "high"})
VALID_MISSED = frozenset({"catch-up", "skip", "coalesce"})
VALID_SOURCES = frozenset({"cli", "buzz", "web"})
JOB_ID_RE = re.compile(r"^mj-[0-9a-f]{12}$")


def maestro_root(baton_home: Path) -> Path:
    return baton_home / "maestro" / "jobs"


def projects_root(baton_home: Path) -> Path:
    return baton_home / "projects"


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def assert_job_id(job_id: str) -> str:
    """Reject path traversal / non-opaque ids before any filesystem join."""
    if not job_id or not JOB_ID_RE.match(job_id):
        raise ValueError(f"invalid job id: {job_id!r}")
    return job_id


def _job_path(root: Path, job_id: str) -> Path:
    safe = assert_job_id(job_id)
    path = (root / f"{safe}.json").resolve()
    root_resolved = root.resolve()
    if root_resolved not in path.parents and path.parent != root_resolved:
        raise ValueError("job path escaped maestro root")
    return path


def _events_path(root: Path) -> Path:
    return root / "events.jsonl"


def list_registry_projects(baton_home: Path) -> list[dict[str, str]]:
    """`$BATON_HOME/projects/<id>/project.json` — Maestro registry, not KB."""
    root = projects_root(baton_home)
    if not root.is_dir():
        return []
    out: list[dict[str, str]] = []
    for d in sorted(root.iterdir()):
        if not d.is_dir():
            continue
        rec_path = d / "project.json"
        name = d.name
        if rec_path.is_file():
            try:
                rec = json.loads(rec_path.read_text(encoding="utf-8"))
                name = str(rec.get("name") or rec.get("id") or d.name)
            except (OSError, json.JSONDecodeError):
                pass
        out.append({"id": d.name, "name": name})
    return out


def project_in_registry(baton_home: Path, project_id: str) -> bool:
    project_id = (project_id or "").strip()
    if not project_id or "/" in project_id or "\\" in project_id or ".." in project_id:
        return False
    return (projects_root(baton_home) / project_id / "project.json").is_file()


def append_event(root: Path, job_id: str, kind: str, **extra: Any) -> None:
    root.mkdir(parents=True, exist_ok=True)
    row = {"ts": _now_iso(), "job_id": job_id, "kind": kind, **extra}
    with _events_path(root).open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def create_job(
    root: Path,
    *,
    project: str,
    goal: str,
    stakes: str = "standard",
    missed_fire: str = "catch-up",
    source: str = "web",
    status: str = "admitted",
    provider: Optional[str] = None,
) -> dict[str, Any]:
    project = (project or "").strip()
    goal = (goal or "").strip()
    if not project:
        raise ValueError("project is required")
    if not goal:
        raise ValueError("goal is required")
    stakes = (stakes or "standard").strip().lower()
    if stakes not in VALID_STAKES:
        raise ValueError(f"invalid stakes: {stakes}")
    missed_fire = (missed_fire or "catch-up").strip().lower()
    if missed_fire not in VALID_MISSED:
        raise ValueError(f"invalid missed_fire: {missed_fire}")
    source = (source or "web").strip().lower()
    if source not in VALID_SOURCES:
        raise ValueError(f"invalid source: {source}")
    status = (status or "admitted").strip().lower()
    if status not in VALID_STATUSES:
        raise ValueError(f"invalid status: {status}")

    root.mkdir(parents=True, exist_ok=True)
    job_id = f"mj-{uuid.uuid4().hex[:12]}"
    job: dict[str, Any] = {
        "id": job_id,
        "project": project,
        "goal": goal,
        "stakes": stakes,
        "missed_fire": missed_fire,
        "source": source,
        "status": status,
        "run_id": None,
        "provider": provider,
        "created_at": _now_iso(),
    }
    _job_path(root, job_id).write_text(
        json.dumps(job, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    append_event(root, job_id, "created", status=status, project=project, source=source)
    return job


def read_job(root: Path, job_id: str) -> dict[str, Any]:
    path = _job_path(root, job_id)
    if not path.is_file():
        raise FileNotFoundError(job_id)
    return json.loads(path.read_text(encoding="utf-8"))


def write_job(root: Path, job: dict[str, Any]) -> dict[str, Any]:
    job_id = assert_job_id(job["id"])
    root.mkdir(parents=True, exist_ok=True)
    _job_path(root, job_id).write_text(
        json.dumps(job, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return job


def list_jobs(root: Path) -> list[dict[str, Any]]:
    if not root.is_dir():
        return []
    jobs: list[dict[str, Any]] = []
    for path in root.glob("mj-*.json"):
        try:
            jobs.append(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
    jobs.sort(key=lambda j: j.get("created_at") or "", reverse=True)
    return jobs


def update_job_fields(
    root: Path,
    job_id: str,
    *,
    status: Optional[str] = None,
    run_id: Optional[str] = None,
    provider: Optional[str] = None,
    **extra: Any,
) -> dict[str, Any]:
    """Patch whitelisted job fields after Conductor fire (maestro-fire.ps1)."""
    job = read_job(root, job_id)
    event_extra: dict[str, Any] = {}
    if status is not None:
        status = status.strip().lower()
        if status not in VALID_STATUSES:
            raise ValueError(f"invalid status: {status}")
        event_extra["status"] = status
        job["status"] = status
    if run_id is not None:
        event_extra["run_id"] = run_id
        job["run_id"] = run_id
    if provider is not None:
        event_extra["provider"] = provider
        job["provider"] = provider
    for key, value in extra.items():
        job[key] = value
        event_extra[key] = value
    write_job(root, job)
    append_event(root, job_id, "updated", **event_extra)
    return job


def hold_job(root: Path, job_id: str) -> dict[str, Any]:
    job = read_job(root, job_id)
    prev = job.get("status")
    job["status"] = "held"
    write_job(root, job)
    append_event(root, job_id, "hold", previous_status=prev)
    return job


def budget_stub(usable: Optional[Iterable[str]] = None) -> dict[str, Any]:
    """Slice-1 budget placeholder — real meters land with Maestro admission."""
    names = list(usable) if usable is not None else [
        "openrouter-ox-alpha",
        "codex",
        "grok-cli",
        "kiro",
        "cursor-agent",
    ]
    return {
        "schema": 1,
        "note": "stub — wire window-budget-lib / CodexBar later",
        "usable": names,
        "held_projects": [],
        "claude_5h": "empty-until-reset",
        "claude_7d": "unknown",
    }
