from hud.store import insert_event, query_events, replay_events, get_conn


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


def test_insert_event_stamps_recv_ts_and_dup_false(isolated_state):
    ev = make_event(session_id="s1", kind="stop")
    insert_event(ev)
    assert ev["recv_ts"]
    assert ev["dup"] is False


def test_insert_event_dedups_by_event_uid(isolated_state):
    ev1 = make_event(session_id="s1", kind="stop", event_uid="abc-123")
    id1 = insert_event(ev1)
    ev2 = make_event(session_id="s1", kind="stop", event_uid="abc-123")
    id2 = insert_event(ev2)
    assert id2 == id1
    assert ev2["dup"] is True
    assert ev2["seq"] == ev1["seq"]


def test_insert_event_without_event_uid_never_dedups(isolated_state):
    a = make_event(session_id="s1", kind="stop")
    b = make_event(session_id="s1", kind="stop")
    id_a = insert_event(a)
    id_b = insert_event(b)
    assert id_a != id_b
    assert a["dup"] is False and b["dup"] is False


def test_insert_event_recycled_event_uid_after_deletion_inserts_as_new_row(isolated_state):
    """Renamed from test_insert_event_row_vanished_retries_insert: this test
    deletes-and-commits before re-inserting, so INSERT OR IGNORE just
    succeeds normally -- it does NOT reach the "row vanished mid-transaction"
    branch (the `cur.rowcount == 0 and event_uid` / re-SELECT-finds-nothing
    path in insert_event). What it actually proves: a recycled event_uid,
    after the original row was pruned, re-inserts cleanly as a brand-new row
    rather than being treated as a (now-nonexistent) duplicate."""
    uid = "vanished-test-uid"
    ev1 = make_event(session_id="s1", kind="stop", event_uid=uid)
    id1 = insert_event(ev1)
    assert ev1["dup"] is False

    # Manually delete the row to simulate concurrent pruning
    conn = get_conn()
    conn.execute("DELETE FROM events WHERE event_uid = ?", (uid,))
    conn.commit()

    # Insert the same event again with the same event_uid
    # The unique index will no longer find a conflict, so a real insert should succeed
    ev2 = make_event(session_id="s1", kind="stop", event_uid=uid)
    id2 = insert_event(ev2)

    # Should have inserted a new row (different id)
    assert id2 != id1
    # Should NOT be marked as a duplicate (the old row is gone)
    assert ev2["dup"] is False
