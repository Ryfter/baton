from dashboard.models.runs import AgentLane, RunRecord


def test_agentlane_defaults_empty_lists():
    lane = AgentLane(model="codex")
    assert lane.model == "codex"
    assert lane.active == []
    assert lane.queued == []
    assert lane.parked == []


def test_agentlane_holds_runrecords():
    r = RunRecord(id="x", name="x", model="codex", status="running")
    lane = AgentLane(model="codex", active=[r])
    assert lane.active[0].id == "x"


from pathlib import Path
import json
from dashboard.readers.runs import read_assignments


def test_groups_runs_by_model(runs_root: Path):
    lanes = read_assignments(runs_root)
    by_model = {lane.model: lane for lane in lanes}
    assert "claude-opus-4-8" in by_model
    assert "codex" in by_model


def test_running_goes_to_active(runs_root: Path):
    lanes = {l.model: l for l in read_assignments(runs_root)}
    assert [r.id for r in lanes["claude-opus-4-8"].active] == ["run_auth-rewrite"]
    assert lanes["claude-opus-4-8"].queued == []
    assert lanes["claude-opus-4-8"].parked == []


def test_needs_you_goes_to_parked(runs_root: Path):
    lanes = {l.model: l for l in read_assignments(runs_root)}
    assert [r.id for r in lanes["codex"].parked] == ["run_fix-login"]


def test_lanes_sorted_by_model_name(runs_root: Path):
    lanes = read_assignments(runs_root)
    models = [l.model for l in lanes]
    assert models == sorted(models)


def test_done_failed_idle_omitted_from_lanes(tmp_path: Path):
    root = tmp_path / "runs"
    root.mkdir()
    for rid, status in [("a", "done"), ("b", "failed"), ("c", "idle")]:
        d = root / rid
        d.mkdir()
        (d / "run.json").write_text(json.dumps({
            "id": rid, "name": rid, "model": "codex", "status": status,
        }), encoding="utf-8")
    lanes = {l.model: l for l in read_assignments(root)}
    # codex lane exists (model was used) but no run lands in active/queued/parked
    assert lanes["codex"].active == []
    assert lanes["codex"].queued == []
    assert lanes["codex"].parked == []


def test_empty_root_returns_empty(tmp_path: Path):
    assert read_assignments(tmp_path / "nope") == []


def test_malformed_run_json_skipped(tmp_path: Path):
    root = tmp_path / "runs"
    root.mkdir()
    bad = root / "bad"
    bad.mkdir()
    (bad / "run.json").write_text("{ not json", encoding="utf-8")
    assert read_assignments(root) == []
