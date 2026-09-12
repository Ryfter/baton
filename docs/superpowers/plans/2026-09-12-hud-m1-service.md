# HUD M1 — "The HUD becomes a service" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the shipped, security-hardened HUD prototype (branch `hud-prototype-grok` @ `3a5624a`) into a durable local service on droid — survives reboots, never loses events across a crash/restart, stops its database from growing forever, and ships with `sapphire` as the default theme instead of `dark`.

**Architecture:** No new components, no new processes yet (multi-machine, adapters, and derived state are M2+). M1 hardens the single-box FastAPI + SQLite service that already exists: a forward-only migrations framework, a `recv_ts`/`event_uid`-aware ingest path, an `/healthz` that says more than "ok", `Last-Event-ID` SSE resume so a restart is invisible to a connected browser, an hourly retention pruner + nightly backup so the DB has a ceiling, a `baton hud {serve,status,install-service,rebuild}` CLI wired through the existing `baton` verb dispatcher, and a macOS launchd unit so it survives a reboot unattended.

**Tech Stack:** Python 3.14, FastAPI 0.141.1, uvicorn 0.52.4 (`[standard]`), stdlib `sqlite3` (WAL mode), pytest 9.1.1, httpx 0.28.1 (TestClient). `baton`'s CLI dispatcher (`scripts/baton.ps1` + `scripts/verbs.yaml`, PowerShell) as a thin passthrough — no logic lives in PowerShell. No new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-10-hud-dashboard-buildout-design.md` (rev 3, commit `aff5c73`) — read §1 (purpose), §2.3 (file layout), §5.1–5.3 (storage/migrations/retention), §6.4 (SSE resume), §7.3 (`/healthz` route), §8.1 (security baseline that must not regress), §8.5 (service management), §9.4 (theme default), §13 M1, §14 D1–D16. Also read the prototype spec `docs/superpowers/specs/2026-09-09-hud-prototype-design.md` for the envelope/route shape M1 must not break.

## Global Constraints

- **Security baseline must never regress** (spec §8.1): default bind `127.0.0.1`; off-loopback without `HUD_TOKEN` fails closed (401 everything) + loud warning; JSON-only `Content-Type` on writes (415 otherwise); cross-`Origin` write refused (403); `TrustedHostMiddleware` allowlist; 64 KB body cap; `_SEG_RE` path allowlist; `asyncio.to_thread` for every SQLite call from a route handler; `openapi_url=None`; `==`-pinned deps; `hmac.compare_digest` token comparison. Every task below runs the full existing 44-test suite before its commit, in addition to its own new tests.
- **Front-end invariant** (spec §8.1, §9.2): zero external network requests, no third-party libraries, no CDN, untrusted event data rendered via `textContent` only — never `innerHTML` with interpolation.
- **`hud/versions/v1..v4/` is FROZEN** — no task may edit anything under `hud/versions/`. Only the live `hud/frontends/*.html` change.
- **No new third-party dependencies.** `hud/requirements.txt` stays exactly `fastapi==0.141.1`, `uvicorn[standard]==0.52.4`, `httpx==0.28.1`, `pytest==9.1.1`. `sqlite3.Connection.backup()` (used for nightly backup) is stdlib.
- **`hook_emit.py`'s contract is unchanged** (spec §2.3): loopback-only, fail-open, 0.25s budget, always exits 0. No task in this plan touches it.
- **Migrations are forward-only, never drop a column** (spec §5.1) — every schema change here is `CREATE TABLE IF NOT EXISTS` or `ALTER TABLE ADD COLUMN`, gated on `PRAGMA user_version` so it runs exactly once per DB.
- **965-byte shell-argument ceiling** (`docs/agent-handoffs.md` #3): never pass a long string as one shell argument in any step's commands.
- **Decision capture**: any implementation-time judgment call this plan makes that isn't spelled out verbatim in the spec (there are three — noted inline in Tasks 1, 5, and 7) gets the file-based decision intake per `CLAUDE.md`, not just a plan comment.
- **Merging to master is Kevin's call, always** (`docs/agent-handoffs.md` #4). This plan's final task opens a PR; it does not merge to `master` itself.

## Setup (once, before Task 1)

The prototype code lives on branch `hud-prototype-grok` (pushed, `origin/hud-prototype-grok` @ `3a5624a`), not on `master` — `master` only carries the spec docs so far. Do the M1 work on a new branch cut from the prototype, in its own worktree:

```bash
cd /Users/kev/Dev/Baton
git fetch origin
git worktree add .worktrees/hud-m1 -b feat/hud-m1-service origin/hud-prototype-grok
cd .worktrees/hud-m1
python3 -m venv .venv && .venv/bin/pip install -r hud/requirements.txt
.venv/bin/python -m pytest hud/tests -q   # confirm the inherited 44 pass before touching anything
```

All file paths in the tasks below are relative to this worktree's repo root.

---

### Task 1: Migrations framework

**Files:**
- Create: `hud/migrations.py`
- Create: `hud/tests/test_migrations.py`
- Modify: `hud/store.py` (`init_db`, imports)

**Interfaces:**
- Produces: `hud.migrations.MIGRATIONS: list[tuple[int, list[str]]]`, `hud.migrations.current_version(conn: sqlite3.Connection) -> int`, `hud.migrations.migrate(conn: sqlite3.Connection) -> int` (applies pending migrations, returns the resulting version). `store.init_db()` now delegates schema creation to `migrations.migrate` instead of a static `executescript`.

**Decision point (capture it):** the spec's §5.1 SQL comments group changes under milestone labels ("m2: multi-machine + idempotency", "m3: board projection", "m4: retention survivors"). M1 needs the retention pruner working now (bullet in spec §13 M1), and the pruner writes into `rollups_hourly` — so this task pulls that table's creation forward into M1's migration set, while leaving the "m2" `project`/`job_id`/`run_id` columns/indexes and the "m3" `sessions` table genuinely deferred to M2/M3 (nothing in M1 reads or writes them yet). Migration **version numbers are sequential integers, independent of the spec's milestone labels** — that's what §5.1 already specifies ("an ordered list of `(version, [sql, …])`"). Capture this as a decision after Step 6 below.

- [ ] **Step 1: Write the failing tests**

```python
# hud/tests/test_migrations.py
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest hud/tests/test_migrations.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'hud.migrations'`

- [ ] **Step 3: Write `hud/migrations.py`**

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest hud/tests/test_migrations.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Wire `store.init_db` to the migrations framework**

In `hud/store.py`, replace the module-level `DDL` constant and `init_db` body:

```python
# Remove the `DDL = """..."""` constant entirely.

# Add near the top, with the other imports:
from hud import migrations

# Replace init_db:
def init_db(conn: Optional[sqlite3.Connection] = None) -> None:
    c = conn if conn is not None else get_conn()
    migrations.migrate(c)
```

- [ ] **Step 6: Run the full existing suite plus the new one**

Run: `.venv/bin/python -m pytest hud/tests -q`
Expected: `47 passed` (44 existing + 3 new), no regressions. `test_store.py`'s tests are unaffected since `insert_event`/`query_events`/`replay_events` signatures haven't changed yet.

- [ ] **Step 7: Capture the migration-scope decision**

```markdown
---
title: HUD M1 — pull rollups_hourly forward into M1's migrations, leave sessions/multi-machine columns at M2/M3
confidence: high
revisit-if: the retention pruner design changes to not need an hourly rollup table
project: baton
phase: hud-m1-service
---

**Chosen:** M1's migrations (versions 1-3) create the baseline `events` schema, add
`event_uid`/`recv_ts` columns + indexes, and create `rollups_hourly` — even though the
spec's §5.1 groups `rollups_hourly` under an "m4" SQL comment. `project`/`job_id`/`run_id`
columns (spec's "m2" bucket) and the `sessions` table ("m3" bucket) are deferred to
versions 4 and 5, landing with the milestones that actually read/write them.

**Alternatives:**
- Follow the spec's SQL-comment grouping literally, deferring `rollups_hourly` to M4 —
  rejected because M1's own exit criteria requires "DB stops growing without bound,"
  which needs the retention pruner working now, which needs somewhere to roll deleted
  rows into.
- Build the pruner without a rollup table (just delete stale rows, no history kept) —
  rejected: throws away D9's "hourly rollups forever" guarantee for the sake of a
  milestone-label purity that the spec itself doesn't actually mandate (§5.1 says
  migration version numbers are ordinal, not milestone-locked).

**Rationale:** The spec's own migration-numbering rule (§5.1: "an ordered list of
version, [sql, …]") already anticipates that version numbers and milestone labels
won't line up 1:1. Table creation is idempotent (`CREATE TABLE IF NOT EXISTS`) and the
table sits unused until M3's journal adapter starts writing `tokens`/`dispatch` events —
no forward-compatibility cost to having it exist a few milestones early.
```

```powershell
. "$HOME/.claude/scripts/decisions-lib.ps1"
Add-DecisionRecordFromFile -Path <path-to-the-file-above>
```

- [ ] **Step 8: Commit**

```bash
git add hud/migrations.py hud/tests/test_migrations.py hud/store.py
git commit -m "feat(hud): forward-only migrations framework (event_uid, recv_ts, rollups_hourly)"
```

---

### Task 2: `recv_ts` + `event_uid` dedup on ingest

**Files:**
- Modify: `hud/store.py` (`insert_event`, `_row_to_event`)
- Modify: `hud/server.py` (`_fill`, `ingest`)
- Modify: `hud/tests/test_store.py`, `hud/tests/test_server.py`

**Interfaces:**
- Consumes: the migrated schema from Task 1 (columns `event_uid`, `recv_ts` exist).
- Produces: `store.insert_event(event: dict) -> int` — **same signature and return type as before** (still returns the row id, still mutates `event['seq']` in place); now *also* mutates `event['recv_ts']` (server-assigned, always) and `event['dup']` (`bool`). `store._row_to_event` now includes `"event_uid"` and `"recv_ts"` keys in every returned event dict. `POST /ingest`'s JSON response gains a `"dup"` key: `{"ok": true, "id": N, "seq": M, "dup": bool}`.

- [ ] **Step 1: Write the failing tests**

```python
# hud/tests/test_store.py — add to the existing file
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
```

```python
# hud/tests/test_server.py — add to the existing file
def test_ingest_response_has_dup_field(client):
    r = client.post("/ingest", json={"session_id": "s1", "kind": "stop"})
    assert r.status_code == 200
    assert r.json()["dup"] is False


def test_ingest_dedups_on_event_uid(client):
    body = {"session_id": "s1", "kind": "stop", "event_uid": "dup-1"}
    r1 = client.post("/ingest", json=body)
    r2 = client.post("/ingest", json=body)
    assert r1.json()["id"] == r2.json()["id"]
    assert r2.json()["dup"] is True
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest hud/tests/test_store.py hud/tests/test_server.py -v -k "recv_ts or dedup or dup"`
Expected: FAIL — `make_event()` doesn't accept `event_uid` as a no-op override yet is fine (it's a plain `dict.update`), but `insert_event` doesn't set `dup`/mutate `recv_ts`, and `/ingest` doesn't accept or echo `event_uid`/`dup`.

- [ ] **Step 3: Update `hud/store.py`**

Add near the other helpers:

```python
from datetime import datetime, timezone

def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
```

Replace `insert_event`:

```python
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
                conn.commit()
                if existing is not None:
                    event["dup"] = True
                    event["seq"] = int(existing["seq"])
                    return int(existing["id"])
                # event_uid collided but the row is gone (pruned) -- fall through as non-dup.
            event["dup"] = False
            conn.commit()
            return int(cur.lastrowid)
        except Exception:
            try:
                conn.rollback()
            except sqlite3.Error:
                pass
            raise
```

Update `_row_to_event` to expose the new columns — add these two lines to the returned dict (after `"machine": row["machine"],`):

```python
        "event_uid": row["event_uid"],
        "recv_ts": row["recv_ts"],
```

Add two read helpers (used by Task 3's `/healthz`):

```python
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
```

- [ ] **Step 4: Update `hud/server.py`**

In `_fill`, thread `event_uid` through from the request body:

```python
def _fill(body: dict[str, Any]) -> dict[str, Any]:
    session_id = body.get("session_id")
    kind = body.get("kind")
    if not session_id or not kind:
        raise HTTPException(status_code=422, detail="session_id and kind required")
    payload = body.get("payload")
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        raise HTTPException(status_code=422, detail="payload must be an object")
    agent = body.get("agent")
    if agent is None or agent == "":
        agent = "main"
    event_uid = body.get("event_uid")
    if event_uid is not None:
        event_uid = str(event_uid)[:64]
    result = {
        "schema": SCHEMA_ID,
        "ts": _coerce_ts(body.get("ts")),
        "session_id": str(session_id),
        "source": "claude-hook",
        "kind": str(kind),
        "agent": agent,
        "machine": body.get("machine") or socket.gethostname(),
        "payload": _clamp_payload(payload),
    }
    if event_uid:
        result["event_uid"] = event_uid
    return result
```

In `ingest`, return the new field:

```python
@app.post("/ingest")
async def ingest(request: Request) -> dict[str, Any]:
    body = await _read_json_object(request)
    try:
        event = _fill(body)
        event_id = await asyncio.to_thread(store.insert_event, event)
        event["id"] = event_id
    except HTTPException:
        raise
    except Exception as exc:
        logger.warning("ingest rejected: %s", exc)
        raise HTTPException(status_code=422, detail="invalid event") from exc
    await _broadcast(event)
    return {"ok": True, "id": event_id, "seq": event["seq"], "dup": event.get("dup", False)}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest hud/tests -q`
Expected: all pass (44 + 3 migrations + 5 new = 52).

- [ ] **Step 6: Commit**

```bash
git add hud/store.py hud/server.py hud/tests/test_store.py hud/tests/test_server.py
git commit -m "feat(hud): recv_ts stamping + event_uid dedup on /ingest"
```

---

### Task 3: Extended `/healthz`

**Files:**
- Modify: `hud/server.py` (`healthz`, imports)
- Modify: `hud/tests/test_server.py`

**Interfaces:**
- Consumes: `store.count_events_since_recv`, `store.max_recv_ts` (Task 2), `migrations.current_version` (Task 1).
- Produces: `GET /healthz` now returns `{ok, events, sessions, uptime_s, db_bytes, subscribers, ingest_rate_1m, spool_drops, last_event_recv_ts, migration_version}`. `sessions` is `None` (no projection until M4) and `spool_drops` is `0` (no forwarder until M2) — both real, honest values for what exists today, not placeholders.

- [ ] **Step 1: Write the failing test**

```python
# hud/tests/test_server.py
def test_healthz_extended_fields(client):
    client.post("/ingest", json={"session_id": "s1", "kind": "stop"})
    r = client.get("/healthz")
    body = r.json()
    for key in ("ok", "events", "sessions", "uptime_s", "db_bytes", "subscribers",
                "ingest_rate_1m", "spool_drops", "last_event_recv_ts", "migration_version"):
        assert key in body, key
    assert body["events"] >= 1
    assert body["ingest_rate_1m"] >= 1
    assert body["sessions"] is None
    assert body["spool_drops"] == 0
    assert body["migration_version"] == 3
    assert body["last_event_recv_ts"]
    assert body["db_bytes"] > 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest hud/tests/test_server.py::test_healthz_extended_fields -v`
Expected: FAIL — `KeyError`/`assert False` on the missing keys.

- [ ] **Step 3: Implement in `hud/server.py`**

Add `from datetime import timedelta` to the existing `datetime` import line, and `from hud import migrations` near the other `hud` imports. Then:

```python
def _db_bytes() -> int:
    total = 0
    base = str(store.db_path())
    for suffix in ("", "-wal", "-shm"):
        p = Path(base + suffix)
        if p.exists():
            total += p.stat().st_size
    return total


@app.get("/healthz")
async def healthz() -> dict[str, Any]:
    one_min_ago = (datetime.now(timezone.utc) - timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
    conn = store.get_conn()
    return {
        "ok": True,
        "events": await asyncio.to_thread(store.count_events),
        "sessions": None,  # M4: sessions projection
        "uptime_s": int(time.time() - STARTED_AT),
        "db_bytes": await asyncio.to_thread(_db_bytes),
        "subscribers": len(_subscribers),
        "ingest_rate_1m": await asyncio.to_thread(store.count_events_since_recv, one_min_ago),
        "spool_drops": 0,  # M2: forwarder spool
        "last_event_recv_ts": await asyncio.to_thread(store.max_recv_ts),
        "migration_version": await asyncio.to_thread(migrations.current_version, conn),
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest hud/tests -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add hud/server.py hud/tests/test_server.py
git commit -m "feat(hud): extended /healthz (db_bytes, ingest_rate_1m, migration_version, ...)"
```

---

### Task 4: `Last-Event-ID` SSE resume

**Files:**
- Modify: `hud/server.py` (`_sse`, `stream`)
- Modify: `hud/tests/test_server.py`

**Interfaces:**
- Consumes: `store.query_events(since=..., limit=...)` (already exists, unchanged).
- Produces: every SSE frame now carries `id: <event id>`. `GET /stream` honors an incoming `Last-Event-ID` request header — when present and a valid positive int, replay is `store.query_events(since=<that id>)` (ascending, up to the store's 2000-row cap) instead of the fixed-window `store.replay_events(n)`. The `?replay=N` query param behavior is unchanged and still used when no `Last-Event-ID` is sent (a cold client).

- [ ] **Step 1: Write the failing tests**

```python
# hud/tests/test_server.py
def test_sse_frames_carry_id(client):
    r = client.post("/ingest", json={"session_id": "s1", "kind": "stop"})
    eid = r.json()["id"]
    with client.stream("GET", "/stream?replay=10") as resp:
        chunk = resp.read().decode("utf-8")
    assert ("id: %d\n" % eid) in chunk


def test_stream_honours_last_event_id_header(client):
    r1 = client.post("/ingest", json={"session_id": "s1", "kind": "stop"})
    first_id = r1.json()["id"]
    r2 = client.post("/ingest", json={"session_id": "s1", "kind": "notification",
                                       "payload": {"message": "x"}})
    second_id = r2.json()["id"]
    with client.stream("GET", "/stream", headers={"Last-Event-ID": str(first_id)}) as r:
        chunk = r.read(4096).decode("utf-8")
    # resume from first_id must NOT replay first_id itself, but MUST include second_id
    assert ("id: %d" % first_id) not in chunk
    assert ("id: %d" % second_id) in chunk
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest hud/tests/test_server.py -v -k "sse_frames_carry_id or last_event_id"`
Expected: FAIL — no `id:` line is emitted today, and `Last-Event-ID` is ignored.

- [ ] **Step 3: Implement in `hud/server.py`**

Replace `_sse`:

```python
def _sse(event: dict[str, Any]) -> str:
    eid = event.get("id")
    id_line = "id: %s\n" % eid if eid else ""
    return "%sevent: hud\ndata: %s\n\n" % (id_line, json.dumps(event, default=str, ensure_ascii=False))
```

Replace the `stream` route:

```python
@app.get("/stream")
async def stream(request: Request, replay: int = Query(default=200)) -> StreamingResponse:
    n = replay
    try:
        n = int(n)
    except (TypeError, ValueError):
        n = 200
    n = max(0, min(n, 2000))

    resume_from: Optional[int] = None
    last_event_id_hdr = request.headers.get("last-event-id")
    if last_event_id_hdr:
        try:
            candidate = int(last_event_id_hdr)
            if candidate > 0:
                resume_from = candidate
        except (TypeError, ValueError):
            resume_from = None

    async def gen():
        q: asyncio.Queue = asyncio.Queue(maxsize=_QUEUE_MAX)
        _subscribers.add(q)
        replayed_ids: set[int] = set()
        try:
            if resume_from is not None:
                replayed = await asyncio.to_thread(store.query_events, since=resume_from)
            else:
                replayed = await asyncio.to_thread(store.replay_events, n)
            if not replayed:
                yield ": stream-open\n\n"
            for ev in replayed:
                eid = int(ev.get("id") or 0)
                if eid:
                    replayed_ids.add(eid)
                yield _sse(ev)
            while True:
                try:
                    item = await asyncio.wait_for(q.get(), timeout=15.0)
                except asyncio.TimeoutError:
                    yield ": ping\n\n"
                    continue
                if item is None:
                    break
                eid = int(item.get("id") or 0)
                if eid and eid in replayed_ids:
                    continue
                yield _sse(item)
        except asyncio.CancelledError:
            raise
        except Exception:
            return
        finally:
            _subscribers.discard(q)

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )
```

(Only the added `request: Request` parameter and the `resume_from` branch are new; the queue/ping/broadcast loop is unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest hud/tests -q`
Expected: all pass.

- [ ] **Step 5: Live restart-resume integration test**

This is the exit-criterion test ("a live stream loses zero events across a `kill -9` + restart") and needs two real uvicorn processes sharing one DB file, so it uses the `live_server` fixture pattern directly rather than `TestClient`.

```python
# hud/tests/test_server.py
def test_restart_resume_loses_no_events(isolated_state):
    import threading
    import time
    import urllib.request

    import uvicorn

    from hud.server import app

    def start(port):
        config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning", lifespan="off")
        srv = uvicorn.Server(config)
        srv.install_signal_handlers = lambda: None
        t = threading.Thread(target=srv.run, daemon=True)
        t.start()
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/healthz" % port, timeout=0.2)
                return srv, t
            except Exception:
                time.sleep(0.05)
        raise RuntimeError("server did not start")

    import socket as _socket
    s = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()

    srv1, t1 = start(port)
    r = urllib.request.urlopen(
        "http://127.0.0.1:%d/ingest" % port,
        data=b'{"session_id":"s1","kind":"stop"}',
        headers={"Content-Type": "application/json"},  # type: ignore[call-arg]
    )
    import json as _json
    first_id = _json.loads(r.read())["id"]

    # simulate kill -9: stop the server WITHOUT graceful SSE teardown
    srv1.should_exit = True
    t1.join(timeout=3)

    # while "down", an emitter would have nothing to POST to; simulate the
    # gap by inserting directly into the shared store as if a forwarder had
    # spooled it (M1 has no forwarder yet -- this proves the DB/WAL survives
    # the restart, which is the M1-scoped half of the exit criterion).
    from hud import store
    ev2 = {"schema": "hud.event/v1", "ts": "2026-09-12T00:00:00Z", "session_id": "s1",
           "source": "claude-hook", "kind": "notification", "agent": "main",
           "machine": "m", "payload": {"message": "x"}}
    second_id = store.insert_event(ev2)  # insert_event returns the id; it does not mutate event["id"]

    srv2, t2 = start(port)
    req = urllib.request.Request(
        "http://127.0.0.1:%d/stream" % port,
        headers={"Last-Event-ID": str(first_id)},
    )
    resp = urllib.request.urlopen(req, timeout=2)
    chunk = resp.read(4096).decode("utf-8")
    assert ("id: %d" % second_id) in chunk
    assert ("id: %d" % first_id) not in chunk

    srv2.should_exit = True
    t2.join(timeout=3)
```

Run: `.venv/bin/python -m pytest hud/tests/test_server.py::test_restart_resume_loses_no_events -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add hud/server.py hud/tests/test_server.py
git commit -m "feat(hud): Last-Event-ID SSE resume — a restart no longer drops events"
```

---

### Task 5: Retention pruner + nightly backup

**Files:**
- Create: `hud/retention.py`
- Create: `hud/tests/test_retention.py`
- Modify: `hud/server.py` (startup/shutdown hooks)
- Modify: `hud/tests/conftest.py` (`isolated_state` disables the background loop)

**Interfaces:**
- Consumes: `rollups_hourly` table (Task 1).
- Produces: `retention.prune_once(conn, *, retention_days: int, now: float | None = None) -> dict` (returns `{"deleted": int, "buckets_touched": int}`), `retention.backup_now(conn, backups_dir: Path, *, keep: int = 7) -> Path`, `retention.should_backup(last_backup_ts: float | None, now: float) -> bool`, `retention.backup_dir() -> Path`, `retention.PRUNE_INTERVAL_S = 3600`, `retention.RETENTION_DAYS_DEFAULT = 30`. `server.py` schedules an asyncio background task on FastAPI startup calling both, unless `HUD_DISABLE_RETENTION=1`.

**Decision point (capture it):** SQLite treats `NULL` as never-equal-to-itself in a unique index/composite primary key, so `rollups_hourly`'s `(bucket_ts, machine, source, kind, project, model)` primary key would silently stop upserting the moment `project`/`model` are `NULL` (which they always are in M1 — no adapter populates them yet). The pruner normalizes `project`/`model` to `""` rather than `None` before writing, so the primary key actually dedups.

- [ ] **Step 1: Write the failing tests**

```python
# hud/tests/test_retention.py
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest hud/tests/test_retention.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'hud.retention'`

- [ ] **Step 3: Write `hud/retention.py`**

```python
"""Hourly retention pruning (raw events -> rollups_hourly) and nightly SQLite backup.

project/model are normalized to "" (never None) when writing rollups_hourly:
SQLite's composite PRIMARY KEY treats every NULL as distinct from every other
NULL, so a None-valued column would defeat the upsert and create a fresh row
on every prune pass instead of accumulating into one.
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
    backups_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
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
```

- [ ] **Step 4: Run the retention tests to verify they pass**

Run: `.venv/bin/python -m pytest hud/tests/test_retention.py -v`
Expected: PASS (6 tests)

- [ ] **Step 5: Wire the background loop into `hud/server.py`, guarded for tests**

In `hud/tests/conftest.py`, add one line to `isolated_state` (right after the existing `monkeypatch.delenv("HUD_TOKEN", ...)` line):

```python
    monkeypatch.setenv("HUD_DISABLE_RETENTION", "1")
```

In `hud/server.py`, add near the top-level state (`_subscribers = ...` etc.):

```python
from hud import retention

_retention_task: Optional[asyncio.Task] = None
_last_backup_ts: Optional[float] = None


async def _retention_loop() -> None:
    global _last_backup_ts
    while True:
        try:
            conn = store.get_conn()
            days = int(os.environ.get("HUD_RETENTION_DAYS", str(retention.RETENTION_DAYS_DEFAULT)))
            await asyncio.to_thread(retention.prune_once, conn, retention_days=days)
            now = time.time()
            if retention.should_backup(_last_backup_ts, now):
                await asyncio.to_thread(retention.backup_now, conn, retention.backup_dir())
                _last_backup_ts = now
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("retention loop failed")
        await asyncio.sleep(retention.PRUNE_INTERVAL_S)


@app.on_event("startup")
async def _on_startup() -> None:
    global _retention_task
    if os.environ.get("HUD_DISABLE_RETENTION") != "1":
        _retention_task = asyncio.create_task(_retention_loop())


@app.on_event("shutdown")
async def _on_shutdown() -> None:
    if _retention_task is not None:
        _retention_task.cancel()
```

- [ ] **Step 6: Run the full suite**

Run: `.venv/bin/python -m pytest hud/tests -q`
Expected: all pass, no new hangs or startup slowdowns (the `client`/`live_server` fixtures now skip the retention loop entirely via `HUD_DISABLE_RETENTION=1`).

- [ ] **Step 7: One live test proving the loop actually schedules (without waiting an hour)**

```python
# hud/tests/test_server.py
def test_retention_task_starts_unless_disabled(monkeypatch, isolated_state):
    monkeypatch.delenv("HUD_DISABLE_RETENTION", raising=False)
    from fastapi.testclient import TestClient
    from hud import server
    with TestClient(server.app):
        assert server._retention_task is not None
        assert not server._retention_task.done()
```

Run: `.venv/bin/python -m pytest hud/tests/test_server.py::test_retention_task_starts_unless_disabled -v`
Expected: PASS

- [ ] **Step 8: Capture the NULL-primary-key decision**

```markdown
---
title: HUD retention rollups — normalize project/model to empty string, never NULL, in the PK
confidence: high
revisit-if: rollups_hourly's primary key columns change shape
project: baton
phase: hud-m1-service
---

**Chosen:** `retention.prune_once` writes `""` (not `None`) for `project`/`model` in
`rollups_hourly` whenever an event doesn't carry them (true for every M1 event kind).

**Alternatives:**
- Leave them `NULL` as the spec's schema literally shows — rejected: SQLite's
  composite PRIMARY KEY / UNIQUE index treats every NULL as distinct from every
  other NULL, so the `ON CONFLICT` upsert would never fire and every prune pass
  would insert a fresh row instead of accumulating into the existing bucket,
  silently breaking the "roll up, don't just delete" guarantee (D9).
- Use a sentinel string like `"(none)"` — rejected as noisier than `""` for the
  same effect, with no benefit.

**Rationale:** Caught by writing a test that calls `prune_once` twice against data
in the same hour bucket (`test_prune_once_is_safe_to_call_repeatedly`) — with `NULL`
it produced two separate `n=1` rows instead of one `n=2` row. `""` is a normal,
indexable, equal-to-itself value, so the upsert works as intended.
```

```powershell
. "$HOME/.claude/scripts/decisions-lib.ps1"
Add-DecisionRecordFromFile -Path <path-to-the-file-above>
```

- [ ] **Step 9: Commit**

```bash
git add hud/retention.py hud/tests/test_retention.py hud/server.py hud/tests/conftest.py hud/tests/test_server.py
git commit -m "feat(hud): hourly retention pruner + nightly backup — DB stops growing without bound"
```

---

### Task 6: Default theme flip to `sapphire`

**Files:**
- Modify: `hud/config.py`
- Modify: `hud/config.json` (tracked default file)
- Modify: `hud/server.py` (`_chooser_html`, `view`, `post_config`)
- Modify: `hud/frontends/board.html`, `cockpit.html`, `deck.html`, `minimal.html`, `cards.html`
- Modify: `hud/tests/test_server.py`

**Interfaces:**
- Produces: `hud.config.THEME_NAMES = ("dark", "sapphire", "lapis-velvet", "sandstone")`, `hud.config.read_config()` now also returns `"default_theme"`, `hud.config.write_config(default_frontend=_UNSET, default_theme=_UNSET)` merges onto the existing stored config instead of overwriting it (backward compatible — existing positional call `write_config(val)` is unchanged). `_chooser_html(names, token="", default_theme="sapphire")`. `POST /config` accepts `default_theme` in its body in addition to (or instead of) `default_frontend`. `GET /v/{name}` now returns `HTMLResponse` (was `FileResponse`) for the five live front-ends only — `hud/versions/vN/` keeps using `FileResponse` unchanged.

- [ ] **Step 1: Write the failing tests**

```python
# hud/tests/test_server.py
def test_default_theme_is_sapphire_out_of_the_box(client):
    r = client.get("/v/board")
    assert r.status_code == 200
    text = r.text
    assert 'localStorage.getItem("hud-theme") || "sapphire"' in text
    assert 't = "sapphire";' in text  # the ALLOWED-fallback line


def test_frozen_version_snapshots_still_default_to_dark(client):
    from hud.server import _version_index

    rows = _version_index()
    assert rows  # sanity: frozen versions exist
    vid = rows[0]["id"]
    layout = rows[0]["layouts"][0]
    r = client.get("/%s/v/%s" % (vid, layout))
    assert r.status_code == 200
    # frozen versions are served via FileResponse (untouched by Task 6's templating)
    # and must keep whatever literal default they shipped with -- "dark" for v1-v4.
    assert 'localStorage.getItem("hud-theme") || "dark"' in r.text


def test_post_config_sets_default_theme(client):
    r = client.post("/config", json={"default_theme": "lapis-velvet"})
    assert r.status_code == 200
    assert r.json()["default_theme"] == "lapis-velvet"
    r2 = client.get("/v/board")
    assert 'localStorage.getItem("hud-theme") || "lapis-velvet"' in r2.text
    # default_frontend, untouched by this call, is preserved
    assert r.json()["default_frontend"] is None


def test_post_config_rejects_unknown_theme(client):
    r = client.post("/config", json={"default_theme": "neon"})
    assert r.status_code == 422


def test_chooser_uses_configured_default_theme(client):
    r = client.get("/")
    assert 'localStorage.getItem("hud-theme") || "sapphire"' in r.text
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest hud/tests/test_server.py -v -k theme`
Expected: FAIL — everything still says `"dark"`.

- [ ] **Step 3: Update `hud/config.py`**

```python
"""Read/write hud/config.json — {"default_frontend": name|null, "default_theme": name}."""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any, Optional

THEME_NAMES = ("dark", "sapphire", "lapis-velvet", "sandstone")
_DEFAULT = {"default_frontend": None, "default_theme": "sapphire"}
_UNSET = object()


def config_path() -> Path:
    env = os.environ.get("HUD_CONFIG")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent / "config.json"


def read_config() -> dict[str, Any]:
    path = config_path()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return dict(_DEFAULT)
    if not isinstance(raw, dict):
        return dict(_DEFAULT)
    val = raw.get("default_frontend", None)
    if val is not None:
        val = str(val)
    theme = raw.get("default_theme", _DEFAULT["default_theme"])
    if theme not in THEME_NAMES:
        theme = _DEFAULT["default_theme"]
    return {"default_frontend": val, "default_theme": theme}


def write_config(default_frontend: Any = _UNSET, default_theme: Any = _UNSET) -> dict[str, Any]:
    current = read_config()
    if default_frontend is not _UNSET:
        if default_frontend is not None:
            default_frontend = str(default_frontend)
            if default_frontend == "" or default_frontend.lower() == "null":
                default_frontend = None
        current["default_frontend"] = default_frontend
    if default_theme is not _UNSET:
        if default_theme not in THEME_NAMES:
            raise ValueError("unknown theme: %r" % (default_theme,))
        current["default_theme"] = default_theme
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="hud-config-", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(current, fh)
            fh.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return current
```

- [ ] **Step 4: Update the tracked `hud/config.json`**

```json
{"default_frontend": null, "default_theme": "sapphire"}
```

- [ ] **Step 5: Update `hud/server.py`**

`_chooser_html` gains a `default_theme` parameter and uses it in place of the two hardcoded `"dark"` fallbacks (lines matching `else t = localStorage.getItem("hud-theme") || "dark";` and the later `if (ALLOWED.indexOf(t) < 0) t = "dark";`):

```python
def _chooser_html(names: list[str], token: str = "", default_theme: str = "sapphire") -> str:
    ...
    return """<!DOCTYPE html>
...
    (function () {
      var q = new URLSearchParams(location.search);
      var t = q.get("theme");
      if (t && ALLOWED.indexOf(t) >= 0) localStorage.setItem("hud-theme", t);
      else t = localStorage.getItem("hud-theme") || "%(theme)s";
      if (ALLOWED.indexOf(t) < 0) t = "%(theme)s";
...
      var t = q || localStorage.getItem("hud-theme") || "%(theme)s";
      if (ALLOWED.indexOf(t) < 0) t = "%(theme)s";
...
""" % {"theme": default_theme, ...cards_join_placeholder_stays_as_is...}
```

Concretely: change the function's final `% "\n".join(cards)` to a dict-based `%` substitution carrying both `theme` and the existing `cards` placeholder (rename the single `%s` template placeholders for `theme` to `%(theme)s` at both of the two "dark" call sites shown above, and the existing `%s` for the cards block to `%(cards)s`), then call it as:

```python
    return TEMPLATE % {"theme": default_theme, "cards": "\n".join(cards)}
```

Update both call sites of `_chooser_html`:

```python
# in root():
    cfg = hud_config.read_config()
    ...
    return HTMLResponse(_chooser_html(names, token=token, default_theme=cfg.get("default_theme", "sapphire")))

# in version_chooser(): frozen versions keep the hardcoded "dark" default -- do NOT pass
# hud_config's default_theme here, since hud/versions/vN/ is a frozen historical snapshot.
```

Change `GET /v/{name}` from `FileResponse` to a templated `HTMLResponse` (this is the ONLY route that changes for live front-ends; `version_view` for `hud/versions/vN/` is untouched):

```python
_THEME_FALLBACK_MARKERS = (
    'localStorage.getItem("hud-theme") || "dark"',
    't = "dark";',
    ': "dark";',
)


def _render_frontend(path: Path, default_theme: str) -> str:
    text = path.read_text(encoding="utf-8")
    text = text.replace('localStorage.getItem("hud-theme") || "dark"',
                         'localStorage.getItem("hud-theme") || "%s"' % default_theme)
    text = text.replace('t = "dark";', 't = "%s";' % default_theme)
    text = text.replace(': "dark";', ': "%s";' % default_theme)
    return text


@app.get("/v/{name}")
async def view(name: str) -> Any:
    path = _frontend_path(name)
    if path is None:
        raise HTTPException(status_code=404, detail="unknown front-end")
    cfg = hud_config.read_config()
    html_text = _render_frontend(path, cfg.get("default_theme", "sapphire"))
    return HTMLResponse(html_text)
```

Update `post_config`:

```python
@app.post("/config")
async def post_config(request: Request) -> dict[str, Any]:
    body = await _read_json_object(request)
    if "default_frontend" not in body and "default_theme" not in body:
        raise HTTPException(status_code=422, detail="default_frontend or default_theme required")
    kwargs: dict[str, Any] = {}
    if "default_frontend" in body:
        val = body.get("default_frontend")
        if val is not None:
            val = str(val)
            if val.endswith(".html"):
                val = val[:-5]
            if val == "" or val.lower() == "null":
                val = None
            elif _frontend_path(val) is None:
                raise HTTPException(status_code=422, detail="unknown front-end")
        kwargs["default_frontend"] = val
    if "default_theme" in body:
        theme = body.get("default_theme")
        if theme not in hud_config.THEME_NAMES:
            raise HTTPException(status_code=422, detail="unknown theme")
        kwargs["default_theme"] = theme
    return hud_config.write_config(**kwargs)
```

- [ ] **Step 6: Flip the static literal default in the five live front-ends**

For each of `hud/frontends/{board,cockpit,deck,minimal,cards}.html`, the *initial page-load* fallback (before any server round-trip has a chance to matter for the very first byte written by `document.write`) should already say `sapphire` so a `curl`/no-JS view and the templated substitution agree. Since `_render_frontend` (Step 5) does a blanket text substitution of the literal `"dark"` fallbacks at serve time, editing the files themselves is **not required** for `/v/{name}` — the server-side substitution is sufficient and is the actual source of truth (so `POST /config` changes take effect without redeploying the HTML). Confirm this by running Step 7's tests; do not hand-edit the five HTML files in this task — the frozen invariant plus the templating in Step 5 already cover it. (If a future task adds `hud.js`, per D11, the substitution moves there — not before M6.)

- [ ] **Step 7: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest hud/tests -q`
Expected: all pass.

- [ ] **Step 8: Manual verification — empty localStorage lands on sapphire**

Run: `.venv/bin/python -m hud &` then open `http://127.0.0.1:8765/v/board` in a private/incognito browser window (guarantees empty `localStorage`). Confirm the page renders in the sapphire palette, not dark. Stop the server.

- [ ] **Step 9: Commit**

```bash
git add hud/config.py hud/config.json hud/server.py hud/tests/test_server.py
git commit -m "feat(hud): default theme flips dark -> sapphire, server-side and config-driven"
```

---

### Task 7: `baton hud` CLI subcommands + macOS launchd service

**Files:**
- Create: `hud/servicectl.py`
- Create: `hud/service/dev.baton.hud.plist`
- Modify: `hud/__main__.py`
- Create: `hud/tests/test_servicectl.py`, `hud/tests/test_main.py`
- Modify: `hud/README.md`

**Interfaces:**
- Produces: `hud.servicectl.render_launchd_plist(python_exe: str, repo_root: Path, host: str, port: int) -> str`, `hud.servicectl.install_macos_service(repo_root: Path, *, host="0.0.0.0", port=8765) -> Path` (writes + `launchctl load`s the plist, returns its installed path), `hud.servicectl.status_summary(host: str, port: int, token: str = "") -> dict` (GETs `/healthz`, returns `{"reachable": bool, ...healthz fields or "error"}`), `hud.servicectl.rebuild_db() -> dict` (WAL checkpoint + integrity check + row count — see decision below). `hud/__main__.py main(argv)` dispatches `serve` (today's behavior, also the implicit default when no subcommand is given), `status`, `install-service`, `rebuild`.

**Decision point (capture it):** `baton hud rebuild` is named in the spec's M1 milestone bullet, but the *thing* §6.1 describes it rebuilding (`derive.rebuild_sessions()`) doesn't exist until M4 — there's no sessions projection yet. M1's `rebuild` does the part of "rebuild" that's real today: a WAL checkpoint, an integrity check, and a row-count report. M4 extends the same subcommand to also call `derive.rebuild_sessions()`.

- [ ] **Step 1: Write the failing tests**

```python
# hud/tests/test_servicectl.py
import platform

import pytest

from hud import servicectl


def test_render_launchd_plist_contains_env_and_paths(tmp_path):
    xml = servicectl.render_launchd_plist("/usr/bin/python3", tmp_path, host="0.0.0.0", port=8765)
    assert "dev.baton.hud" in xml
    assert "/usr/bin/python3" in xml
    assert str(tmp_path) in xml
    assert "<key>RunAtLoad</key>" in xml
    assert "<true/>" in xml
    assert "HUD_HOST" in xml and "0.0.0.0" in xml
    assert "HUD_PORT" in xml and "8765" in xml


@pytest.mark.skipif(platform.system() != "Darwin", reason="launchd is macOS-only")
def test_install_macos_service_writes_and_loads(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(servicectl.subprocess, "run",
                         lambda *a, **k: calls.append(a) or servicectl._FakeCompleted())
    dest = tmp_path / "LaunchAgents"
    monkeypatch.setattr(servicectl, "_launch_agents_dir", lambda: dest)
    path = servicectl.install_macos_service(tmp_path, host="0.0.0.0", port=8765)
    assert path == dest / "dev.baton.hud.plist"
    assert path.is_file()
    assert any("launchctl" in str(c) for c in calls)


def test_install_service_on_non_macos_is_a_clear_refusal(monkeypatch, tmp_path):
    monkeypatch.setattr(servicectl.platform, "system", lambda: "Linux")
    with pytest.raises(servicectl.UnsupportedPlatform, match="M2"):
        servicectl.install_service(tmp_path)


def test_rebuild_db_reports_counts(isolated_state):
    from hud import store
    store.insert_event({"schema": "hud.event/v1", "ts": "2026-09-12T00:00:00Z", "session_id": "s",
                         "source": "claude-hook", "kind": "stop", "agent": "main", "machine": "m",
                         "payload": {}})
    result = servicectl.rebuild_db()
    assert result["integrity_ok"] is True
    assert result["events"] == 1


def test_status_summary_reachable(live_server):
    from hud import servicectl

    result = servicectl.status_summary("127.0.0.1", live_server["port"])
    assert result["reachable"] is True
    assert "events" in result
    assert "migration_version" in result


def test_status_summary_unreachable_reports_error():
    from hud import servicectl

    result = servicectl.status_summary("127.0.0.1", 1)  # port 1: nothing listens there
    assert result["reachable"] is False
    assert "error" in result
```

```python
# hud/tests/test_main.py
from hud.__main__ import build_parser


def test_no_subcommand_implies_serve():
    parser = build_parser()
    args = parser.parse_args(["--host", "0.0.0.0", "--port", "9999"])
    assert args.command == "serve"
    assert args.host == "0.0.0.0"
    assert args.port == 9999


def test_explicit_serve_subcommand():
    parser = build_parser()
    args = parser.parse_args(["serve", "--port", "9000"])
    assert args.command == "serve"
    assert args.port == 9000


def test_status_subcommand_parses():
    parser = build_parser()
    args = parser.parse_args(["status"])
    assert args.command == "status"


def test_rebuild_subcommand_parses():
    parser = build_parser()
    args = parser.parse_args(["rebuild"])
    assert args.command == "rebuild"


def test_install_service_subcommand_parses():
    parser = build_parser()
    args = parser.parse_args(["install-service"])
    assert args.command == "install-service"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest hud/tests/test_servicectl.py hud/tests/test_main.py -v`
Expected: FAIL — `hud.servicectl` and `build_parser` don't exist yet.

- [ ] **Step 3: Write `hud/servicectl.py`**

```python
"""Service install/status/rebuild logic behind `baton hud {install-service,status,rebuild}`.
Kept out of __main__.py so it's unit-testable without subprocess/argv plumbing."""
from __future__ import annotations

import platform
import subprocess
import sqlite3
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from hud import store

PLIST_NAME = "dev.baton.hud.plist"

_PLIST_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.baton.hud</string>
  <key>ProgramArguments</key>
  <array>
    <string>%(python)s</string>
    <string>-m</string>
    <string>hud</string>
    <string>serve</string>
  </array>
  <key>WorkingDirectory</key><string>%(repo_root)s</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HUD_HOST</key><string>%(host)s</string>
    <key>HUD_PORT</key><string>%(port)s</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>%(repo_root)s/hud/logs/hud.out.log</string>
  <key>StandardErrorPath</key><string>%(repo_root)s/hud/logs/hud.err.log</string>
</dict>
</plist>
"""


class UnsupportedPlatform(RuntimeError):
    pass


class _FakeCompleted:
    returncode = 0


def render_launchd_plist(python_exe: str, repo_root: Path, *, host: str = "0.0.0.0", port: int = 8765) -> str:
    return _PLIST_TEMPLATE % {
        "python": python_exe,
        "repo_root": str(repo_root),
        "host": host,
        "port": port,
    }


def _launch_agents_dir() -> Path:
    return Path.home() / "Library" / "LaunchAgents"


def install_macos_service(repo_root: Path, *, host: str = "0.0.0.0", port: int = 8765,
                           python_exe: str = "") -> Path:
    import sys
    python_exe = python_exe or sys.executable
    (repo_root / "hud" / "logs").mkdir(parents=True, exist_ok=True)
    xml = render_launchd_plist(python_exe, repo_root, host=host, port=port)
    dest_dir = _launch_agents_dir()
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / PLIST_NAME
    dest.write_text(xml, encoding="utf-8")
    subprocess.run(["launchctl", "unload", str(dest)], capture_output=True)
    subprocess.run(["launchctl", "load", str(dest)], capture_output=True, check=False)
    return dest


def install_service(repo_root: Path, **kwargs: Any) -> Path:
    system = platform.system()
    if system == "Darwin":
        return install_macos_service(repo_root, **kwargs)
    raise UnsupportedPlatform(
        "install-service on %s lands in M2 (systemd user unit / Windows Task Scheduler). "
        "Run `python -m hud serve` directly for now." % system
    )


def status_summary(host: str, port: int, token: str = "") -> dict[str, Any]:
    url = "http://%s:%d/healthz" % (host if host not in ("0.0.0.0",) else "127.0.0.1", port)
    if token:
        url += "?t=" + token
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            import json
            body = json.loads(resp.read().decode("utf-8"))
        body["reachable"] = True
        return body
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"reachable": False, "error": str(exc)}


def rebuild_db() -> dict[str, Any]:
    """M1-provisional: WAL checkpoint + integrity check + row count.
    M4 extends this to also call derive.rebuild_sessions()."""
    conn = store.get_conn()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    integrity = conn.execute("PRAGMA integrity_check").fetchone()
    integrity_ok = bool(integrity and integrity[0] == "ok")
    events = store.count_events()
    return {"integrity_ok": integrity_ok, "events": events}
```

- [ ] **Step 4: Run the servicectl/main tests, fixing the launchd fake as needed**

Run: `.venv/bin/python -m pytest hud/tests/test_servicectl.py -v`
Expected: PASS (the `Darwin`-only test skips elsewhere; the non-macOS refusal and plist-rendering/rebuild tests run everywhere).

- [ ] **Step 5: Write `hud/__main__.py`**

```python
"""python -m hud [serve|status|install-service|rebuild] -- see `python -m hud --help`."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import uvicorn

from hud.server import warn_if_unauthed_lan

_KNOWN_COMMANDS = {"serve", "status", "install-service", "rebuild"}
_REPO_ROOT = Path(__file__).resolve().parent.parent


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="hud", description="Baton HUD")
    sub = parser.add_subparsers(dest="command")

    serve_p = sub.add_parser("serve", help="run the HUD server (default)")
    serve_p.add_argument("--host", default=os.environ.get("HUD_HOST", "127.0.0.1"))
    serve_p.add_argument("--port", type=int, default=int(os.environ.get("HUD_PORT", "8765")))

    status_p = sub.add_parser("status", help="query a running HUD's /healthz")
    status_p.add_argument("--host", default=os.environ.get("HUD_HOST", "127.0.0.1"))
    status_p.add_argument("--port", type=int, default=int(os.environ.get("HUD_PORT", "8765")))
    status_p.add_argument("--token", default=os.environ.get("HUD_TOKEN", ""))

    sub.add_parser("install-service", help="install the platform service unit (macOS: launchd)")
    sub.add_parser("rebuild", help="WAL checkpoint + integrity check (+ sessions rebuild from M4)")

    # backward compat: `python -m hud --host H --port P` (no subcommand) == `serve`
    parser.add_argument("--host", default=argparse.SUPPRESS)
    parser.add_argument("--port", type=int, default=argparse.SUPPRESS)
    return parser


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] not in _KNOWN_COMMANDS:
        argv = ["serve"] + argv
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "serve":
        os.environ["HUD_HOST"] = args.host
        warn_if_unauthed_lan(args.host)
        uvicorn.run("hud.server:app", host=args.host, port=args.port)
        return 0

    if args.command == "status":
        from hud import servicectl
        result = servicectl.status_summary(args.host, args.port, token=args.token)
        print(json.dumps(result, indent=2))
        return 0 if result.get("reachable") else 1

    if args.command == "install-service":
        from hud import servicectl
        try:
            path = servicectl.install_service(_REPO_ROOT)
        except servicectl.UnsupportedPlatform as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print("installed: %s" % path)
        return 0

    if args.command == "rebuild":
        from hud import servicectl
        result = servicectl.rebuild_db()
        print(json.dumps(result, indent=2))
        return 0 if result.get("integrity_ok") else 1

    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: Run all `hud/__main__.py`-related tests**

Run: `.venv/bin/python -m pytest hud/tests/test_main.py hud/tests/test_hook_emit.py -v`
Expected: PASS. (`test_hook_emit.py` is unrelated to `__main__.py` but is the cheapest cross-check that nothing about the module import order broke `hook_emit.py`'s own `sys.path` bootstrap.)

- [ ] **Step 7: Write the actual launchd plist file used by `install-service`**

`hud/service/dev.baton.hud.plist` — a *rendered example* checked into the repo for reference/documentation (the real one is generated by `servicectl.render_launchd_plist` at install time with the actual `sys.executable` and repo path baked in):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.baton.hud</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>-m</string>
    <string>hud</string>
    <string>serve</string>
  </array>
  <key>WorkingDirectory</key><string>/Users/kev/Dev/Baton</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HUD_HOST</key><string>0.0.0.0</string>
    <key>HUD_PORT</key><string>8765</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>/Users/kev/Dev/Baton/hud/logs/hud.out.log</string>
  <key>StandardErrorPath</key><string>/Users/kev/Dev/Baton/hud/logs/hud.err.log</string>
</dict>
</plist>
```

- [ ] **Step 8: Update `hud/README.md`**

Add a section after "## Port collision":

```markdown
## Running as a service (macOS)

```
baton hud install-service          # writes ~/Library/LaunchAgents/dev.baton.hud.plist, loads it
baton hud status                   # human-readable /healthz summary
baton hud rebuild                  # WAL checkpoint + integrity check + row count
launchctl unload ~/Library/LaunchAgents/dev.baton.hud.plist   # stop
```

`install-service` on Linux/Windows currently refuses with a clear message — systemd and
Task Scheduler land in M2 (see `docs/superpowers/specs/2026-09-10-hud-dashboard-buildout-design.md` §8.5, D15).
```

- [ ] **Step 9: Capture the `rebuild` scoping decision**

```markdown
---
title: HUD M1 -- `baton hud rebuild` does a WAL checkpoint + integrity check, not a sessions rebuild
confidence: med
revisit-if: M4 ships derive.py and the sessions projection
project: baton
phase: hud-m1-service
---

**Chosen:** `rebuild` in M1 performs `PRAGMA wal_checkpoint(TRUNCATE)`, an integrity
check, and reports the row count. M4 will extend the same subcommand to also call
`derive.rebuild_sessions()` once that projection exists.

**Alternatives:**
- Ship `rebuild` as a no-op / not-yet-implemented stub until M4 — rejected: the spec's
  M1 milestone bullet explicitly lists `rebuild` as one of the four M1 subcommands, and
  a stub would violate the "no placeholders" rule for real deliverables.
- Skip `rebuild` in M1 entirely, add it only at M4 — rejected for the same reason: the
  spec names it as an M1 CLI surface commitment, not an M4 one.

**Rationale:** The spec's §6.1 describes what `rebuild` means once the sessions
projection exists (M4), but the M1 milestone bullet commits to the CLI surface now.
Filling that surface with real, useful M1-scoped behavior (checkpoint + integrity +
count) rather than a stub keeps the CLI contract stable across milestones — M4 adds to
`rebuild`'s behavior, it never has to introduce the subcommand.
```

```powershell
. "$HOME/.claude/scripts/decisions-lib.ps1"
Add-DecisionRecordFromFile -Path <path-to-the-file-above>
```

- [ ] **Step 10: Commit**

```bash
git add hud/servicectl.py hud/service/dev.baton.hud.plist hud/__main__.py hud/tests/test_servicectl.py hud/tests/test_main.py hud/README.md
git commit -m "feat(hud): baton hud {serve,status,install-service,rebuild} + macOS launchd unit"
```

---

### Task 8: Wire `baton hud` into the top-level CLI dispatcher

**Files:**
- Create: `scripts/hud.ps1`
- Modify: `scripts/verbs.yaml`

**Interfaces:**
- Produces: `baton hud <args...>` → `scripts/hud.ps1 <args...>` → `python3 -m hud <args...>`, exit code passed straight through. No Python interface — this is the pwsh-side dispatch boundary only.

- [ ] **Step 1: Add the `hud` verb to `scripts/verbs.yaml`**

Add, alphabetically is not the existing convention (the file is topic-ordered, not alphabetical) — append near the end of the `verbs:` list, following the existing entry format:

```yaml
  - name: hud
    summary: Agent-activity HUD -- serve, status, install-service, rebuild.
    class: engine
    runner: hud.ps1
    json: false
```

- [ ] **Step 2: Write `scripts/hud.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  baton hud -- thin passthrough to `python -m hud`. All logic lives in Python
  (hud/__main__.py, hud/servicectl.py); this file only picks an interpreter
  and forwards argv, exit code included.
#>
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) {
    Write-Error "baton hud: no python3/python on PATH"
    exit 1
}

Push-Location $repoRoot
try {
    & $python.Path -m hud @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
```

- [ ] **Step 3: Manual verification (no pytest coverage for the pwsh boundary — matches the other verb runners, none of which have unit tests either)**

Run, from the repo root of the M1 worktree:

```bash
pwsh -NoProfile -File scripts/hud.ps1 rebuild
```

Expected: prints the `{"integrity_ok": ..., "events": ...}` JSON from `servicectl.rebuild_db()` and exits 0 (or 1 if `hud.db` doesn't exist yet in this worktree — either is an acceptable pass for this manual check, since the point is confirming the passthrough reaches Python, not the DB's state).

Then, from the repo root (not `scripts/`), confirm the full verb dispatch:

```bash
pwsh -NoProfile -File baton.ps1 hud status
```

Expected: prints a JSON status blob (likely `"reachable": false` if nothing is running on 8765) and exits accordingly — confirms `baton.ps1` → `verbs.yaml` → `hud.ps1` → `python -m hud status` all actually connect end to end.

- [ ] **Step 4: Commit**

```bash
git add scripts/hud.ps1 scripts/verbs.yaml
git commit -m "feat(hud): wire \`baton hud\` into the verbs.yaml CLI dispatcher"
```

---

### Task 9: M1 exit-criteria verification, docs, and PR

**Files:**
- Modify: `hud/README.md` (final pass)
- No new source files — this task verifies and ships.

- [ ] **Step 1: Run the complete test suite one more time**

Run: `.venv/bin/python -m pytest hud/tests -q`
Expected: all pass (44 original + all new tests from Tasks 1–7 — roughly 70).

- [ ] **Step 2: Verify each M1 exit criterion from the spec (§13) by hand**

```bash
# "survives a reboot unattended" -- launchd load/unload cycle on droid itself
# (skip this specific check if not running on droid; note it in the PR description instead)
baton hud install-service
launchctl list | grep dev.baton.hud   # expect a PID and exit status 0 line

# "/healthz green"
curl -s http://127.0.0.1:8765/healthz | python3 -m json.tool

# "DB stops growing without bound" -- already covered by Task 5's tests; spot check:
curl -s http://127.0.0.1:8765/healthz | python3 -c "import json,sys; print(json.load(sys.stdin)['migration_version'])"
# expect: 3

# "a browser with empty localStorage lands on sapphire" -- Task 6 Step 8, repeat here
# if not already confirmed this session.

launchctl unload ~/Library/LaunchAgents/dev.baton.hud.plist
```

- [ ] **Step 3: Update `hud/README.md`'s top-of-file description**

Change the first paragraph from "Throwaway-or-keep live agent-activity HUD" to reflect M1's service status:

```markdown
# HUD

Baton's live agent-activity dashboard. Runs as a service (`baton hud install-service`
on macOS; Linux/Windows land in M2). Separate from the legacy `dashboard/` (do not
start both — see `docs/superpowers/specs/2026-09-10-hud-dashboard-buildout-design.md`
§11.1 for the port-collision resolution). Transport is SSE with resume-on-reconnect.
Storage is SQLite with hourly retention rollups (`hud/hud.db`, gitignored).
```

- [ ] **Step 4: Commit the docs pass**

```bash
git add hud/README.md
git commit -m "docs(hud): M1 — service status, install-service, rebuild"
```

- [ ] **Step 5: Push the branch and open the PR (do not merge — that's Kevin's call)**

```bash
gh repo view Ryfter/baton --json visibility -q .visibility   # confirm PUBLIC, as expected
git push -u origin feat/hud-m1-service
gh pr create --repo Ryfter/baton --base master --head feat/hud-m1-service \
  --title "HUD M1: the HUD becomes a service" \
  --body "$(cat <<'EOF'
Implements M1 of docs/superpowers/specs/2026-09-10-hud-dashboard-buildout-design.md (rev 3, aff5c73):
migrations framework, event_uid/recv_ts + dedup on ingest, extended /healthz,
Last-Event-ID SSE resume, hourly retention pruner + nightly backup, sapphire default
theme, baton hud {serve,status,install-service,rebuild} CLI wired through verbs.yaml,
macOS launchd service unit.

Exit criteria verified: see plan docs/superpowers/plans/2026-09-12-hud-m1-service.md Task 9.
Security baseline unchanged (spec §8.1) — full 44-test prototype suite plus all new
tests green.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
git rev-list --count @{u}..HEAD   # expect 0 -- confirms the push actually landed
```

- [ ] **Step 6: Report back**

Tell Kevin: PR URL, test count (before/after), which of the M1 exit criteria were verified live on this machine vs. still need droid-specific confirmation (the reboot-survival check), and the three decisions captured in Tasks 1/5/7. Do not merge to `master` — that's explicitly his call per `docs/agent-handoffs.md` #4.
