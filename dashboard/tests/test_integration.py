# dashboard/tests/test_integration.py
import pytest
from pathlib import Path
from fastapi.testclient import TestClient

import dashboard.main as main_module
from dashboard.main import app


@pytest.fixture
def client(journal_file: Path, monkeypatch):
    monkeypatch.setattr(main_module, "JOURNAL_PATH", journal_file)
    app.state.journal_path = journal_file
    return TestClient(app)


def test_index_returns_html(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "Routing Dashboard" in resp.text


def test_index_contains_model_name(client):
    resp = client.get("/")
    assert "claude-sonnet-4-6" in resp.text


def test_index_contains_htmx_polling(client):
    resp = client.get("/")
    assert "hx-get" in resp.text
    assert "every 5s" in resp.text


def test_partial_spend_returns_html(client):
    resp = client.get("/partials/spend")
    assert resp.status_code == 200
    assert "Spend" in resp.text


def test_partial_leaderboard_returns_html(client):
    resp = client.get("/partials/leaderboard")
    assert resp.status_code == 200
    assert "Model" in resp.text


def test_partial_activity_returns_html(client):
    resp = client.get("/partials/activity")
    assert resp.status_code == 200
    assert "Activity" in resp.text


def test_api_stats_full(client):
    data = client.get("/api/stats").json()
    assert data["total_otel_calls"] == 2
    assert len(data["models"]) == 2
    assert data["models"][0]["name"] == "claude-sonnet-4-6"  # highest cost first


def test_activity_shows_newest_first(client):
    resp = client.get("/partials/activity")
    # The fixture has hooks at 10:00, 10:20, 10:25
    # reversed order: 10:25 then 10:20 then 10:00
    text = resp.text
    pos_25 = text.find("10:25")
    pos_20 = text.find("10:20")
    pos_00 = text.find("10:00")
    assert pos_25 < pos_20 < pos_00


@pytest.fixture
def client_with_jobs(journal_file, tagged_journal_file, jobs_root, monkeypatch):
    import dashboard.main as main_module
    from dashboard.main import app
    monkeypatch.setattr(main_module, 'JOURNAL_PATH', tagged_journal_file)
    monkeypatch.setattr(main_module, 'JOBS_ROOT', jobs_root)
    app.state.journal_path = tagged_journal_file
    app.state.jobs_root = jobs_root
    return TestClient(app)


def test_jobs_partial_via_main_app(client_with_jobs):
    resp = client_with_jobs.get('/partials/jobs')
    assert resp.status_code == 200
    assert 'j-2026-05-26-feature-flags' in resp.text


def test_jobs_detail_via_main_app(client_with_jobs):
    resp = client_with_jobs.get('/jobs/j-2026-05-26-feature-flags')
    assert resp.status_code == 200
    assert 'feature flag system' in resp.text


def test_index_includes_jobs_card(client_with_jobs):
    resp = client_with_jobs.get('/')
    assert resp.status_code == 200
    assert 'partials/jobs' in resp.text   # the hx-get URL of the jobs card
