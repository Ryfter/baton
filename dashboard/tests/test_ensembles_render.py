"""Renders /partials/fleet end-to-end and asserts the cockpit surfaces partial
provider content + synthesis preview (issues #21 + #26)."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import dashboard.main as main_module
from dashboard.main import app


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@pytest.fixture
def ensembles_root(tmp_path: Path, journal_file: Path, monkeypatch) -> Path:
    root = tmp_path / "ensembles"
    run = root / "ensemble-live"
    run.mkdir(parents=True)
    (run / "_ensemble.json").write_text(json.dumps({
        "run_id": "ensemble-live", "kind": "ensemble", "prompt": "Compare approaches",
        "state": "running", "started": _now_iso(), "timeout_s": 300,
        "tasks": [{"label": "claude-cli", "provider": "claude-cli"},
                  {"label": "codex", "provider": "codex"}],
    }), encoding="utf-8")
    # claude-cli finished -> partial content available while codex still runs.
    (run / "claude-cli.live.json").write_text(json.dumps({
        "label": "claude-cli", "provider": "claude-cli", "state": "done",
        "started": _now_iso(), "ended": _now_iso(), "duration_s": 6, "exit": 0}), encoding="utf-8")
    (run / "claude-cli.md").write_text("PARTIAL_FROM_CLAUDE: prefer the event-driven design.", encoding="utf-8")
    (run / "codex.live.json").write_text(json.dumps({
        "label": "codex", "provider": "codex", "state": "running", "started": _now_iso()}), encoding="utf-8")
    (run / "synthesis.md").write_text("SYNTH_BLOCK: the models agree on event-driven.", encoding="utf-8")

    monkeypatch.setattr(main_module, "ENSEMBLES_ROOT", root)
    monkeypatch.setattr(main_module, "JOURNAL_PATH", journal_file)
    app.state.journal_path = journal_file
    return root


def test_cockpit_shows_partial_content_and_synthesis(ensembles_root: Path):
    resp = TestClient(app).get("/partials/fleet")
    assert resp.status_code == 200
    html = resp.text
    # Finished provider's partial response is shown...
    assert "PARTIAL_FROM_CLAUDE" in html
    # ...the still-running provider has a live pulse but no content block yet.
    assert "prov-running" in html
    assert "PARTIAL_FROM_CODEX" not in html
    # Synthesis preview is surfaced.
    assert "SYNTH_BLOCK" in html
    assert "Synthesis preview" in html
