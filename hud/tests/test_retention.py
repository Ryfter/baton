import time

from hud import retention, store


def _insert_old(session_id, kind, payload, ts):
    ev = {"schema": "hud.event/v1", "ts": ts, "session_id": session_id, "source": "claude-hook",
          "kind": kind, "agent": "main", "machine": "m", "payload": payload}
    store.insert_event(ev)
    return ev


def test_prune_once_rolls_old_rows_into_rollups_and_deletes_them(isolated_state):
    old_ts = "2020-01-01T07:00:03Z"
    _insert_old("s1", "post_tool_use", {"tool_name": "Bash", "ok": True}, old_ts)
    _insert_old("s1", "post_tool_use", {"tool_name": "Bash", "ok": False, "error": "boom"}, old_ts)
    _insert_old("s2", "stop", {}, "2020-01-01T07:00:05Z")  # also old -- retention is date-based
    conn = store.get_conn()

    result = retention.prune_once(conn, retention_days=30, now=time.time())
    assert result["deleted"] == 3
    assert store.count_events() == 0

    row = conn.execute(
        "SELECT n, n_errors FROM rollups_hourly WHERE bucket_ts = ? AND kind = 'post_tool_use'",
        ("2020-01-01T07:00:00Z",),
    ).fetchone()
    assert row["n"] == 2
    assert row["n_errors"] == 1


def test_prune_once_is_safe_to_call_repeatedly(isolated_state):
    """Two separate prune passes over data in the same hour bucket must
    accumulate in rollups_hourly, not collide on the NULL project/model PK."""
    conn = store.get_conn()
    _insert_old("s1", "stop", {}, "2020-01-01T07:00:00Z")
    retention.prune_once(conn, retention_days=30, now=time.time())
    _insert_old("s2", "stop", {}, "2020-01-01T07:00:30Z")
    retention.prune_once(conn, retention_days=30, now=time.time())
    row = conn.execute(
        "SELECT n FROM rollups_hourly WHERE bucket_ts = ? AND kind = 'stop'",
        ("2020-01-01T07:00:00Z",),
    ).fetchone()
    assert row["n"] == 2  # not two separate rows of n=1


def test_prune_once_keeps_recent_rows(isolated_state):
    import datetime
    recent = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _insert_old("s1", "stop", {}, recent)
    conn = store.get_conn()
    retention.prune_once(conn, retention_days=30, now=time.time())
    assert store.count_events() == 1


def test_backup_now_creates_restorable_copy_and_keeps_n(isolated_state, tmp_path):
    conn = store.get_conn()
    _insert_old("s1", "stop", {}, "2026-09-12T00:00:00Z")
    backups = tmp_path / "backups"
    paths = [retention.backup_now(conn, backups, keep=2) for _ in range(3)]
    remaining = sorted(backups.glob("hud-*.db"))
    assert len(remaining) == 2
    assert paths[-1].exists()


def test_should_backup():
    now = 1_000_000.0
    assert retention.should_backup(None, now) is True
    assert retention.should_backup(now - 3600, now) is False
    assert retention.should_backup(now - 21 * 3600, now) is True
