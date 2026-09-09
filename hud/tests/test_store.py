from hud.store import insert_event, query_events, replay_events


def make_event(**overrides):
    event = {
        "schema": "hud.event/v1",
        "ts": "2026-09-09T07:40:00Z",
        "session_id": "abc123",
        "source": "claude-hook",
        "kind": "stop",
        "agent": "main",
        "machine": "droid",
        "payload": {},
    }
    event.update(overrides)
    return event


def test_insert_event_returns_id(isolated_state):
    eid = insert_event(make_event(session_id="s1", kind="stop"))
    assert isinstance(eid, int)
    assert eid >= 1


def test_seq_increments_per_session_independent(isolated_state):
    a1 = make_event(session_id="alpha", kind="session_start")
    a2 = make_event(session_id="alpha", kind="stop")
    b1 = make_event(session_id="beta", kind="session_start")
    insert_event(a1)
    insert_event(a2)
    insert_event(b1)
    assert a1["seq"] == 1
    assert a2["seq"] == 2
    assert b1["seq"] == 1


def test_query_events_honours_since_limit_session_kind(isolated_state):
    insert_event(make_event(session_id="a", kind="stop"))
    insert_event(make_event(session_id="b", kind="notification", payload={"message": "x"}))
    insert_event(make_event(session_id="a", kind="notification", payload={"message": "y"}))
    only_a = query_events(session="a")
    assert [e["session_id"] for e in only_a] == ["a", "a"]
    only_n = query_events(kind="notification")
    assert [e["kind"] for e in only_n] == ["notification", "notification"]
    limited = query_events(limit=1)
    assert len(limited) == 1
    assert limited[0]["id"] == 1
    since = query_events(since=1)
    assert all(e["id"] > 1 for e in since)
    assert len(since) == 2


def test_replay_events_ascending(isolated_state):
    for i in range(5):
        insert_event(make_event(session_id="s", kind="stop", ts="2026-09-09T07:40:0%sZ" % i))
    replayed = replay_events(3)
    ids = [e["id"] for e in replayed]
    assert ids == sorted(ids)
    assert ids == [3, 4, 5]
