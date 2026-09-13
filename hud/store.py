"""SQLite event store. seq is per-session, monotonic, assigned here under a lock."""
from __future__ import annotations

import json
import os
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from hud import migrations
from hud.schema import validate_envelope

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
    migrations.migrate(c)


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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
        "event_uid": row["event_uid"],
        "recv_ts": row["recv_ts"],
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
    """Assign seq + recv_ts under a lock/transaction, persist, return id.
    Mutates event['seq'], event['recv_ts'], event['dup'].
    A duplicate event_uid returns the EXISTING row's id/seq and sets dup=True."""
    with _lock:
        conn = get_conn()
        try:
            conn.execute("BEGIN IMMEDIATE")
            session_id = event["session_id"]
            event["seq"] = _next_seq(conn, session_id)
            event["recv_ts"] = _utcnow_iso()
            validate_envelope(event)
            event_uid = event.get("event_uid")
            cur = conn.execute(
                """
                INSERT OR IGNORE INTO events
                  (ts, session_id, source, kind, agent, seq, machine, payload, event_uid, recv_ts)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    event_uid,
                    event["recv_ts"],
                ),
            )
            if cur.rowcount == 0 and event_uid:
                existing = conn.execute(
                    "SELECT id, seq FROM events WHERE event_uid = ?", (event_uid,)
                ).fetchone()
                if existing is not None:
                    conn.commit()
                    event["dup"] = True
                    event["seq"] = int(existing["seq"])
                    return int(existing["id"])
                # The INSERT OR IGNORE was ignored for some reason OTHER than a live
                # event_uid conflict (e.g. a different constraint violation) -- no row
                # with this event_uid actually exists to have returned here. Retry a
                # real INSERT so any real problem raises loudly instead of silently
                # vanishing.
                cur = conn.execute(
                    """
                    INSERT INTO events (ts, session_id, source, kind, agent, seq, machine, payload, event_uid, recv_ts)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        event_uid,
                        event["recv_ts"],
                    ),
                )
            event["dup"] = False
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


def count_events_since_recv(cutoff_ts: str) -> int:
    with _lock:
        conn = get_conn()
        row = conn.execute("SELECT COUNT(*) FROM events WHERE recv_ts >= ?", (cutoff_ts,)).fetchone()
    return int(row[0] if row else 0)


def max_recv_ts() -> Optional[str]:
    with _lock:
        conn = get_conn()
        row = conn.execute("SELECT MAX(recv_ts) FROM events").fetchone()
    return row[0] if row and row[0] else None
