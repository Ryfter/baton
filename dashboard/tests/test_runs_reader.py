from datetime import datetime

from dashboard.models.runs import RunRecord, RunEvent, RunDetail, GlobalStrip


def test_run_record_defaults():
    r = RunRecord(id="run_x", name="x", model="claude-opus-4-8", status="running")
    assert r.cost_usd == 0.0
    assert r.tokens_in == 0
    assert r.files_touched == []
    assert r.parked_question is None
    assert r.worktree is False


def test_run_event_minimal():
    e = RunEvent(ts=datetime(2026, 6, 6, 3, 15), kind="action", what="read file")
    assert e.why is None
    assert e.kind == "action"


def test_run_detail_and_strip():
    rec = RunRecord(id="r", name="r", model="m", status="idle")
    d = RunDetail(record=rec, events=[])
    assert d.events == []
    s = GlobalStrip()
    assert s.spend_today_usd == 0.0
    assert s.active_runs == 0
    assert s.rate_limit_pct is None


from pathlib import Path

from dashboard.readers.runs import (
    list_runs, read_run_detail, read_global_strip, write_run_answer,
)


def test_list_runs_sorted_active_first(runs_root: Path):
    runs = list_runs(runs_root)
    assert [r.id for r in runs] == ["run_auth-rewrite", "run_fix-login"]
    assert runs[1].status == "needs-you"


def test_list_runs_missing_root(tmp_path: Path):
    assert list_runs(tmp_path / "nope") == []


def test_list_runs_skips_corrupt(runs_root: Path):
    bad = runs_root / "run_bad"
    bad.mkdir()
    (bad / "run.json").write_text("{ not json", encoding="utf-8")
    runs = list_runs(runs_root)
    assert all(r.id != "run_bad" for r in runs)
    assert len(runs) == 2


def test_read_run_detail(runs_root: Path):
    d = read_run_detail(runs_root, "run_auth-rewrite")
    assert d.record.name == "auth-rewrite"
    assert len(d.events) == 2
    assert d.events[0].why == "map blast radius"


def test_read_run_detail_missing(runs_root: Path):
    import pytest
    with pytest.raises(FileNotFoundError):
        read_run_detail(runs_root, "run_nope")


def test_read_global_strip(runs_root: Path):
    s = read_global_strip(runs_root)
    assert s.rate_limit_pct == 37
    assert s.spend_today_usd == 128.64


def test_read_global_strip_missing_falls_back(tmp_path: Path):
    root = tmp_path / "runs"; root.mkdir()
    s = read_global_strip(root)
    assert s.spend_today_usd == 0.0
    assert s.rate_limit_pct is None


def test_write_run_answer(runs_root: Path):
    write_run_answer(runs_root, "run_fix-login", "use a grace window")
    assert (runs_root / "run_fix-login" / "answer.txt").read_text(encoding="utf-8") == "use a grace window"


def test_write_run_answer_missing_run(runs_root: Path):
    import pytest
    with pytest.raises(FileNotFoundError):
        write_run_answer(runs_root, "run_nope", "x")
