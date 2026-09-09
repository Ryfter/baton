# HUD prototype — design spec

**Date:** 2026-09-09
**Status:** approved (Kevin), ready to build
**Author:** Claude (orchestrator), from a brainstorming session
**Builder:** GLM 5.3 Flash via `opencode run -m openrouter/z-ai/glm-5.3-flash`
**Review:** agy (Gemini Antigravity) judges each "done"; grok gives a final opinion after accept-or-3-rounds.

---

## 1. Purpose

A throwaway-or-keep **prototype** to feel out front-end styles for a live agent-activity
HUD, and to let Kevin pick which front-end "runs" (like a setting). Not a product; not a
replacement for the legacy `dashboard/` (left untouched). Separate top-level `hud/` dir.

Kevin is SSH'd into **droid** (this Mac Mini, primary dev box) and views from another PC, so
the server binds `0.0.0.0:8765` and is reached at **`http://droid:8765/`**.

> ⚠️ Port 8765 is also the legacy `dashboard/`'s port. They cannot both run. The prototype
> takes 8765; do not start the old dashboard alongside it.

## 2. Shape

```
Claude Code hooks ──POST /ingest──▶ hud/server (FastAPI + uvicorn, 0.0.0.0:8765)
  hud/hook_emit.py (fail-open)          │  validate → SQLite (hud/hud.db) → fan out
                                        ▼
                     GET /stream (SSE)  ◀── browser at http://droid:8765/v/<name>
                     GET /events (JSON) ◀── history / derive board+cockpit later
```

- **Transport: SSE**, not WebSocket. The HUD is display-only; `EventSource` auto-reconnects;
  no back-channel needed. (WebSocket was the considered alternative — rejected as unneeded.)
- **Storage: SQLite** (stdlib `sqlite3`), one file `hud/hud.db` (gitignored). Deriving board
  state / cockpit tiles later is a query, not a rewrite. (JSONL was the alternative.)
- **Front-ends: N self-contained `.html` files.** Each is one file, inline `<style>`+`<script>`,
  **zero external network requests, no JS libraries.** Add a look by dropping in a file.

## 3. Event envelope — `hud.event/v1`

```json
{
  "schema": "hud.event/v1",
  "ts": "2026-09-09T07:40:00Z",   // ISO-8601 UTC; server assigns if emitter omits
  "session_id": "abc123",          // Claude Code hook session_id
  "source": "claude-hook",         // claude-hook | baton-journal | manual
  "kind": "pre_tool_use",          // normalized (see §4)
  "agent": "main",                 // "main" or a subagent name, best-effort
  "machine": "droid",              // socket.gethostname() at emit; server fills if absent
  "seq": 42,                       // per-session monotonic, SERVER-assigned
  "payload": { }                   // kind-specific, see §4
}
```

Emitter sends `{session_id, kind, payload, machine, ts?}`. Server assigns `seq`, fills `ts`
and `machine` if missing, sets `source:"claude-hook"`, validates, stores, publishes.

Derivable later (schema-ready, **not built now**): board state (per session: running /
needs-you / stopped from last `kind` + unanswered `notification`); cockpit tiles (counts,
rates, error totals via `GROUP BY`).

## 4. Normalized event kinds (from Claude Code hooks)

| kind | hook | payload fields |
|---|---|---|
| `session_start` | SessionStart | `source` (startup/resume/compact), `cwd` |
| `user_prompt` | UserPromptSubmit | `prompt` (truncated to 500 chars) |
| `pre_tool_use` | PreToolUse | `tool_name`, `tool_input_summary` (short string) |
| `post_tool_use` | PostToolUse | `tool_name`, `ok` (bool), `error` (short, if any) |
| `notification` | Notification | `message` — **the "needs you" signal** |
| `stop` | Stop | — |
| `subagent_stop` | SubagentStop | `agent` (name if available) |
| `pre_compact` | PreCompact | `trigger` (auto/manual) |

Unknown hook name → `kind` = a slugified fallback; never drop the event.

## 5. Files

```
hud/
  __main__.py           # python -m hud → uvicorn hud.server:app --host $HUD_HOST --port $HUD_PORT
  server.py             # FastAPI app: all routes + SSE broadcaster
  store.py              # SQLite: init_db, insert_event, query_events, replay_events
  schema.py             # validate_envelope, normalize_hook (hook JSON → hud.event/v1)
  config.py             # read_config / write_config over hud/config.json
  hook_emit.py          # stdin hook JSON → POST /ingest (timeout 0.25s) → ALWAYS exit 0
  fake_traffic.py       # replay a scripted event sequence to /ingest ; --fast drops sleeps
  requirements.txt      # fastapi, uvicorn[standard]
  config.json           # {"default_frontend": null}
  README.md             # run instructions + the droid:8765 + port-collision notes
  frontends/
    deck.html
    board.html
    cockpit.html
    minimal.html
  tests/
    __init__.py  conftest.py
    test_schema.py       test_store.py     test_server.py
    test_hook_emit.py    test_fake_traffic.py
settings-hooks.snippet.json   # the ~/.claude/settings.json hooks block to add (all 8 events)
```

`.gitignore`: add `hud/hud.db` and `hud/*.db`.

## 6. Backend routes (`hud/server.py`)

| Route | Behaviour |
|---|---|
| `POST /ingest` | body = partial envelope. Fill `seq`/`ts`/`machine`/`source`, validate (`schema.validate_envelope`), `store.insert_event`, publish to SSE subscribers. → `{"ok":true,"id":N,"seq":M}`. Bad body → 422, still never raises to the client beyond that. |
| `GET /stream` | SSE `text/event-stream`. Query `?replay=200` (default 200, max 2000). Emit replayed events first as `event: hud\ndata: <json>\n\n` ascending by id, then live tail. Comment heartbeat `: ping\n\n` every 15s. Drop slow clients cleanly. |
| `GET /events` | `?since=<id>&limit=<n≤2000>&session=<id>&kind=<k>` → JSON array ascending by id. |
| `GET /` | If `config.default_frontend` set **and** `frontends/<it>.html` exists → `302` to `/v/<it>`. Else serve the **chooser** page: the 4 variants, each with name + one-line description + a "Set as default" button (POST /config) + a "just view once" link. |
| `GET /v/{name}` | Serve `frontends/{name}.html`. `name` whitelisted to existing files; else 404. |
| `POST /config` | body `{"default_frontend": "deck" | null}` → `config.write_config` → return new config. |
| `GET /healthz` | `{"ok":true,"events":N,"uptime_s":S}` |

SQLite DDL (`store.init_db`):

```sql
CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         TEXT NOT NULL,
  session_id TEXT NOT NULL,
  source     TEXT NOT NULL,
  kind       TEXT NOT NULL,
  agent      TEXT,
  seq        INTEGER NOT NULL,
  machine    TEXT,
  payload    TEXT NOT NULL          -- JSON
);
CREATE INDEX IF NOT EXISTS ix_events_session ON events(session_id);
CREATE INDEX IF NOT EXISTS ix_events_kind    ON events(kind);
CREATE INDEX IF NOT EXISTS ix_events_ts      ON events(ts);
```

`seq` = `1 + (max seq for that session_id so far)`, computed under a lock/transaction.

Binding: `HUD_HOST` (default `0.0.0.0`), `HUD_PORT` (default `8765`); `python -m hud` passes
`--host`/`--port` through if given.

## 7. Hook emitter (`hud/hook_emit.py`)

- Read all of stdin, parse JSON (Claude Code hook input).
- `normalize_hook()` → partial envelope.
- `POST http://127.0.0.1:8765/ingest` with **total timeout 0.25s** (`urllib` from stdlib is
  fine — keep it dependency-free so it runs even if fastapi isn't importable in that env).
- **Catch every exception. Always `sys.exit(0)`. Never write to stdout** (would look like hook
  output to Claude Code). Optional one-line stderr on failure only if `HUD_DEBUG=1`.
- Target under 50 ms wall time when the backend is down.

`settings-hooks.snippet.json` — the block for `~/.claude/settings.json`, one matcher per event
in §4, each running `python3 /Users/kev/Dev/Baton/hud/hook_emit.py`. (When testing from a
worktree, point at the worktree's path instead; noted in README.) Global install means every
Claude Code session on droid emits — intended, for real traffic.

## 8. Front-end briefs

All four: connect with `new EventSource('/stream?replay=200')` — **relative URL**, so it works
from `droid:8765` on another machine. Show a connection dot (green live / red reconnecting).
Cap the DOM to the last ~500 events (trim oldest). No external requests. No libraries.

- **`deck.html`** — dark (`#0b0e14`), monospace. Top bar: title · connection dot · total event
  count · `⚙ views` link (→ `/`). Body: one **horizontal lane per `session_id`**, most-recently-
  active on top; each lane a right-scrolling strip of event chips colored by kind (tool = blue,
  notification = amber, stop/subagent_stop = grey, error = red). Chip text = `kind` + `tool_name`.
  New session → lane slides in. Idle > 5 min → lane dims. The disler-flavored look.
- **`board.html`** — light, cards. One card per `session_id`. Columns: **Running** /
  **Needs You** (last event is a `notification`) / **Stopped** (last `kind` = `stop`). Card:
  short session id · machine · last tool · event count · age. Cards animate between columns on
  state change. mission-control / Untrivial flavor.
- **`cockpit.html`** — medium/dark. Top: 4 stat tiles — **Active sessions**, **Events/min**
  (rolling 60 s), **Tool calls**, **Errors**. A small hand-drawn SVG sparkline for events/min
  (no lib). Below: compact reverse-chron feed, one line per event. session-pilot flavor.
- **`minimal.html`** — system font, white bg, black text. One `<table>`: time · session · kind ·
  detail, newest on top. `aria-live="polite"`. Colour only for errors (red text). The
  accessible baseline / control.

## 9. Tests (`hud/tests/`, pytest)

- `test_schema.py` — `validate_envelope` accepts good / rejects missing-required; `normalize_hook`
  maps each of the 8 hook shapes to the right `kind` + payload; unknown hook → fallback kind, not dropped.
- `test_store.py` — `insert_event` returns id; `seq` increments per session, independent across
  sessions; `query_events` honours `since` / `limit` / `session` / `kind`; `replay_events` ascending.
- `test_server.py` — `POST /ingest` stores + returns id/seq; a subscriber to `/stream` receives a
  subsequently-ingested event; `GET /events` filters; `GET /` redirects when a default is set and
  shows the chooser when not; `/v/deck` serves, `/v/bogus` 404s; `POST /config` round-trips.
- `test_hook_emit.py` — backend down → process exits 0 in < 300 ms, no stdout; backend up →
  the event lands in the store with the right kind.
- `test_fake_traffic.py` — `fake_traffic.py --fast` against a live test server produces the
  expected event count.

Run: `python -m pytest hud/tests -q` (add `hud` to the settings.json pytest allow-list).

## 10. Explicitly out of scope (YAGNI for the prototype)

Auth, TLS, multi-machine event fan-in (the `machine` field exists; no aggregator), the board /
cockpit **derivation logic beyond what each front-end computes client-side**, writing back to
agents, any change to `dashboard/`, packaging, and a Baton `baton hud` subcommand (later).

## 11. Run

```
cd /Users/kev/Dev/Baton              # (or the build worktree)
pip install -r hud/requirements.txt
python -m hud                         # binds 0.0.0.0:8765
# from the other PC:  http://droid:8765/
python hud/fake_traffic.py --fast    # optional: demo traffic without a live Claude session
```

## 12. Build / review loop (this task)

1. `opencode run -m openrouter/z-ai/glm-5.3-flash` in an isolated `hud-prototype` worktree,
   fed this spec. Then `python -m pytest hud/tests -q`.
2. **agy** judges: spec + `git diff` + test output → `accept` or `polish` + a brief.
3. If `polish` and rounds < 3 → feed the brief back to step 1.
4. On `accept`, or after round 3 → **grok** gives a final opinion on the current state.
5. Claude applies small finalization fixes, re-runs tests, commits on `hud-prototype`.
   **Not merged to master** — Kevin's call.
