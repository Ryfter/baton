"""Ordered, forward-only schema migrations, gated on PRAGMA user_version.

Never drop or rename a column here — a rolled-back binary must still be able
to read the file. Version numbers are plain sequential integers; they are
NOT the same thing as the spec's milestone labels (a later version may land
in an earlier milestone than its "m2/m3/m4" SQL-comment grouping in the
design doc suggests — see docs/superpowers/specs/2026-09-10-hud-dashboard-buildout-design.md §5.1).
"""
from __future__ import annotations

import sqlite3

Migration = tuple[int, list[str]]

MIGRATIONS: list[Migration] = [
    (1, [
        # Baseline schema — verbatim from the original hud/store.py DDL.
        """
        CREATE TABLE IF NOT EXISTS events (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          ts         TEXT NOT NULL,
          session_id TEXT NOT NULL,
          source     TEXT NOT NULL,
          kind       TEXT NOT NULL,
          agent      TEXT,
          seq        INTEGER NOT NULL,
          machine    TEXT,
          payload    TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS ix_events_session ON events(session_id)",
        "CREATE INDEX IF NOT EXISTS ix_events_kind ON events(kind)",
        "CREATE INDEX IF NOT EXISTS ix_events_ts ON events(ts)",
        "CREATE INDEX IF NOT EXISTS ix_events_session_seq ON events(session_id, seq)",
    ]),
    (2, [
        # M1: event_uid dedup key + server-assigned arrival time.
        "ALTER TABLE events ADD COLUMN event_uid TEXT",
        "ALTER TABLE events ADD COLUMN recv_ts TEXT",
        "CREATE UNIQUE INDEX IF NOT EXISTS ux_events_uid ON events(event_uid) WHERE event_uid IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS ix_events_recv ON events(recv_ts)",
    ]),
    (3, [
        # M1 (pulled forward from the spec's "m4" bucket): the retention
        # pruner needs somewhere to roll stale rows into before deleting them.
        """
        CREATE TABLE IF NOT EXISTS rollups_hourly (
          bucket_ts TEXT, machine TEXT, source TEXT, kind TEXT, project TEXT, model TEXT,
          n INTEGER, n_errors INTEGER, tokens_in INTEGER, tokens_out INTEGER, cost_usd REAL,
          PRIMARY KEY (bucket_ts, machine, source, kind, project, model)
        )
        """,
    ]),
    # Next version is 4 — reserved for M2's project/job_id/run_id columns +
    # ix_events_mach_ts / ix_events_src_kind / ix_events_project indexes.
    # Version 5 is reserved for M3/M4's `sessions` projection table.
]


def current_version(conn: sqlite3.Connection) -> int:
    row = conn.execute("PRAGMA user_version").fetchone()
    return int(row[0]) if row else 0


def migrate(conn: sqlite3.Connection) -> int:
    """Apply every pending migration, each in its own transaction. Returns the final version."""
    version = current_version(conn)
    for target, statements in MIGRATIONS:
        if target <= version:
            continue
        conn.execute("BEGIN IMMEDIATE")
        try:
            for stmt in statements:
                conn.execute(stmt)
            conn.execute("PRAGMA user_version = %d" % target)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        version = target
    return version
