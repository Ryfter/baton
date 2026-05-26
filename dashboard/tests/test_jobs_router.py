import pytest
from pathlib import Path
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.routers.jobs import build_router


def make_app(jobs_root: Path, journal_path: Path) -> FastAPI:
    app = FastAPI()
    app.state.jobs_root = jobs_root
    app.state.journal_path = journal_path
    here = Path(__file__).parent.parent
    templates = Jinja2Templates(directory=str(here / 'templates'))
    app.include_router(build_router(templates))
    return app


def test_partial_jobs_html(jobs_root: Path, tagged_journal_file: Path):
    client = TestClient(make_app(jobs_root, tagged_journal_file))
    resp = client.get('/partials/jobs')
    assert resp.status_code == 200
    assert 'text/html' in resp.headers['content-type']
    assert 'j-2026-05-26-feature-flags' in resp.text


def test_jobs_detail_html(jobs_root: Path, tagged_journal_file: Path):
    client = TestClient(make_app(jobs_root, tagged_journal_file))
    resp = client.get('/jobs/j-2026-05-26-feature-flags')
    assert resp.status_code == 200
    assert 'feature flag system' in resp.text
    assert 'research → design' in resp.text   # phase-log
    assert 'release vs ops' in resp.text       # lesson


def test_jobs_detail_404(jobs_root: Path, tagged_journal_file: Path):
    client = TestClient(make_app(jobs_root, tagged_journal_file))
    resp = client.get('/jobs/j-nope')
    assert resp.status_code == 404
