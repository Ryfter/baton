"""Hourly retention pruning (raw events -> rollups_hourly) and nightly SQLite backup.

project/model are normalized to "" (never None) when writing rollups_hourly:
SQLite's composite PRIMARY KEY treats every NULL as distinct from every other
NULL, so a None-valued column would defeat the upsert and create a fresh row
on every prune pass instead of accumulating into one.

Locking: prune_once and backup_now run on a background asyncio task via
asyncio.to_thread, i.e. on a real OS thread, concurrently with request-handling
threads calling store.insert_event on the SAME shared sqlite3.Connection.
store.insert_event always wraps its writes in `with store._lock:` around a
BEGIN IMMEDIATE ... commit/rollback block. To avoid two threads interleaving
multi-statement transactions on one connection, prune_once and backup_now take
the same lock at the same granularity (one `with store._lock:` per batch in
prune_once; the whole body in backup_now) -- per controller instruction.
"""
from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path
from typing import Any, Optional

from hud import store

RETENTION_DAYS_DEFAULT = 30
BATCH_SIZE = 10_000
PRUNE_INTERVAL_S = 3600
BACKUP_KEEP_DEFAULT = 7
BACKUP_MIN_INTERVAL_S = 20 * 3600  # "nightly", without needing calendar-day bookkeeping


def _iso(ts: float) -> str:
    import datetime
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _bucket_ts(ts: str) -> str:
    """Floor an ISO-8601 UTC timestamp ('...THH:MM:SSZ') to the top of its hour."""
    return ts[:13] + ":00:00Z" if len(ts) >= 13 else ts


def _row_stats(payload_json: str) -> tuple[bool, int, int, float]:
    try:
        payload = json.loads(payload_json) if payload_json else {}
    except json.JSONDecodeError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    is_error = bool(payload.get("error")) or payload.get("ok") is False
    tokens_in = int(payload.get("tokens_in") or 0)
    tokens_out = int(payload.get("tokens_out") or 0)
    cost_usd = float(payload.get("cost_usd") or 0.0)
    return is_error, tokens_in, tokens_out, cost_usd


def prune_once(conn: sqlite3.Connection, *, retention_days: int = RETENTION_DAYS_DEFAULT,
               now: Optional[float] = None) -> dict[str, int]:
    now = time.time() if now is None else now
    cutoff = _iso(now - retention_days * 86400)
    deleted = 0
    buckets_touched = 0
    while True:
        rows = conn.execute(
            "SELECT id, ts, machine, source, kind, payload FROM events WHERE ts < ? ORDER BY id ASC LIMIT ?",
            (cutoff, BATCH_SIZE),
        ).fetchall()
        if not rows:
            break
        agg: dict[tuple, list] = {}
        ids: list[int] = []
        for row in rows:
            ids.append(row["id"])
            bucket = _bucket_ts(row["ts"])
            key = (bucket, row["machine"] or "", row["source"] or "", row["kind"] or "", "", "")
            is_error, tin, tout, cost = _row_stats(row["payload"])
            cell = agg.setdefault(key, [0, 0, 0, 0, 0.0])
            cell[0] += 1
            cell[1] += 1 if is_error else 0
            cell[2] += tin
            cell[3] += tout
            cell[4] += cost
        with store._lock:
            conn.execute("BEGIN IMMEDIATE")
            try:
                for (bucket, machine, source, kind, project, model), (n, n_err, tin, tout, cost) in agg.items():
                    conn.execute(
                        """
                        INSERT INTO rollups_hourly (bucket_ts, machine, source, kind, project, model,
                                                     n, n_errors, tokens_in, tokens_out, cost_usd)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(bucket_ts, machine, source, kind, project, model) DO UPDATE SET
                          n = n + excluded.n,
                          n_errors = n_errors + excluded.n_errors,
                          tokens_in = tokens_in + excluded.tokens_in,
                          tokens_out = tokens_out + excluded.tokens_out,
                          cost_usd = cost_usd + excluded.cost_usd
                        """,
                        (bucket, machine, source, kind, project, model, n, n_err, tin, tout, cost),
                    )
                conn.executemany("DELETE FROM events WHERE id = ?", [(i,) for i in ids])
                conn.commit()
            except Exception:
                conn.rollback()
                raise
        deleted += len(ids)
        buckets_touched += len(agg)
        if len(rows) < BATCH_SIZE:
            break
    return {"deleted": deleted, "buckets_touched": buckets_touched}


def backup_dir() -> Path:
    import os
    env = os.environ.get("HUD_BACKUP_DIR")
    if env:
        return Path(env)
    return store.db_path().parent / "backups"


def backup_now(conn: sqlite3.Connection, backups_dir: Path, *, keep: int = BACKUP_KEEP_DEFAULT) -> Path:
    with store._lock:
        backups_dir.mkdir(parents=True, exist_ok=True)
        now_s = time.time()
        # Second-resolution alone collides when called repeatedly in a tight
        # loop (e.g. tests, or a caller retrying); a zero-padded microsecond
        # suffix keeps filenames unique while preserving lexical/chronological
        # sort order (deviation from the brief's plain %H%M%S stamp -- found
        # via test_backup_now_creates_restorable_copy_and_keeps_n failing
        # deterministically with 3 backups in one second).
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(now_s)) + (
            "-%06d" % int((now_s % 1) * 1_000_000)
        )
        dest_path = backups_dir / ("hud-%s.db" % stamp)
        dest_conn = sqlite3.connect(str(dest_path))
        try:
            conn.backup(dest_conn)
        finally:
            dest_conn.close()
        existing = sorted(backups_dir.glob("hud-*.db"))
        if len(existing) > keep:
            for old in existing[: len(existing) - keep]:
                try:
                    old.unlink()
                except OSError:
                    pass
        return dest_path


def should_backup(last_backup_ts: Optional[float], now: float) -> bool:
    return last_backup_ts is None or (now - last_backup_ts) >= BACKUP_MIN_INTERVAL_S
