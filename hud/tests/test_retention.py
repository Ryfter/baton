import os
import time

import pytest

from hud import retention, store


def _insert_old(session_id, kind, payload, ts):
    """Insert an event with the given `ts`. insert_event always stamps
    recv_ts to the real wall-clock "now", so this makes a row with an OLD
    `ts` but a RECENT `recv_ts` -- useful on its own for the I2 tests below,
    which are specifically about that divergence."""
    ev = {"schema": "hud.event/v1", "ts": ts, "session_id": session_id, "source": "claude-hook",
          "kind": kind, "agent": "main", "machine": "m", "payload": payload}
    store.insert_event(ev)
    return ev


def _insert_fully_old(session_id, kind, payload, ts):
    """Like _insert_old, but also backdates recv_ts to match ts -- a
    realistic "genuinely old" row, as if it had actually been ingested back
    when `ts` was current. Used by tests that exercise the prune+rollup
    mechanism itself rather than the ts/recv_ts divergence (I2)."""
    ev = _insert_old(session_id, kind, payload, ts)
    conn = store.get_conn()
    conn.execute("UPDATE events SET recv_ts = ? WHERE session_id = ? AND ts = ? AND recv_ts != ?",
                 (ts, session_id, ts, ts))
    conn.commit()
    ev["recv_ts"] = ts
    return ev


def test_prune_once_rolls_old_rows_into_rollups_and_deletes_them(isolated_state):
    old_ts = "2020-01-01T07:00:03Z"
    ev1 = _insert_fully_old("s1", "post_tool_use", {"tool_name": "Bash", "ok": True}, old_ts)
    _insert_fully_old("s1", "post_tool_use", {"tool_name": "Bash", "ok": False, "error": "boom"}, old_ts)
    _insert_fully_old("s2", "stop", {}, "2020-01-01T07:00:05Z")  # also old -- retention is date-based
    conn = store.get_conn()

    result = retention.prune_once(conn, retention_days=30, now=time.time())
    assert result["deleted"] == 3
    assert store.count_events() == 0

    # I2: bucket_ts is keyed on recv_ts (the collector clock), not the
    # emitter-supplied `ts` above -- floor insert_event's own recv_ts (real
    # wall-clock time of the insert) to the hour, don't hardcode `old_ts`'s
    # bucket.
    bucket = retention._bucket_ts(ev1["recv_ts"])
    row = conn.execute(
        "SELECT n, n_errors FROM rollups_hourly WHERE bucket_ts = ? AND kind = 'post_tool_use'",
        (bucket,),
    ).fetchone()
    assert row["n"] == 2
    assert row["n_errors"] == 1


def test_prune_once_is_safe_to_call_repeatedly(isolated_state):
    """Two separate prune passes over data in the same hour bucket must
    accumulate in rollups_hourly, not collide on the NULL project/model PK."""
    conn = store.get_conn()
    ev1 = _insert_fully_old("s1", "stop", {}, "2020-01-01T07:00:00Z")
    retention.prune_once(conn, retention_days=30, now=time.time())
    _insert_fully_old("s2", "stop", {}, "2020-01-01T07:00:30Z")
    retention.prune_once(conn, retention_days=30, now=time.time())
    bucket = retention._bucket_ts(ev1["recv_ts"])  # I2: bucketed by recv_ts, not ts
    row = conn.execute(
        "SELECT n FROM rollups_hourly WHERE bucket_ts = ? AND kind = 'stop'",
        (bucket,),
    ).fetchone()
    assert row["n"] == 2  # not two separate rows of n=1


def test_prune_once_keeps_recent_rows(isolated_state):
    import datetime
    recent = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _insert_old("s1", "stop", {}, recent)
    conn = store.get_conn()
    retention.prune_once(conn, retention_days=30, now=time.time())
    assert store.count_events() == 1


def test_prune_once_uses_recv_ts_not_ts_for_cutoff(isolated_state):
    """I2: recv_ts (server clock) is authoritative, not ts (emitter clock).
    A row with an old `ts` but a fresh `recv_ts` must survive -- an emitter
    with a wrong clock (or clock skew) must not get its events silently
    pruned right after ingest."""
    conn = store.get_conn()
    ev = _insert_old("s1", "stop", {}, "2020-01-01T00:00:00Z")  # ts: far in the past
    # insert_event always stamps recv_ts = now -- leave it alone, it's recent.
    row = conn.execute("SELECT recv_ts FROM events WHERE session_id = 's1'").fetchone()
    assert row["recv_ts"]  # sanity: recv_ts really is set and recent

    retention.prune_once(conn, retention_days=30, now=time.time())

    assert store.count_events() == 1  # NOT pruned -- recv_ts wins over the stale ts


def test_prune_once_falls_back_to_ts_when_recv_ts_is_null(isolated_state):
    """I2 fallback: pre-migration rows (recv_ts IS NULL, from before Task 1/2
    landed) must still be prunable via their ts."""
    conn = store.get_conn()
    _insert_old("s1", "stop", {}, "2020-01-01T00:00:00Z")
    conn.execute("UPDATE events SET recv_ts = NULL WHERE session_id = 's1'")
    conn.commit()
    row = conn.execute("SELECT recv_ts, ts FROM events WHERE session_id = 's1'").fetchone()
    assert row["recv_ts"] is None and row["ts"] == "2020-01-01T00:00:00Z"

    retention.prune_once(conn, retention_days=30, now=time.time())

    assert store.count_events() == 0  # pruned via the ts fallback


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


def test_latest_backup_mtime_finds_newest_backup(tmp_path):
    backups = tmp_path / "backups"
    backups.mkdir()
    older = backups / "hud-20260101-000000-000000.db"
    newer = backups / "hud-20260102-000000-000000.db"
    older.write_bytes(b"x")
    newer.write_bytes(b"x")
    old_t = time.time() - 3600
    os.utime(older, (old_t, old_t))
    new_t = time.time()
    os.utime(newer, (new_t, new_t))

    result = retention.latest_backup_mtime(backups)
    assert result == pytest.approx(newer.stat().st_mtime)


def test_latest_backup_mtime_empty_or_missing_dir_returns_none(tmp_path):
    empty = tmp_path / "empty-backups"
    empty.mkdir()
    assert retention.latest_backup_mtime(empty) is None
    assert retention.latest_backup_mtime(tmp_path / "does-not-exist") is None


def test_should_vacuum():
    now = 1_000_000.0
    assert retention.should_vacuum(None, now) is True
    assert retention.should_vacuum(now - 86400, now) is False  # 1 day: not yet
    assert retention.should_vacuum(now - 8 * 86400, now) is True  # 8 days: due


def test_prune_once_enforces_hud_max_rows_by_deleting_oldest_first(isolated_state):
    """I5 item 1: HUD_MAX_ROWS is a second, row-count-based bound on top of
    the time-based retention -- whichever binds first. Excess oldest rows
    (by id) get rolled into rollups_hourly, not just deleted."""
    conn = store.get_conn()
    recent = "2026-09-12T00:00:00Z"
    for i in range(12):
        _insert_old("s1", "stop", {}, recent)

    result = retention.prune_once(conn, retention_days=30, now=time.time(), max_rows=5)

    assert store.count_events() <= 5
    assert result["deleted"] == 7
    row = conn.execute("SELECT SUM(n) AS total FROM rollups_hourly WHERE kind = 'stop'").fetchone()
    assert row["total"] == 7  # rolled up, not just dropped


def test_prune_once_without_max_rows_does_not_enforce_a_count_bound(isolated_state):
    conn = store.get_conn()
    recent = "2026-09-12T00:00:00Z"
    for i in range(5):
        _insert_old("s1", "stop", {}, recent)
    retention.prune_once(conn, retention_days=30, now=time.time())
    assert store.count_events() == 5


def test_prune_once_incremental_vacuum_runs_without_error(isolated_state):
    """I5 item 2: incremental_vacuum must run cleanly against a real DB
    (auto_vacuum=INCREMENTAL is set once at migration time -- see
    hud/tests/test_migrations.py) after both prune passes, without raising
    and without corrupting the database."""
    conn = store.get_conn()
    assert conn.execute("PRAGMA auto_vacuum").fetchone()[0] == 2
    old_ts = "2020-01-01T00:00:00Z"
    for i in range(5):
        _insert_old("s1", "stop", {}, old_ts)
    for i in range(5):
        _insert_old("s2", "stop", {}, "2026-09-12T00:00:00Z")

    retention.prune_once(conn, retention_days=30, now=time.time(), max_rows=2)

    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    assert integrity == "ok"


def test_prune_once_incremental_vacuum_drains_the_freelist(isolated_state):
    """C-1: `conn.execute("PRAGMA incremental_vacuum")` with the cursor
    discarded performs exactly ONE sqlite3_step and returns -- it reclaims
    only ONE freelist page per call, no matter how many pages the DELETE
    just freed. `PRAGMA integrity_check == 'ok'` (the previous version of
    this test) passes just as well against that buggy one-step call as
    against a real fix -- it doesn't corrupt the DB, it just leaves the
    freelist almost entirely undrained. This is the assertion that actually
    catches a regression back to that bug: freelist_count must come back
    down to (near) zero after a prune that puts many pages on the freelist,
    not merely "didn't raise, didn't corrupt anything"."""
    conn = store.get_conn()
    assert conn.execute("PRAGMA auto_vacuum").fetchone()[0] == 2
    old_ts = "2020-01-01T00:00:00Z"
    big_payload = {"message": "x" * 500}
    for i in range(3000):
        _insert_old("s%d" % i, "stop", big_payload, old_ts)
    # Bulk-backdate recv_ts (I2's authoritative clock) so the cutoff pass
    # actually prunes these rows -- see _insert_fully_old's docstring above;
    # done as one UPDATE here (not per-row like _insert_fully_old) purely so
    # 3000 rows insert fast enough for a unit test.
    conn.execute("UPDATE events SET recv_ts = ts")
    conn.commit()

    result = retention.prune_once(conn, retention_days=30, now=time.time())
    assert result["deleted"] == 3000

    freelist_count = conn.execute("PRAGMA freelist_count").fetchone()[0]
    assert freelist_count <= 1, (
        "freelist_count=%d after prune -- incremental_vacuum did not drain "
        "the freelist (regression to the one-step-per-call bug, C-1)" % freelist_count
    )
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    assert integrity == "ok"


def test_vacuum_now_runs_without_error(isolated_state):
    conn = store.get_conn()
    _insert_old("s1", "stop", {}, "2026-09-12T00:00:00Z")
    retention.vacuum_now(conn)
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    assert integrity == "ok"


def test_latest_vacuum_mtime_returns_none_when_marker_missing(tmp_path):
    empty = tmp_path / "empty-backups"
    empty.mkdir()
    assert retention.latest_vacuum_mtime(empty) is None
    assert retention.latest_vacuum_mtime(tmp_path / "does-not-exist") is None


def test_vacuum_now_writes_marker_and_latest_vacuum_mtime_finds_it(isolated_state, tmp_path):
    """I-2: vacuum_now(conn, backups_dir) touches a marker file after the
    VACUUM completes, and latest_vacuum_mtime reads it back -- the same
    seeding shape as latest_backup_mtime/backup_now (I4), so a crash-looping
    process seeds _last_vacuum_ts from disk instead of re-VACUUMing on every
    restart."""
    conn = store.get_conn()
    _insert_old("s1", "stop", {}, "2026-09-12T00:00:00Z")
    backups = tmp_path / "backups"
    assert retention.latest_vacuum_mtime(backups) is None  # nothing yet

    retention.vacuum_now(conn, backups)

    marker = retention.vacuum_marker_path(backups)
    assert marker.is_file()
    result = retention.latest_vacuum_mtime(backups)
    assert result == pytest.approx(marker.stat().st_mtime)


def test_vacuum_now_without_backups_dir_does_not_write_a_marker(isolated_state):
    """Backward-compat: the pre-existing `retention.vacuum_now(conn)` call
    shape (no backups_dir) still works and simply skips marker bookkeeping."""
    conn = store.get_conn()
    _insert_old("s1", "stop", {}, "2026-09-12T00:00:00Z")
    retention.vacuum_now(conn)  # no backups_dir -- must not raise
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    assert integrity == "ok"


def test_row_clock_falls_back_only_on_none_not_empty_string():
    """M-3: _row_clock must match the SQL cutoff query's
    COALESCE(recv_ts, ts) exactly -- COALESCE only falls back on NULL, and
    treats '' as a real (kept) value. The old `recv_ts or ts` implementation
    would have wrongly fallen back to `ts` for an empty-string recv_ts."""
    assert retention._row_clock({"recv_ts": None, "ts": "TS"}) == "TS"
    assert retention._row_clock({"recv_ts": "RECV", "ts": "TS"}) == "RECV"
    assert retention._row_clock({"recv_ts": "", "ts": "TS"}) == ""


def test_env_int_returns_default_when_var_unset(monkeypatch):
    monkeypatch.delenv("HUD_TESTVAR_NOPE", raising=False)
    assert retention.env_int("HUD_TESTVAR_NOPE", 42) == 42


def test_env_int_parses_a_valid_value(monkeypatch):
    monkeypatch.setenv("HUD_TESTVAR_NOPE", "7")
    assert retention.env_int("HUD_TESTVAR_NOPE", 42) == 7


def test_env_int_falls_back_and_warns_on_a_bad_value(monkeypatch, caplog):
    """M-6: a typo'd HUD_MAX_ROWS/HUD_RETENTION_DAYS must not raise and take
    the whole retention cycle down with it -- fall back to the documented
    default and log a warning instead."""
    monkeypatch.setenv("HUD_TESTVAR_NOPE", "not-a-number")
    with caplog.at_level("WARNING", logger="hud"):
        assert retention.env_int("HUD_TESTVAR_NOPE", 42) == 42
    assert any("HUD_TESTVAR_NOPE" in rec.message for rec in caplog.records)
