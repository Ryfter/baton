"""Tests for cockpit grid reader + HTTP/WebSocket routes (Maestro slice 4)."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.readers import maestro_jobs as mj
from dashboard.readers.cockpit_grid import read_cockpit_grid
from dashboard.routers.cockpit import build_router


def _seed_registry(home: Path, project_id: str = "baton", name: str = "Baton") -> None:
    d = home / "projects" / project_id
    d.mkdir(parents=True)
    (d / "project.json").write_text(
        json.dumps({"id": project_id, "name": name, "folder": "/tmp"}),
        encoding="utf-8",
    )


def _seed_run(runs_root: Path, run_id: str, project: str, status: str = "running") -> None:
    run_dir = runs_root / run_id
    run_dir.mkdir(parents=True)
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    (run_dir / "run.json").write_text(
        json.dumps(
            {
                "id": run_id,
                "name": "orch-1",
                "model": "ox-alpha",
                "status": status,
                "project": project,
                "current_step": "implement slice 4",
                "updated_at": now,
            }
        ),
        encoding="utf-8",
    )
    (run_dir / "events.jsonl").write_text(
        json.dumps({"ts": now, "kind": "action", "what": "opened PR"}) + "\n",
        encoding="utf-8",
    )


def test_read_cockpit_grid_merges_job_and_run(tmp_path: Path):
    home = tmp_path
    _seed_registry(home, "baton")
    _seed_registry(home, "canvas", "Canvas Toolchain")
    jobs_root = mj.maestro_root(home)
    job = mj.create_job(jobs_root, project="baton", goal="ship cockpit grid hero")
    mj.update_job_fields(jobs_root, job["id"], status="running", provider="openrouter-ox-alpha")
    runs_root = home / "runs"
    _seed_run(runs_root, "run-2026-08-22-a", "baton")

    grid = read_cockpit_grid(home, runs_root)
    assert grid["schema"] == 1
    assert grid["live_count"] >= 1
    by_id = {c["project_id"]: c for c in grid["cells"]}
    assert "baton" in by_id
    assert "canvas" in by_id
    baton = by_id["baton"]
    assert baton["status"] == "running"
    assert baton["live"] is True
    assert baton["job_id"] == job["id"]
    assert baton["run_id"] == "run-2026-08-22-a"
    assert "ship cockpit" in baton["goal"]
    assert any("action" in line for line in baton["tail"])
    assert by_id["canvas"]["status"] == "idle"


def test_cockpit_http_and_ws(tmp_path: Path):
    templates = Jinja2Templates(
        directory=str(Path(__file__).resolve().parents[1] / "templates")
    )
    _seed_registry(tmp_path)
    app = FastAPI()
    app.state.baton_home = tmp_path
    app.state.runs_root = tmp_path / "runs"
    app.include_router(build_router(templates))
    client = TestClient(app)

    partial = client.get("/partials/cockpit-grid")
    assert partial.status_code == 200
    assert "cockpit-grid" in partial.text
    assert "Baton" in partial.text

    api = client.get("/api/cockpit-grid")
    assert api.status_code == 200
    body = api.json()
    assert body["schema"] == 1
    assert isinstance(body["cells"], list)

    with client.websocket_connect("/ws/cockpit") as ws:
        msg = ws.receive_json()
        assert msg.get("schema") == 1
        assert "cells" in msg or msg.get("heartbeat") is True
