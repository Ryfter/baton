"""Agent observability reader tests."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from dashboard.readers.agent_observability import (
    observability_attention_items,
    observability_for_project,
    parse_plan_md,
)
from dashboard.readers.home_board import read_home_header


SAMPLE_PLAN = """# demo

## Capture audio {#capture}
files: [src/audio/**]
- [x] Grab mic {#capture-mic}
- [~] Ring buffer {#capture-ring}

## Ship it {#ship}
needs: [capture]
- [!] Blocked on device {#ship-block}
"""


def test_parse_plan_md_components_and_tasks():
    plan = parse_plan_md(SAMPLE_PLAN)
    comps = [n for n in plan["nodes"] if n["level"] == "component"]
    assert len(comps) == 2
    assert comps[0]["id"] == "capture"
    assert comps[0]["files"] == ["src/audio/**"]
    tasks = [n for n in plan["nodes"] if n["level"] == "task"]
    assert any(t["status"] == "active" for t in tasks)
    assert any(t["status"] == "blocked" for t in tasks)
    assert comps[0]["status"] == "active"


def test_regression_surfaces_in_attention_rail(tmp_path: Path):
    folder = tmp_path / "demo-proj"
    folder.mkdir()
    (folder / "PLAN.md").write_text(SAMPLE_PLAN, encoding="utf-8")

    baton = tmp_path / "baton"
    proj = baton / "projects" / "demo" / "project.json"
    proj.parent.mkdir(parents=True)
    proj.write_text(
        json.dumps({"id": "demo", "name": "Demo", "folder": str(folder)}),
        encoding="utf-8",
    )

    # Simulate agenttrail persisted state — done component touched recently
    state_dir = Path.home() / ".agenttrail"
    state_dir.mkdir(exist_ok=True)
    import hashlib

    digest = hashlib.sha1(str(folder.resolve()).encode()).hexdigest()[:12]
    state_file = state_dir / f"{digest}.json"
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    state_file.write_text(
        json.dumps({"compTouched": {"capture": now_ms}, "activity": {"file": "src/audio/x.py", "at": now_ms}}),
        encoding="utf-8",
    )

    items = observability_attention_items(
        baton_home=baton,
        project_id="demo",
        project_name="Demo",
        jobs_dir=baton / "maestro" / "jobs",
    )
    assert any(i["kind"] == "blocked" for i in items)
    assert any("revising done" in i["label"].lower() or "blocked" in i["label"].lower() for i in items)


def test_observability_for_project_without_plan(tmp_path: Path):
    folder = tmp_path / "empty"
    folder.mkdir()
    baton = tmp_path / "baton"
    rec = baton / "projects" / "empty" / "project.json"
    rec.parent.mkdir(parents=True)
    rec.write_text(json.dumps({"id": "empty", "folder": str(folder)}), encoding="utf-8")

    obs = observability_for_project(
        baton_home=baton,
        project_id="empty",
        jobs_dir=baton / "maestro" / "jobs",
    )
    assert obs["enabled"] is True
    assert obs["has_plan"] is False


def test_home_header_includes_blocked_plan_task(tmp_path: Path):
    folder = tmp_path / "answerbot"
    folder.mkdir()
    (folder / "PLAN.md").write_text(
        "# bot\n\n## Fix login {#login}\nfiles: [src/**]\n- [!] Stuck on auth {#login-stuck}\n",
        encoding="utf-8",
    )
    baton = tmp_path / "baton"
    (baton / "projects" / "answerbot" / "project.json").parent.mkdir(parents=True)
    (baton / "projects" / "answerbot" / "project.json").write_text(
        json.dumps({"id": "answerbot", "name": "AnswerBot", "folder": str(folder)}),
        encoding="utf-8",
    )
    (baton / "maestro" / "jobs").mkdir(parents=True)
    journal = baton / "model-routing-log.md"
    journal.write_text("# log\n", encoding="utf-8")

    # Minimal grid dependency: running job record
    job = {
        "id": "mj-aaaaaaaaaaaa",
        "project": "answerbot",
        "goal": "fix",
        "status": "running",
        "created_at": "2026-08-24T06:00:00+00:00",
    }
    (baton / "maestro" / "jobs" / "mj-aaaaaaaaaaaa.json").write_text(
        json.dumps(job), encoding="utf-8",
    )

    header = read_home_header(
        baton_home=baton,
        journal_path=journal,
        jobs_root=baton / "jobs",
        runs_root=baton / "runs",
        now=datetime(2026, 8, 24, 7, 0, tzinfo=timezone.utc),
    )
    assert any("blocked" in a["label"].lower() for a in header["attention"])
