"""Plan 7: tests for dashboard/routers/projects.py."""
from __future__ import annotations

from pathlib import Path
from fastapi.testclient import TestClient

from dashboard.main import app


def _setup(tmp_path: Path) -> dict[str, Path]:
    kb = tmp_path / 'kb'
    jobs = tmp_path / 'jobs'
    journal = tmp_path / 'journal.md'
    journal.write_text('# log\n', encoding='utf-8')
    (kb / 'projects' / 'alpha').mkdir(parents=True)
    (kb / 'projects' / 'alpha' / 'decision-guidance.md').write_text(
        '# Alpha Project\n', encoding='utf-8'
    )
    (kb / 'projects' / 'alpha' / 'cost.md').write_text(
        "**Current total: $7.50** (as of 2026-05-30)\n\n"
        "| Date | Total | Delta | Source | Note |\n"
        "|---|---|---|---|---|\n"
        "| 2026-05-30 | $7.50 | +$7.50 | seed | initial |\n",
        encoding='utf-8'
    )
    return {'kb': kb, 'jobs': jobs, 'journal': journal}


def test_projects_list_returns_200(tmp_path: Path) -> None:
    paths = _setup(tmp_path)
    app.state.kb_root = paths['kb']
    app.state.jobs_root = paths['jobs']
    app.state.journal_path = paths['journal']
    client = TestClient(app)
    r = client.get('/projects')
    assert r.status_code == 200
    assert 'Alpha Project' in r.text
    assert '7.50' in r.text


def test_partial_projects_returns_200(tmp_path: Path) -> None:
    paths = _setup(tmp_path)
    app.state.kb_root = paths['kb']
    app.state.jobs_root = paths['jobs']
    app.state.journal_path = paths['journal']
    client = TestClient(app)
    r = client.get('/partials/projects')
    assert r.status_code == 200
    assert 'Alpha Project' in r.text


def test_project_detail_200(tmp_path: Path) -> None:
    paths = _setup(tmp_path)
    app.state.kb_root = paths['kb']
    app.state.jobs_root = paths['jobs']
    app.state.journal_path = paths['journal']
    client = TestClient(app)
    r = client.get('/projects/alpha')
    assert r.status_code == 200
    assert 'Alpha Project' in r.text
    assert 'Cost ledger' in r.text


def test_project_detail_404(tmp_path: Path) -> None:
    paths = _setup(tmp_path)
    app.state.kb_root = paths['kb']
    app.state.jobs_root = paths['jobs']
    app.state.journal_path = paths['journal']
    client = TestClient(app)
    r = client.get('/projects/nope')
    assert r.status_code == 404
