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
