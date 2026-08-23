"""Gauges reader + page — 5h project burn and cap instruments."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.readers.gauges import (
    UNASSIGNED,
    fold_project_needles,
    read_cap_gauges,
    read_gauges,
    resolve_window,
)
from dashboard.readers.maestro_jobs import create_job, maestro_root
from dashboard.routers.gauges import build_router


def _write_journal(path: Path, lines: list[str]) -> None:
    path.write_text("# Model Routing Log\n\n## Activity\n\n" + "\n".join(lines) + "\n", encoding="utf-8")


def test_window_uses_claude_reset(tmp_path: Path):
    now = datetime(2026, 8, 23, 7, 40, tzinfo=timezone.utc)
    reset = now + timedelta(minutes=20)
    (tmp_path / "claude-quota.json").write_text(
        json.dumps({"five_hour": {"resets_at": reset.isoformat()}}),
        encoding="utf-8",
    )
    window = resolve_window(tmp_path, now=now)
    assert window["is_claude_clock"] is True
    assert window["label"] == "5h window"
    assert window["end"] == reset
    assert window["start"] == reset - timedelta(hours=5)


def test_window_fallback_when_no_snapshot(tmp_path: Path):
    now = datetime(2026, 8, 23, 7, 40, tzinfo=timezone.utc)
    window = resolve_window(tmp_path, now=now)
    assert window["is_claude_clock"] is False
    assert window["label"] == "fallback — rolling 5h"
    assert window["end"] == now


def test_fold_project_needles_joins_and_sorts(tmp_path: Path):
    now = datetime(2026, 8, 23, 7, 40, tzinfo=timezone.utc)
    reset = now + timedelta(hours=1)
    (tmp_path / "claude-quota.json").write_text(
        json.dumps({"five_hour": {"resets_at": reset.isoformat()}}),
        encoding="utf-8",
    )
    window = resolve_window(tmp_path, now=now)

    jobs_root = tmp_path / "jobs"
    jobs_root.mkdir()
    mj_root = maestro_root(tmp_path)
    mj_root.mkdir(parents=True)
    job_a = create_job(mj_root, project="answerbot", goal="ship api")
    job_b = create_job(mj_root, project="baton", goal="gauges")

    journal = tmp_path / "model-routing-log.md"
    inside = now - timedelta(hours=2)
    outside = now - timedelta(hours=6)
    _write_journal(
        journal,
        [
            f"{inside.isoformat()} | otel | grok | in:100000 out:12000 | $0.50 | api_request | job:{job_a['id']}",
            f"{inside.isoformat()} | otel | ox-alpha | in:300000 out:20000 | $0.60 | api_request | job:{job_b['id']}",
            f"{inside.isoformat()} | otel | claude | in:5000 out:1000 | $0.05 | api_request",
            f"{outside.isoformat()} | otel | old-model | in:999999 out:999999 | $9.99 | api_request | job:{job_b['id']}",
        ],
    )

    registry = {"answerbot": "AnswerBot", "baton": "Baton"}
    job_map = {job_a["id"]: "answerbot", job_b["id"]: "baton"}
    needles, total_tokens, total_cost = fold_project_needles(journal, window, job_map, registry)

    assert total_tokens == 100000 + 12000 + 300000 + 20000 + 5000 + 1000
    assert abs(total_cost - 1.15) < 0.001
    assert len(needles) == 3
    assert needles[0]["id"] == "baton"
    assert needles[1]["id"] == "answerbot"
    assert needles[2]["id"] == UNASSIGNED
    assert needles[0]["tokens_display"] == "320k"
    assert "ox-alpha" in needles[0]["models"]


def test_cap_gauges_hide_without_snapshot(tmp_path: Path):
    now = datetime(2026, 8, 23, 7, 40, tzinfo=timezone.utc)
    assert read_cap_gauges(tmp_path, now=now) == []


def test_cap_gauges_claude_only(tmp_path: Path):
    now = datetime(2026, 8, 23, 7, 40, tzinfo=timezone.utc)
    reset5 = now + timedelta(minutes=47)
    reset7 = now + timedelta(days=4, hours=3)
    (tmp_path / "claude-quota.json").write_text(
        json.dumps(
            {
                "five_hour": {"used_pct": 100, "resets_at": reset5.isoformat()},
                "seven_day": {"used_pct": 62, "resets_at": reset7.isoformat()},
            }
        ),
        encoding="utf-8",
    )
    caps = read_cap_gauges(tmp_path, now=now)
    assert len(caps) == 2
    assert caps[0]["id"] == "claude_5h"
    assert "empty · resets in 47m" in caps[0]["label"]
    assert "empty-until-reset" not in caps[0]["label"]


def test_read_gauges_end_to_end(tmp_path: Path):
    now = datetime(2026, 8, 23, 7, 40, tzinfo=timezone.utc)
    reset = now + timedelta(minutes=30)
    (tmp_path / "claude-quota.json").write_text(
        json.dumps({"five_hour": {"used_pct": 88, "resets_at": reset.isoformat()}}),
        encoding="utf-8",
    )
    mj_root = maestro_root(tmp_path)
    mj_root.mkdir(parents=True)
    job = create_job(mj_root, project="baton", goal="test")
    journal = tmp_path / "model-routing-log.md"
    inside = now - timedelta(minutes=30)
    _write_journal(
        journal,
        [f"{inside.isoformat()} | otel | codex | in:1000 out:500 | $0.01 | api_request | job:{job['id']}"],
    )
    (tmp_path / "projects" / "baton" / "project.json").parent.mkdir(parents=True)
    (tmp_path / "projects" / "baton" / "project.json").write_text(
        '{"id":"baton","name":"Baton"}',
        encoding="utf-8",
    )
    payload = read_gauges(
        journal_path=journal,
        baton_home=tmp_path,
        jobs_root=tmp_path / "jobs",
        now=now,
    )
    assert payload["projects"][0]["name"] == "Baton"
    assert payload["clock"]["is_claude_clock"] is True
    assert len(payload["caps"]) == 1


def test_gauges_page_no_stub_strings(tmp_path: Path):
    reset = datetime.now(timezone.utc) + timedelta(minutes=47)
    (tmp_path / "claude-quota.json").write_text(
        json.dumps({"five_hour": {"used_pct": 100, "resets_at": reset.isoformat()}}),
        encoding="utf-8",
    )
    journal = tmp_path / "model-routing-log.md"
    _write_journal(journal, [])

    templates = Jinja2Templates(
        directory=str(Path(__file__).resolve().parents[1] / "templates")
    )
    app = FastAPI()
    app.state.baton_home = tmp_path
    app.state.journal_path = journal
    app.state.jobs_root = tmp_path / "jobs"
    app.include_router(build_router(templates))
    client = TestClient(app)

    page = client.get("/gauges")
    assert page.status_code == 200
    assert "Gauges" in page.text
    assert 'href="/gauges"' in page.text
    assert "empty-until-reset" not in page.text
    assert "empty · resets in" in page.text
    assert "47m" in page.text or "46m" in page.text

    partial = client.get("/partials/gauges")
    assert partial.status_code == 200
    assert "empty-until-reset" not in partial.text

    api = client.get("/api/gauges")
    assert api.status_code == 200
    assert api.json()["schema"] == 1
