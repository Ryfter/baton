"""Tests for Maestro job store + HTTP routes (front-door slice 1)."""
from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.readers import maestro_jobs as mj
from dashboard.routers.maestro import build_router


def _seed_registry(home: Path, project_id: str = "baton") -> None:
    d = home / "projects" / project_id
    d.mkdir(parents=True)
    (d / "project.json").write_text(
        '{"id":"%s","name":"Baton","folder":"/tmp"}\n' % project_id,
        encoding="utf-8",
    )


def test_create_list_hold(tmp_path: Path):
    root = tmp_path / "maestro" / "jobs"
    job = mj.create_job(root, project="baton", goal="ship slice 1", stakes="standard")
    assert job["id"].startswith("mj-")
    assert job["status"] == "queued"
    assert job["source"] == "web"
    listed = mj.list_jobs(root)
    assert len(listed) == 1
    held = mj.hold_job(root, job["id"])
    assert held["status"] == "held"
    events = (root / "events.jsonl").read_text(encoding="utf-8").strip().splitlines()
    assert len(events) == 2


def test_update_job_fields(tmp_path: Path):
    root = tmp_path / "maestro" / "jobs"
    job = mj.create_job(root, project="baton", goal="fire me", stakes="high")
    updated = mj.update_job_fields(
        root,
        job["id"],
        status="running",
        run_id="run-2026-08-21-abc",
        provider="openrouter-ox-alpha",
    )
    assert updated["status"] == "running"
    assert updated["run_id"] == "run-2026-08-21-abc"
    assert updated["provider"] == "openrouter-ox-alpha"
    events = (root / "events.jsonl").read_text(encoding="utf-8").strip().splitlines()
    assert "updated" in events[-1]
    assert "openrouter-ox-alpha" in events[-1]


def test_create_rejects_empty_goal(tmp_path: Path):
    root = tmp_path / "jobs"
    try:
        mj.create_job(root, project="baton", goal="  ")
        assert False, "expected ValueError"
    except ValueError as exc:
        assert "goal" in str(exc)


def test_job_id_rejects_traversal(tmp_path: Path):
    root = tmp_path / "maestro" / "jobs"
    root.mkdir(parents=True)
    try:
        mj.read_job(root, "../../etc/passwd")
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_release_job(tmp_path: Path):
    root = tmp_path / "maestro" / "jobs"
    job = mj.create_job(root, project="baton", goal="hold me")
    held = mj.hold_job(root, job["id"])
    assert held["status"] == "held"
    assert held.get("held_from") == "queued"
    released = mj.release_job(root, job["id"])
    assert released["status"] == "queued"
    try:
        mj.release_job(root, job["id"])
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_board_status(tmp_path: Path):
    root = tmp_path / "maestro" / "jobs"
    mj.create_job(root, project="baton", goal="one")
    mj.create_job(root, project="baton", goal="two")
    board = mj.board_status(root)
    assert board["counts"]["queued"] == 2
    assert "status_line" in board


def test_registry_list(tmp_path: Path):
    _seed_registry(tmp_path)
    projects = mj.list_registry_projects(tmp_path)
    assert projects == [{"id": "baton", "name": "Baton"}]
    assert mj.project_in_registry(tmp_path, "baton")
    assert not mj.project_in_registry(tmp_path, "nope")


def test_maestro_http_create_and_list(tmp_path: Path):
    templates = Jinja2Templates(
        directory=str(Path(__file__).resolve().parents[1] / "templates")
    )
    _seed_registry(tmp_path)
    app = FastAPI()
    app.state.baton_home = tmp_path
    app.state.maestro_jobs_root = tmp_path / "maestro" / "jobs"
    app.include_router(build_router(templates))
    client = TestClient(app)

    bad = client.post(
        "/maestro/jobs",
        data={"project": "unknown", "goal": "x", "stakes": "standard", "source": "web"},
        headers={"Accept": "application/json"},
    )
    assert bad.status_code == 400
    assert "unknown project" in bad.json()["detail"]

    hx_bad = client.post(
        "/maestro/jobs",
        data={"project": "unknown", "goal": "x", "stakes": "standard", "source": "web"},
        headers={"HX-Request": "true"},
    )
    assert hx_bad.status_code == 400
    assert "text/html" in hx_bad.headers["content-type"]
    assert "unknown project" in hx_bad.text
    assert "role=\"alert\"" in hx_bad.text

    compose = client.get("/maestro/partials/compose")
    assert compose.status_code == 200
    assert 'for="maestro-project"' in compose.text
    assert 'id="maestro-project"' in compose.text
    assert 'hx-disabled-elt="#maestro-start"' in compose.text

    r = client.post(
        "/maestro/jobs",
        data={"project": "baton", "goal": "paste a long dump", "stakes": "high", "source": "web"},
        headers={"Accept": "application/json"},
    )
    assert r.status_code in (200, 201)
    body = r.json()
    assert body["project"] == "baton"
    assert body["stakes"] == "high"
    assert body["status"] == "queued"

    status_board = client.get("/maestro/status")
    assert status_board.status_code == 200
    assert status_board.json()["counts"]["queued"] >= 1

    listed = client.get("/maestro/jobs")
    assert listed.status_code == 200
    assert len(listed.json()["jobs"]) == 1

    budget = client.get("/maestro/budget")
    assert budget.status_code == 200
    assert "usable" in budget.json()

    # Starlette may 404 before our handler on `../`; malformed ids must 400.
    trav = client.post("/maestro/jobs/../../secret/hold")
    assert trav.status_code in (400, 404)
    bad_id = client.post("/maestro/jobs/not-a-maestro-id/hold")
    assert bad_id.status_code == 400

    held = client.post(f"/maestro/jobs/{body['id']}/hold")
    assert held.status_code == 200
    assert held.json()["status"] == "held"

    released = client.post(f"/maestro/jobs/{body['id']}/release")
    assert released.status_code == 200
    assert released.json()["status"] == "queued"

    status = client.get("/maestro/partials/status")
    assert status.status_code == 200
    assert body["id"] in status.text
