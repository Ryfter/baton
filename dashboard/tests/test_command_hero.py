"""Tests for command hero partial."""
from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.readers.command_hero import read_command_hero


def test_command_hero_reader_shape(tmp_path: Path):
    home = tmp_path / "baton"
    (home / "maestro" / "jobs").mkdir(parents=True)
    journal = tmp_path / "journal.md"
    journal.write_text("", encoding="utf-8")
    hero = read_command_hero(home, journal)
    assert hero["mode"] == "Dark factory L4"
    assert "jobs_running" in hero
    assert hero["primary_seat"] == "openrouter-ox-alpha"


def test_command_hero_partial_route(tmp_path: Path):
    here = Path(__file__).resolve().parents[1]
    templates = Jinja2Templates(directory=str(here / "templates"))
    home = tmp_path / "baton"
    (home / "maestro" / "jobs").mkdir(parents=True)
    journal = tmp_path / "journal.md"
    journal.write_text("", encoding="utf-8")

    app = FastAPI()
    app.state.baton_home = home
    app.state.journal_path = journal

    @app.get("/partials/command-hero", response_class=HTMLResponse)
    async def partial_command_hero(request: Request) -> HTMLResponse:
        hero = read_command_hero(home, journal)
        return templates.TemplateResponse(
            request, "partials/command_hero.html", {"hero": hero}
        )

    client = TestClient(app)
    resp = client.get("/partials/command-hero")
    assert resp.status_code == 200
    assert "Dark factory" in resp.text
    assert "Ox Alpha" in resp.text
