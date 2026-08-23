"""Dark factory status — Maestro lanes, security cadence, Grimdex-edu curriculum."""
from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Optional

from dashboard.readers.maestro_jobs import list_jobs, maestro_root


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _status_via_powershell(baton_home: Path) -> dict[str, Any]:
    script = _repo_root() / "scripts" / "fleet-dark-factory.ps1"
    if not script.is_file():
        return _status_fallback(baton_home)
    env = os.environ.copy()
    env["BATON_HOME"] = str(baton_home)
    try:
        proc = subprocess.run(
            [
                os.environ.get("PWSH", "pwsh"),
                "-NoProfile",
                "-File",
                str(script),
                "-Action",
                "status",
                "-Json",
            ],
            capture_output=True,
            text=True,
            timeout=45,
            env=env,
            check=False,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return _status_fallback(baton_home)
        return json.loads(proc.stdout)
    except (json.JSONDecodeError, subprocess.TimeoutExpired, OSError):
        return _status_fallback(baton_home)


def _status_fallback(baton_home: Path) -> dict[str, Any]:
    jobs = list_jobs(maestro_root(baton_home))
    by_status: dict[str, int] = {}
    for job in jobs:
        st = str(job.get("status") or "unknown")
        by_status[st] = by_status.get(st, 0) + 1
    df = [
        j
        for j in jobs
        if "dark-factory" in str(j.get("goal", "")).lower()
        or (isinstance(j.get("tags"), list) and "dark-factory" in j.get("tags", []))
    ]
    return {
        "schema_version": 1,
        "jobs_total": len(jobs),
        "jobs_by_status": by_status,
        "dark_factory": df[:8],
        "security_due": [],
        "security_count": 0,
        "curriculum": {"shipped": 0, "pending": 0, "modules": []},
        "lanes": ["dashboard", "baton-spine", "grimdex-edu-curriculum"],
    }


def read_dark_factory_board(baton_home: Path) -> dict[str, Any]:
    board = _status_via_powershell(baton_home)
    jobs_by_status = board.get("jobs_by_status") or {}
    curriculum = board.get("curriculum") or {}
    modules = curriculum.get("modules") or []
    if isinstance(modules, list):
        module_rows = modules
    else:
        module_rows = []
    return {
        "jobs_total": int(board.get("jobs_total") or 0),
        "queued": int(jobs_by_status.get("queued") or 0),
        "admitted": int(jobs_by_status.get("admitted") or 0),
        "running": int(jobs_by_status.get("running") or 0),
        "waiting": int(jobs_by_status.get("waiting-quota") or 0),
        "dark_factory_jobs": board.get("dark_factory") or [],
        "security_due": board.get("security_due") or [],
        "security_count": int(board.get("security_count") or 0),
        "curriculum_shipped": int(curriculum.get("shipped") or 0),
        "curriculum_pending": int(curriculum.get("pending") or 0),
        "curriculum_modules": module_rows,
        "lanes": board.get("lanes") or [],
    }


def grimdex_edu_root(baton_home: Path) -> Optional[Path]:
    env = os.environ.get("GRIMDEX_EDU_ROOT", "").strip()
    if env:
        p = Path(env).expanduser()
        if p.is_dir():
            return p
    rec = baton_home / "projects" / "grimdex-edu" / "project.json"
    if rec.is_file():
        try:
            doc = json.loads(rec.read_text(encoding="utf-8"))
            folder = str(doc.get("folder") or "").strip()
            if folder and Path(folder).is_dir():
                return Path(folder)
        except (OSError, json.JSONDecodeError):
            pass
    default = Path("/Users/kev/Dev/Grimdex-edu")
    return default if default.is_dir() else None
