"""Machines reader + page — computers, not a flat model dump."""
from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.readers.machines import parse_fleet_providers, read_machines
from dashboard.routers.machines import build_router


_FLEET = """
providers:
  - name: claude-cli
    kind: cli
    enabled: true
    cost_tier: paid
  - name: ollama-local
    kind: cli
    enabled: true
    cost_tier: local
    model_default: 'devstral:24b'
  - name: ollama-box2
    kind: http
    enabled: true
    cost_tier: local
    model_default: 'dolphin3:8b'
    base_url: 'http://192.168.1.80:11434'
  - name: lm-studio
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    model_default: 'qwen/qwen3-coder-30b'
  - name: lm-studio-small
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    model_default: 'phi-4'
  - name: disabled-box
    kind: http
    enabled: false
    cost_tier: local
    base_url: 'http://192.168.1.99:1234'
    model_default: 'should-not-appear'
"""


def test_parse_fleet_providers():
    rows = parse_fleet_providers(_FLEET)
    by_name = {r["name"]: r for r in rows}
    assert by_name["lm-studio"]["base_url"] == "http://localhost:1234"
    assert by_name["lm-studio"]["model_default"] == "qwen/qwen3-coder-30b"
    assert by_name["disabled-box"]["enabled"] == "false"


def test_read_machines_groups_by_computer(tmp_path: Path):
    fleet = tmp_path / "fleet.yaml"
    fleet.write_text(_FLEET, encoding="utf-8")
    inventory = tmp_path / "model-inventory.json"
    inventory.write_text(
        '{"boxes":[{"base_url":"http://localhost:1234","models":['
        '{"id":"qwen/qwen3-coder-30b","loaded":true},'
        '{"id":"phi-4","loaded":false},'
        '{"id":"some-huge-catalog-model","loaded":false}'
        "]}]}",
        encoding="utf-8",
    )
    payload = read_machines(
        fleet,
        inventory_path=inventory,
        loaded_lms=[{"id": "qwen/qwen3-coder-30b"}],
    )
    by_id = {m["id"]: m for m in payload["machines"]}
    assert "droid" in by_id
    assert "192.168.1.80" in by_id
    assert "192.168.1.99" not in by_id
    droid = by_id["droid"]
    installed_ids = {m["id"] for m in droid["installed"]}
    catalog_ids = {m["id"] for m in droid["catalog"]}
    assert "qwen/qwen3-coder-30b" in installed_ids
    assert "phi-4" in installed_ids
    assert "devstral:24b" in installed_ids
    assert "some-huge-catalog-model" in catalog_ids
    assert "some-huge-catalog-model" not in installed_ids
    assert by_id["192.168.1.80"]["installed"][0]["id"] == "dolphin3:8b"
    cloud = by_id["cloud"]
    assert "claude-cli" in cloud["providers"]
    assert droid["name"] == "droid · Mac mini"


def test_machines_page(tmp_path: Path):
    fleet = tmp_path / "fleet.yaml"
    fleet.write_text(_FLEET, encoding="utf-8")
    templates = Jinja2Templates(
        directory=str(Path(__file__).resolve().parents[1] / "templates")
    )
    app = FastAPI()
    app.state.baton_home = tmp_path
    app.state.fleet_path = fleet
    app.state.journal_path = tmp_path / "missing-journal.md"
    app.include_router(build_router(templates))
    client = TestClient(app)

    page = client.get("/machines")
    assert page.status_code == 200
    assert "droid · Mac mini" in page.text
    assert "qwen/qwen3-coder-30b" in page.text
    assert "192.168.1.80" in page.text
    assert "Cloud seats" in page.text
    assert "should-not-appear" not in page.text
