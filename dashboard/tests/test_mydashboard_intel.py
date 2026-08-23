"""Tests for MyDashboard intel reader and partial."""
from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.readers.mydashboard_intel import read_mydashboard_intel
from dashboard.routers.mydashboard import build_router


def test_read_mydashboard_intel_shape():
    intel = read_mydashboard_intel()
    assert "available" in intel
    assert "topics" in intel
    assert isinstance(intel["topics"], list)
    assert "counts" in intel


def test_mydashboard_partial_route(tmp_path: Path):
    here = Path(__file__).resolve().parents[1]
    templates = Jinja2Templates(directory=str(here / "templates"))
    app = FastAPI()
    app.include_router(build_router(templates))
    client = TestClient(app)
    resp = client.get("/mydashboard/partials/intel")
    assert resp.status_code == 200
    assert "MyDashboard" in resp.text
