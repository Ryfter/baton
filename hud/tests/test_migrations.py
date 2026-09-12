import sqlite3

from hud import migrations


def _fresh_conn(tmp_path):
    conn = sqlite3.connect(str(tmp_path / "m.db"), isolation_level=None)
    conn.row_factory = sqlite3.Row
    return conn


def test_fresh_db_migrates_to_latest_version(tmp_path):
    conn = _fresh_conn(tmp_path)
    latest = migrations.MIGRATIONS[-1][0]
    result = migrations.migrate(conn)
    assert result == latest
    assert migrations.current_version(conn) == latest
    # baseline table + both pulled-forward pieces all exist
    conn.execute("INSERT INTO events (ts, session_id, source, kind, agent, seq, machine, payload, event_uid, recv_ts) "
                 "VALUES ('t','s','claude-hook','stop','main',1,'m','{}',NULL,'t')")
    conn.execute("SELECT bucket_ts, machine, source, kind, project, model, n, n_errors, tokens_in, tokens_out, cost_usd "
                 "FROM rollups_hourly")


def test_migrate_is_idempotent(tmp_path):
    conn = _fresh_conn(tmp_path)
    migrations.migrate(conn)
    v1 = migrations.current_version(conn)
    migrations.migrate(conn)  # running again must not re-run ALTER TABLE and blow up
    assert migrations.current_version(conn) == v1


def test_preexisting_db_without_user_version_upgrades_cleanly(tmp_path):
    """A DB created by the old store.py (static DDL, no migrations, user_version=0)
    must upgrade in place without losing its rows."""
    conn = _fresh_conn(tmp_path)
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, session_id TEXT NOT NULL,
          source TEXT NOT NULL, kind TEXT NOT NULL, agent TEXT, seq INTEGER NOT NULL,
          machine TEXT, payload TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS ix_events_session ON events(session_id);
        """
    )
    conn.execute(
        "INSERT INTO events (ts, session_id, source, kind, agent, seq, machine, payload) "
        "VALUES ('t','pre-existing','claude-hook','stop','main',1,'m','{}')"
    )
    migrations.migrate(conn)
    row = conn.execute("SELECT event_uid, recv_ts FROM events WHERE session_id='pre-existing'").fetchone()
    assert row is not None
    assert row["event_uid"] is None and row["recv_ts"] is None  # new columns, old row untouched
