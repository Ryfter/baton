from pathlib import Path
from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.routers.runs import build_router


def make_app(runs_root: Path) -> FastAPI:
    app = FastAPI()
    app.state.runs_root = runs_root
    here = Path(__file__).parent.parent
    templates = Jinja2Templates(directory=str(here / "templates"))
    app.include_router(build_router(templates))
    return app


def test_partial_runs_gutter(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.get("/partials/runs")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "auth-rewrite" in resp.text
    assert "fix-login" in resp.text
    # global strip rendered in the same response
    assert "128.64" in resp.text
    assert "21:30" in resp.text


def test_run_detail_full_page(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.get("/runs/run_auth-rewrite")
    assert resp.status_code == 200
    assert "implement grace window" in resp.text       # current_step
    assert "map blast radius" in resp.text             # event why
    # wires htmx polling to the live partial
    assert 'hx-get="/partials/runs/run_auth-rewrite"' in resp.text
    assert 'hx-trigger="every 5s"' in resp.text


def test_run_detail_404(runs_root: Path):
    client = TestClient(make_app(runs_root))
    assert client.get("/runs/run_nope").status_code == 404


def test_run_detail_live_partial(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.get("/partials/runs/run_auth-rewrite")
    assert resp.status_code == 200
    assert "wrote failing test" in resp.text
    assert "<!DOCTYPE html>" not in resp.text          # no base chrome


def test_needs_you_shows_answer_box(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.get("/partials/runs/run_fix-login")
    assert resp.status_code == 200
    assert "rotate tokens" in resp.text                # the parked question
    assert 'name="answer"' in resp.text                # the answer box


def test_post_answer_writes_file(runs_root: Path):
    client = TestClient(make_app(runs_root))
    resp = client.post("/runs/run_fix-login/answer", data={"answer": "use a grace window"})
    assert resp.status_code == 200
    assert (runs_root / "run_fix-login" / "answer.txt").read_text(encoding="utf-8") == "use a grace window"


def test_post_answer_404(runs_root: Path):
    client = TestClient(make_app(runs_root))
    assert client.post("/runs/run_nope/answer", data={"answer": "x"}).status_code == 404


def test_app_registers_runs_routes():
    from dashboard.main import app
    paths = {r.path for r in app.routes}
    assert "/partials/runs" in paths
    assert "/runs/{run_id}" in paths
