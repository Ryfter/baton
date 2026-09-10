"""SQLite event store. seq is per-session, monotonic, assigned here under a lock."""
from __future__ import annotations

import json
import os
import sqlite3
import threading
from pathlib import Path
from typing import Any, Optional

from hud.schema import validate_envelope

DDL = """
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
);
CREATE INDEX IF NOT EXISTS ix_events_session ON events(session_id);
CREATE INDEX IF NOT EXISTS ix_events_kind    ON events(kind);
CREATE INDEX IF NOT EXISTS ix_events_ts      ON events(ts);
CREATE INDEX IF NOT EXISTS ix_events_session_seq ON events(session_id, seq);
"""

_lock = threading.Lock()
_conn: Optional[sqlite3.Connection] = None


def db_path() -> Path:
    env = os.environ.get("HUD_DB")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent / "hud.db"


def reset() -> None:
    """Close the cached connection (tests)."""
    global _conn
    with _lock:
        if _conn is not None:
            try:
                _conn.close()
            except sqlite3.Error:
                pass
            _conn = None


def get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        path = db_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        _conn = conn
        init_db(conn)
    return _conn


def init_db(conn: Optional[sqlite3.Connection] = None) -> None:
    c = conn if conn is not None else get_conn()
    c.executescript(DDL)
    c.commit()


def _row_to_event(row: sqlite3.Row) -> dict[str, Any]:
    payload_raw = row["payload"]
    try:
        payload = json.loads(payload_raw) if payload_raw else {}
    except json.JSONDecodeError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    return {
        "id": row["id"],
        "schema": "hud.event/v1",
        "ts": row["ts"],
        "session_id": row["session_id"],
        "source": row["source"],
        "kind": row["kind"],
        "agent": row["agent"],
        "seq": row["seq"],
        "machine": row["machine"],
        "payload": payload,
    }


def _next_seq(conn: sqlite3.Connection, session_id: str) -> int:
    row = conn.execute(
        "SELECT MAX(seq) FROM events WHERE session_id = ?",
        (session_id,),
    ).fetchone()
    current = row[0] if row is not None else None
    return int(current or 0) + 1


def insert_event(event: dict[str, Any]) -> int:
    """Assign seq under a lock/transaction, persist, return id. Mutates event['seq']."""
    with _lock:
        conn = get_conn()
        try:
            conn.execute("BEGIN IMMEDIATE")
            session_id = event["session_id"]
            event["seq"] = _next_seq(conn, session_id)
            validate_envelope(event)
            cur = conn.execute(
                """
                INSERT INTO events (ts, session_id, source, kind, agent, seq, machine, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event["ts"],
                    event["session_id"],
                    event["source"],
                    event["kind"],
                    event.get("agent"),
                    event["seq"],
                    event.get("machine"),
                    json.dumps(event.get("payload") or {}, ensure_ascii=False),
                ),
            )
            conn.commit()
            return int(cur.lastrowid)
        except Exception:
            try:
                conn.rollback()
            except sqlite3.Error:
                pass
            raise


def query_events(
    *,
    since: Optional[int] = None,
    limit: Optional[int] = None,
    session: Optional[str] = None,
    kind: Optional[str] = None,
) -> list[dict[str, Any]]:
    cap = 2000
    n = cap if limit is None else max(0, min(int(limit), cap))
    sql = "SELECT * FROM events WHERE 1=1"
    args: list[Any] = []
    if since is not None:
        sql += " AND id > ?"
        args.append(int(since))
    if session:
        sql += " AND session_id = ?"
        args.append(session)
    if kind:
        sql += " AND kind = ?"
        args.append(kind)
    sql += " ORDER BY id ASC LIMIT ?"
    args.append(n)
    with _lock:
        conn = get_conn()
        rows = conn.execute(sql, args).fetchall()
    return [_row_to_event(r) for r in rows]


def replay_events(n: int = 200) -> list[dict[str, Any]]:
    n = max(0, min(int(n), 2000))
    if n == 0:
        return []
    with _lock:
        conn = get_conn()
        rows = conn.execute(
            "SELECT * FROM events ORDER BY id DESC LIMIT ?",
            (n,),
        ).fetchall()
    events = [_row_to_event(r) for r in rows]
    events.reverse()
    return events


def count_events() -> int:
    with _lock:
        conn = get_conn()
        row = conn.execute("SELECT COUNT(*) FROM events").fetchone()
    return int(row[0] if row else 0)
