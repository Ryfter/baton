"""Home shift board — attention rail + project cards."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.readers.home_board import _classify_activity, _resolve_pill, read_home_header
from dashboard.readers.maestro_jobs import create_job, maestro_root, write_job
from dashboard.routers.home import build_router


def test_attention_rail_waiting_quota(tmp_path: Path):
    mj = maestro_root(tmp_path)
    mj.mkdir(parents=True)
    job = create_job(mj, project="answerbot", goal="wait", status="waiting-quota")
    write_job(mj, {**job, "status": "waiting-quota"})
    (tmp_path / "projects" / "answerbot" / "project.json").parent.mkdir(parents=True)
    (tmp_path / "projects" / "answerbot" / "project.json").write_text(
        '{"id":"answerbot","name":"AnswerBot"}', encoding="utf-8",
    )
    journal = tmp_path / "model-routing-log.md"
    journal.write_text("# log\n", encoding="utf-8")
    header = read_home_header(
        baton_home=tmp_path,
        journal_path=journal,
        jobs_root=tmp_path / "jobs",
        runs_root=tmp_path / "runs",
        now=datetime(2026, 8, 23, 7, 40, tzinfo=timezone.utc),
    )
    assert header["attention_clean"] is False
    assert any("answerbot" in a["label"].lower() for a in header["attention"])


def test_stale_running_job_not_in_attention_rail(tmp_path: Path):
    mj = maestro_root(tmp_path)
    mj.mkdir(parents=True)
    old = datetime(2026, 8, 22, 7, 0, tzinfo=timezone.utc)
    job = create_job(mj, project="answerbot", goal="old run", status="running")
    write_job(mj, {
        **job,
        "status": "running",
        "created_at": old.isoformat().replace("+00:00", "Z"),
    })
    (tmp_path / "projects" / "answerbot" / "project.json").parent.mkdir(parents=True)
    (tmp_path / "projects" / "answerbot" / "project.json").write_text(
        '{"id":"answerbot","name":"AnswerBot"}', encoding="utf-8",
    )
    events = mj / "events.jsonl"
    events.write_text(
        json.dumps({"job_id": job["id"], "ts": old.isoformat().replace("+00:00", "Z"), "kind": "tick"}) + "\n",
        encoding="utf-8",
    )
    journal = tmp_path / "model-routing-log.md"
    journal.write_text("# log\n", encoding="utf-8")
    header = read_home_header(
        baton_home=tmp_path,
        journal_path=journal,
        jobs_root=tmp_path / "jobs",
        runs_root=tmp_path / "runs",
        now=datetime(2026, 8, 23, 7, 40, tzinfo=timezone.utc),
    )
    assert header["stale_count"] >= 1
    assert not any("stalled" in a["label"] for a in header["attention"])


def test_resolve_pill_stale_vs_stalled():
    assert _resolve_pill("running", 500) == "stalled"
    assert _resolve_pill("running", 50000) == "stale"
    assert _resolve_pill("running", 60) == "running"


def test_classify_lifecycle_output():
    cell = {"status": "queued", "turns": [{"kind": "status", "detail": "created · queued"}]}
    activity = _classify_activity(cell, "created · queued · openrouter-ox-alpha")
    assert activity["kind"] == "lifecycle"


def test_home_page_no_doughnut(tmp_path: Path):
    journal = tmp_path / "model-routing-log.md"
    journal.write_text("# log\n", encoding="utf-8")
    templates = Jinja2Templates(directory=str(Path(__file__).resolve().parents[1] / "templates"))
    app = FastAPI()
    app.state.baton_home = tmp_path
    app.state.journal_path = journal
    app.state.jobs_root = tmp_path / "jobs"
    app.state.runs_root = tmp_path / "runs"
    app.include_router(build_router(templates))

    from dashboard.readers.home_board import read_home_floor, read_home_header
    from dashboard.readers.stats import compute_stats

    @app.get("/")
    async def home(request: Request):
        ctx = {
            "stats": compute_stats(journal),
            "server_time": "now",
            "board": read_home_header(
                baton_home=tmp_path, journal_path=journal,
                jobs_root=tmp_path / "jobs", runs_root=tmp_path / "runs",
            ),
            "floor": read_home_floor(
                baton_home=tmp_path, journal_path=journal,
                jobs_root=tmp_path / "jobs", runs_root=tmp_path / "runs",
            ),
        }
        return templates.TemplateResponse(request, "index.html", ctx)

    client = TestClient(app)
    page = client.get("/")
    assert page.status_code == 200
    assert "costChart" not in page.text
    assert "attention-rail" in page.text
    assert "empty-until-reset" not in page.text
