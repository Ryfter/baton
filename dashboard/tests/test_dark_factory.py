"""Tests for dark factory dashboard reader."""
from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.readers.dark_factory import read_dark_factory_board
from dashboard.routers.dark_factory import build_router


def test_read_dark_factory_board_shape(tmp_path: Path):
    home = tmp_path / "baton"
    (home / "maestro" / "jobs").mkdir(parents=True)
    board = read_dark_factory_board(home)
    assert "jobs_total" in board
    assert "lanes" in board
    assert isinstance(board["dark_factory_jobs"], list)
    assert "curriculum_shipped" in board


def test_dark_factory_partial_route(tmp_path: Path):
    here = Path(__file__).resolve().parents[1]
    templates = Jinja2Templates(directory=str(here / "templates"))
    app = FastAPI()
    app.state.baton_home = tmp_path / "baton"
    app.include_router(build_router(templates))
    client = TestClient(app)
    resp = client.get("/dark-factory/partials/panel")
    assert resp.status_code == 200
    assert "Dark factory" in resp.text
