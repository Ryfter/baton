import json
from pathlib import Path
from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.routers.runs import build_router


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
