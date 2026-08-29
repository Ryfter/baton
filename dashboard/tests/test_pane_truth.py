"""Pane-truth permission detection tests."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from dashboard.readers.maestro_jobs import create_job, maestro_root, write_job
from dashboard.readers.pane_truth import permission_attention_items


def test_permission_from_event_kind(tmp_path: Path):
    mj = maestro_root(tmp_path)
    mj.mkdir(parents=True)
    job = create_job(mj, project="answerbot", goal="go", status="running")
    write_job(mj, job)
    now = datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc)
    (mj / "events.jsonl").write_text(
        json.dumps({
            "job_id": job["id"],
            "ts": now.isoformat().replace("+00:00", "Z"),
            "kind": "needs-permission",
            "what": "Approve npm publish?",
        }) + "\n",
        encoding="utf-8",
    )
    items = permission_attention_items(
        baton_home=tmp_path,
        project_id="answerbot",
        project_name="AnswerBot",
        job_id=job["id"],
        now=now,
    )
    assert len(items) == 1
    assert items[0]["kind"] == "permission"
    assert "Approve npm publish" in items[0]["label"]


def test_pane_truth_sidecar(tmp_path: Path):
    obs = tmp_path / "observability"
    obs.mkdir(parents=True)
    (obs / "pane-truth.json").write_text(
        json.dumps([{"project_id": "baton", "message": "Allow network access?"}]),
        encoding="utf-8",
    )
    items = permission_attention_items(
        baton_home=tmp_path,
        project_id="baton",
        project_name="Baton",
    )
    assert any("Allow network access" in i["label"] for i in items)
