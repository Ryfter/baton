import json
import shutil
import subprocess
from pathlib import Path
import pytest
from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.routers.runs import build_router
from dashboard.readers.runs import read_assignments


def make_app(runs_root: Path) -> FastAPI:
    app = FastAPI()
    app.state.runs_root = runs_root
    here = Path(__file__).parent.parent
    app.include_router(build_router(Jinja2Templates(directory=str(here / "templates"))))
    return app


def _write_run(root: Path, rid: str, **fields):
    d = root / rid; d.mkdir(parents=True, exist_ok=True)
    base = {"id": rid, "name": rid, "model": "m", "status": "running"}
    base.update(fields)
    (d / "run.json").write_text(json.dumps(base), encoding="utf-8")


def test_full_lifecycle(tmp_path: Path):
    root = tmp_path / "runs"; root.mkdir()
    client = TestClient(make_app(root))

    # queued -> running with an event
    _write_run(root, "run_e", status="running", current_step="building")
    (root / "run_e" / "events.jsonl").write_text(
        '{"ts":"2026-06-06T03:00:00+00:00","kind":"action","what":"started","status":"done"}\n',
        encoding="utf-8")
    assert "run_e" in client.get("/partials/runs").text

    # becomes needs-you
    _write_run(root, "run_e", status="needs-you", parked_question="ship it?")
    detail = client.get("/partials/runs/run_e")
    assert "ship it?" in detail.text and 'name="answer"' in detail.text

    # user answers -> answer.txt written
    resp = client.post("/runs/run_e/answer", data={"answer": "yes"})
    assert resp.status_code == 200
    assert (root / "run_e" / "answer.txt").read_text(encoding="utf-8") == "yes"

    # agent resumes -> done
    _write_run(root, "run_e", status="done", current_step="finished")
    assert "run_e" in client.get("/partials/runs").text


pwsh = shutil.which("pwsh")
REPO = Path(__file__).resolve().parents[2]


@pytest.mark.skipif(pwsh is None, reason="pwsh not available")
def test_publish_item_run_lifecycle_to_assignments(tmp_path: Path):
    runs_root = tmp_path / "runs"
    script = (
        f". '{REPO}/scripts/fleet-runs-bridge.ps1'; "
        f"$env:ROUTING_RUNS_ROOT='{runs_root.as_posix()}'; "
        "Publish-ItemRun -Id 'issue-22' -Model 'codex' -State 'queued' -Name 'wire bridge'; "
        "Publish-ItemRun -Id 'issue-22' -Model 'codex' -State 'running' -Branch 'auto/issue-22-codex'"
    )
    subprocess.run([pwsh, "-NoProfile", "-Command", script], check=True, cwd=REPO)

    lanes = {l.model: l for l in read_assignments(runs_root)}
    assert "codex" in lanes
    assert [r.id for r in lanes["codex"].active] == ["backlog-issue-22-codex"]
    assert lanes["codex"].active[0].tree == "auto/issue-22-codex"
