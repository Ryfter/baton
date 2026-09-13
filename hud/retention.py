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

Cutoff clock (I2, spec §8.6): `recv_ts` (server-assigned on ingest, never
client-settable) is authoritative for both the prune cutoff and the hourly
rollup bucket. `ts` (emitter-supplied, accepted from any parseable client
ISO-8601 value -- see `_coerce_ts` in hud/server.py) is only a fallback for
rows written before the M1 migration added `recv_ts` (those have
`recv_ts IS NULL`). Cutoff and bucketing use the SAME `COALESCE(recv_ts, ts)`
value for a given row -- diverging them (cutoff on one clock, bucket on the
other) would let a bad emitter clock skew the rollup bucket even though it
can no longer skew *whether* the row survives.
"""
from __future__ import annotations

import datetime
import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Optional

from hud import store

RETENTION_DAYS_DEFAULT = 30
MAX_ROWS_DEFAULT = 2_000_000
BATCH_SIZE = 10_000
PRUNE_INTERVAL_S = 3600
BACKUP_KEEP_DEFAULT = 7
BACKUP_MIN_INTERVAL_S = 20 * 3600  # "nightly", without needing calendar-day bookkeeping
VACUUM_MIN_INTERVAL_S = 7 * 86400  # "weekly", without needing exact wall-clock scheduling
VACUUM_MARKER_NAME = ".last-vacuum"

_ROW_COLUMNS = "id, ts, recv_ts, machine, source, kind, payload"


def _iso(ts: float) -> str:
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _bucket_ts(ts: str) -> str:
    """Floor an ISO-8601 UTC timestamp ('...THH:MM:SSZ') to the top of its hour."""
    return ts[:13] + ":00:00Z" if len(ts) >= 13 else ts


def _row_clock(row: sqlite3.Row) -> str:
    """The authoritative clock for a row: recv_ts when present, else ts (I2)."""
    return row["recv_ts"] or row["ts"]


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


def _prune_rows(conn: sqlite3.Connection, rows: list[sqlite3.Row]) -> tuple[int, int]:
    """Roll `rows` into rollups_hourly and delete them, in one transaction.
    Shared by both the time-cutoff pass and the row-count-excess pass (I5) so
    the two prune paths can never diverge in how they aggregate data. Returns
    (deleted, buckets_touched)."""
    if not rows:
        return 0, 0
    agg: dict[tuple, list] = {}
    ids: list[int] = []
    for row in rows:
        ids.append(row["id"])
        bucket = _bucket_ts(_row_clock(row))
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
        # Reclaim the pages just freed by the DELETE above. A no-op unless
        # auto_vacuum=INCREMENTAL is in effect (see
        # migrations._ensure_auto_vacuum_incremental, applied once at DB
        # creation/migration time) -- see I5 item 2 in the follow-up report
        # for the full auto_vacuum investigation.
        #
        # C-1: `PRAGMA incremental_vacuum` is *row-stepped* -- sqlite3's
        # Connection.execute() performs exactly one sqlite3_step and returns,
        # so a bare `conn.execute(...)` with the cursor discarded frees only
        # ONE page per call, no matter how many pages are on the freelist.
        # list(...) (or executescript, equivalently) drives the statement to
        # completion, actually draining the freelist. Verified empirically: a
        # 4000-row prune that put 598 pages on the freelist only reclaimed 1
        # of them (0.2%) with the bare-execute form.
        list(conn.execute("PRAGMA incremental_vacuum"))
    return len(ids), len(agg)


def prune_once(conn: sqlite3.Connection, *, retention_days: int = RETENTION_DAYS_DEFAULT,
               now: Optional[float] = None, max_rows: Optional[int] = None) -> dict[str, int]:
    now = time.time() if now is None else now
    cutoff = _iso(now - retention_days * 86400)
    deleted = 0
    buckets_touched = 0

    # Pass 1: time-based retention. COALESCE(recv_ts, ts) makes the trustworthy,
    # server-assigned recv_ts authoritative while still pruning pre-migration
    # rows (recv_ts IS NULL) via their emitter-supplied ts (I2).
    while True:
        rows = conn.execute(
            "SELECT %s FROM events WHERE COALESCE(recv_ts, ts) < ? ORDER BY id ASC LIMIT ?"
            % _ROW_COLUMNS,
            (cutoff, BATCH_SIZE),
        ).fetchall()
        if not rows:
            break
        d, b = _prune_rows(conn, rows)
        deleted += d
        buckets_touched += b
        if len(rows) < BATCH_SIZE:
            break

    # Pass 2 (I5): hard row-count bound, "whichever binds first" per spec
    # §5.3. Oldest rows first (id ASC), rolled up the same way as pass 1.
    if max_rows is not None:
        while True:
            total = conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
            excess = total - max_rows
            if excess <= 0:
                break
            rows = conn.execute(
                "SELECT %s FROM events ORDER BY id ASC LIMIT ?" % _ROW_COLUMNS,
                (min(BATCH_SIZE, excess),),
            ).fetchall()
            if not rows:
                break
            d, b = _prune_rows(conn, rows)
            deleted += d
            buckets_touched += b

    return {"deleted": deleted, "buckets_touched": buckets_touched}


def backup_dir() -> Path:
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


def latest_backup_mtime(backups_dir: Path) -> Optional[float]:
    """Newest mtime among existing hud-*.db backups, or None if there are
    none yet (or the directory doesn't exist). Used to seed _last_backup_ts
    at startup (I4) so a crash-looping process doesn't take a fresh backup
    -- and rotate away real history -- on every restart."""
    if not backups_dir.is_dir():
        return None
    mtimes = [p.stat().st_mtime for p in backups_dir.glob("hud-*.db")]
    return max(mtimes) if mtimes else None


def should_backup(last_backup_ts: Optional[float], now: float) -> bool:
    return last_backup_ts is None or (now - last_backup_ts) >= BACKUP_MIN_INTERVAL_S


def should_vacuum(last_vacuum_ts: Optional[float], now: float) -> bool:
    """Same shape as should_backup: a full VACUUM is due once 7+ days have
    elapsed since the last one (I5 item 3) -- simpler and more robust than
    trying to hit an exact 04:11 wall-clock time from an hourly loop."""
    return last_vacuum_ts is None or (now - last_vacuum_ts) >= VACUUM_MIN_INTERVAL_S


def vacuum_marker_path(backups_dir: Path) -> Path:
    return backups_dir / VACUUM_MARKER_NAME


def latest_vacuum_mtime(backups_dir: Path) -> Optional[float]:
    """Mtime of the vacuum marker file, or None if a VACUUM has never run (or
    `backups_dir` doesn't exist yet). Used to seed _last_vacuum_ts at startup
    (I-2), the same way latest_backup_mtime seeds _last_backup_ts (I4): a
    process's own _last_vacuum_ts starts None on every restart, and the
    retention loop runs its body before its first sleep, so without a
    persisted marker a launchd crash-loop (restart every ~10s) would fire a
    full VACUUM -- a real, possibly-long file rewrite -- on every single
    restart. A marker file is used rather than the main DB file's own mtime
    because ordinary writes touch that mtime constantly, which would make it
    useless as a "was a VACUUM the last thing that touched this file"
    signal."""
    try:
        return vacuum_marker_path(backups_dir).stat().st_mtime
    except OSError:
        return None


def vacuum_now(conn: sqlite3.Connection, backups_dir: Optional[Path] = None) -> None:
    with store._lock:
        conn.execute("VACUUM")
    if backups_dir is not None:
        # Touch the marker (I-2) after releasing the lock -- this is bookkeeping
        # for the *next* process startup's should_vacuum() decision, not part of
        # the VACUUM transaction itself, so it doesn't need store._lock held.
        backups_dir.mkdir(parents=True, exist_ok=True)
        vacuum_marker_path(backups_dir).touch()
