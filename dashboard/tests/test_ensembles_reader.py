"""Tests for the ensemble cockpit reader's partial-content + synthesis previews
(Plan 10 / issues #21 + #26)."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from dashboard.readers.ensembles import read_ensembles


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def _json(path: Path, obj: dict) -> None:
    path.write_text(json.dumps(obj), encoding="utf-8")


def test_active_run_exposes_finished_provider_preview_but_not_running(tmp_path: Path) -> None:
    root = tmp_path / "ensembles"
    run = root / "ensemble-run1"
    run.mkdir(parents=True)
    _json(run / "_ensemble.json", {
        "run_id": "ensemble-run1", "kind": "ensemble", "prompt": "Compare X and Y",
        "state": "running", "started": _now_iso(), "timeout_s": 300,
        "tasks": [{"label": "alpha", "provider": "alpha"},
                  {"label": "beta", "provider": "beta"}],
    })
    # alpha finished -> has a .md; beta still running -> no .md yet.
    _json(run / "alpha.live.json", {"label": "alpha", "provider": "alpha", "state": "done",
                                    "started": _now_iso(), "ended": _now_iso(), "duration_s": 4, "exit": 0})
    _write(run / "alpha.md", "Alpha says: the answer is 42.")
    _json(run / "beta.live.json", {"label": "beta", "provider": "beta", "state": "running",
                                   "started": _now_iso()})

    data = read_ensembles(root)
    assert len(data["active"]) == 1
    provs = {p["provider"]: p for p in data["active"][0]["providers"]}

    assert provs["alpha"]["state"] == "done"
    assert "answer is 42" in provs["alpha"]["preview"]
    assert provs["alpha"]["preview_truncated"] is False

    assert provs["beta"]["state"] == "running"
    assert provs["beta"]["preview"] == ""          # no content until it finishes


def test_long_provider_output_is_truncated(tmp_path: Path) -> None:
    root = tmp_path / "ensembles"
    run = root / "ensemble-run2"
    run.mkdir(parents=True)
    _json(run / "_ensemble.json", {
        "run_id": "ensemble-run2", "kind": "ensemble", "prompt": "p", "state": "running",
        "started": _now_iso(), "timeout_s": 300, "tasks": [{"label": "alpha", "provider": "alpha"}],
    })
    _json(run / "alpha.live.json", {"label": "alpha", "provider": "alpha", "state": "done",
                                    "started": _now_iso(), "ended": _now_iso(), "duration_s": 2, "exit": 0})
    _write(run / "alpha.md", "x" * 5000)

    run_obj = read_ensembles(root)["active"][0]
    alpha = run_obj["providers"][0]
    assert alpha["preview_truncated"] is True
    assert 0 < len(alpha["preview"]) < 5000


def test_synthesis_preview_surfaced_when_present(tmp_path: Path) -> None:
    root = tmp_path / "ensembles"
    run = root / "ensemble-done"
    run.mkdir(parents=True)
    _json(run / "_ensemble.json", {
        "run_id": "ensemble-done", "kind": "ensemble", "prompt": "p", "state": "done",
        "started": _now_iso(), "ended": _now_iso(), "timeout_s": 300,
        "tasks": [{"label": "gamma", "provider": "gamma"}],
    })
    _json(run / "gamma.live.json", {"label": "gamma", "provider": "gamma", "state": "done",
                                    "started": _now_iso(), "ended": _now_iso(), "duration_s": 3, "exit": 0})
    _write(run / "gamma.md", "Gamma output text.")
    _write(run / "synthesis.md", "Synthesis: the models AGREE on the core claim.")

    recent = read_ensembles(root)["recent"]
    assert len(recent) == 1
    assert "AGREE on the core claim" in recent[0]["synthesis"]
    assert recent[0]["providers"][0]["preview"] == "Gamma output text."


def test_no_synthesis_yields_empty_string(tmp_path: Path) -> None:
    root = tmp_path / "ensembles"
    run = root / "ensemble-nosyn"
    run.mkdir(parents=True)
    _json(run / "_ensemble.json", {
        "run_id": "ensemble-nosyn", "kind": "ensemble", "prompt": "p", "state": "done",
        "started": _now_iso(), "ended": _now_iso(), "timeout_s": 300,
        "tasks": [{"label": "alpha", "provider": "alpha"}],
    })
    _json(run / "alpha.live.json", {"label": "alpha", "provider": "alpha", "state": "done",
                                    "started": _now_iso(), "ended": _now_iso(), "duration_s": 1, "exit": 0})
    _write(run / "alpha.md", "done")

    assert read_ensembles(root)["recent"][0]["synthesis"] == ""
