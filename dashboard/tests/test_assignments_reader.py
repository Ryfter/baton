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
