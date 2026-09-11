# HUD build-out — design spec (the HUD replaces `dashboard/`)

**Date:** 2026-09-10
**Status:** draft, for Kevin's review — rev. 3 folds in his answers to the remaining open questions: Windows is in scope for M2 alongside macOS/Linux, `tailscale serve` confirmed, KB router and `mydashboard` dropped, a `dashboard/` access log lands at M4, 30-day retention confirmed. Only Maestro hold/release (§15) stays genuinely open, with a stated lean.
**Author:** Claude (Opus 5, orchestrator)
**Builds on:** `docs/superpowers/specs/2026-09-09-hud-prototype-design.md` (the prototype spec — envelope, kinds, routes, SSE+SQLite+static-front-end shape). Everything there still holds unless this document says otherwise.
**Shipped code this extends:** branch `hud-prototype-grok` @ `3a5624a` (`origin`), worktree `/Users/kev/Dev/Baton/.worktrees/hud-prototype-grok`. 44 tests pass.
**Security baseline folded in:** `/tmp/hud-opus-security-review.md` (Opus 5 review, 18 findings) → `/tmp/hud-grok-secfix-report.md` (all fixed).

This is a **design spec**, not an implementation plan. No task-by-task TDD breakdown — that comes later, per milestone.

---

## 1. Purpose

Turn the shipped HUD prototype into **the** Baton dashboard: an always-on, multi-machine, event-sourced activity collector that covers everything the legacy `dashboard/` does, retires `dashboard/`, and **ships as a feature of Baton 2.x** (Kevin, 2026-09-10 — "let's make the HUD a 2.x release, we may be close to that").

Shipping changes the stakes in two specific ways, both carried through this spec: the opt-in telemetry guard (§8.7, D12) is now load-bearing rather than a hedge, and nothing may hard-code `droid` outside config.

### 1.1 Goal

1. The HUD is a **service**, not a thing you remember to start. launchd on droid, survives reboot.
2. It ingests from **four source families**, all normalized into `hud.event/v1`: Claude Code hooks (shipped), the Baton journal / run-log, other agent harnesses (Codex, Herdr-driven grok / cursor-agent, opencode), and machine/system state.
3. It is **multi-machine**: droid is the collector; other boxes POST over the tailnet/LAN. Token auth is load-bearing, not optional.
4. Derived state (board, cockpit aggregates, machine panel) is a **server-side query**, not a client-side guess.
5. It is **observe-only** — "just to see what is going on" (Kevin). Control of the fleet stays in the CLI and, prospectively, a future Hermes / "claw" bot. See D13.
6. At the end, `dashboard/` is deleted from the tree and the HUD ships in Baton 2.x.

### 1.2 Why replace `dashboard/` rather than extend it

| | `dashboard/` | HUD |
|---|---|---|
| Data model | ~25 readers that re-parse `$BATON_HOME` files on every request | append-only event store + projections |
| Freshness | htmx polling of `/partials/*` | SSE push, sub-second |
| Multi-machine | none — reads the local filesystem | collector + authenticated remote ingest |
| Runtime | pwsh-era; several readers shell out to PowerShell (`dark_factory`, quota probes) | Python, no pwsh in the request path (`pwsh` is flaky on this Mac — see memory `baton-pwsh-flaky-on-mac`) |
| Front-end | Jinja + htmx + vendored Chart.js | self-contained static HTML, zero external requests |
| Tests | 33 test files, mostly reader-level | 44 tests incl. a live black-box security probe |
| Size | 5,312 loc of Python | 1,394 loc of Python |

The readers' value is **domain knowledge** (what a journal line means, how a 5h window burns), not code. That knowledge is portable to adapters; the polling/reader architecture is not worth carrying.

Two facts make the swap cheap and are worth stating up front:

- **`dashboard/` is stateless.** It owns no database. Every reader reads `$BATON_HOME` or `~/.claude/knowledge`. The only file it owns is `dashboard/data/api-rates.json`. **There is no data migration** — cutover is a code deletion plus moving one JSON file.
- **Both want port 8765.** They cannot run together today. §11.1 resolves this.

### 1.3 Non-goals

- **Not a control plane.** The HUD is observe-only for the whole of M1–M7: no write-back to agents, no fleet actions, no run answering. Control belongs to the CLI today and to a future Hermes / claw bot tomorrow (D13). The one candidate exception — Maestro hold/release — is scoped but gated on §15.1.
- **Not multi-tenant.** The HUD ships in 2.x and other Baton users can run it, but each install is single-operator: one collector, one token store, one `$BATON_HOME`. Nothing here precludes multi-tenant later — telemetry is opt-in (§8.7), paths are `$BATON_HOME`-relative, no hostname is hard-coded outside config — but no tenant model is built.
- Not a replacement for `/baton:*` slash commands. The HUD observes the fleet; the commands drive it.
- Not a log aggregator. Payloads are *summaries* with hard clamps, never transcripts.

---

## 2. Target architecture

### 2.1 Shape

```
  droid (collector)                              satellite box (N)
  ─────────────────                              ──────────────────
  Claude Code hooks ─┐                           Claude Code hooks ─┐
  journal tailer    ─┤                           journal tailer    ─┤
  harness adapters  ─┼─▶ 127.0.0.1:8765          harness adapters  ─┼─▶ 127.0.0.1:8765
  machine reporter  ─┘    (the collector)        machine reporter  ─┘    hud/forwarder.py
                            │                                              │ spool
                            │                          POST /ingest/batch  │ (jsonl, backoff)
                            │  ◀────────────────── tailnet / LAN ──────────┘
                            ▼
                    hud/hud.db (SQLite, WAL)
                     ├─ events        (append-only)
                     ├─ sessions      (projection, updated on ingest)
                     └─ rollups_hourly(retention survivors)
                            │
            ┌───────────────┼────────────────────┐
            ▼               ▼                    ▼
     GET /stream      GET /api/board       GET /events
     (SSE, topics)    /api/cockpit         (raw history)
                      /api/machines …
                            │
                      browser at http://droid:8765/
```

### 2.2 The forwarder — why hooks never talk to the network

`hook_emit.py` has a 0.25 s total budget and must always exit 0 (it is in Claude Code's critical path). It cannot retry, and it must not be able to redirect telemetry off-box (security finding LOW-4 pinned `HUD_INGEST_URL` to loopback).

So: **every emitter on every box POSTs to `127.0.0.1:8765`, always.** On droid that listener is the collector. On a satellite it is `hud/forwarder.py`, which:

- speaks the same `POST /ingest` contract (so emitters are byte-identical on every box),
- appends each accepted envelope to a local spool `$BATON_HOME/hud-spool.jsonl`,
- drains the spool to the collector with `POST /ingest/batch`, exponential backoff + jitter, at-least-once,
- caps the spool at `HUD_SPOOL_MAX_MB` (default 64), dropping oldest and counting the drops into `/healthz`.

The forwarder is the *only* component that holds a collector URL or a network token. `hook_emit.py`'s loopback pin stays exactly as it is.

### 2.3 File layout (new/changed marked)

```
hud/
  __main__.py            # + subcommands: serve | forward | install-service | status
  server.py              # routes, middleware, SSE fan-out
  auth.py         NEW    # token store, scopes, cookie upgrade
  store.py               # + uid dedup, projections
  migrations.py   NEW    # ordered, forward-only, PRAGMA user_version
  schema.py              # + new kinds, per-kind payload clamps
  derive.py       NEW    # sessions projection + board/cockpit/machines/gauges queries
  retention.py    NEW    # pruner, hourly roll-ups, nightly backup
  hook_emit.py           # UNCHANGED contract: loopback only, fail-open, exit 0
  forwarder.py    NEW    # satellite-box loopback listener + spool + drain
  fake_traffic.py        # + multi-source scenarios
  config.py              # + default_theme, stale thresholds
  data/
    api-rates.json  MOVED from dashboard/data/
  adapters/       NEW
    journal.py           # model-routing-log.md + routing-journal.jsonl tailer
    runs.py              # runs/<id>/events.jsonl, decisions.jsonl, tasks/*/attempts.jsonl
    machine.py           # system sampler + live-agent roster
    harness/{codex,grok,cursor,opencode}.py
  service/        NEW
    dev.baton.hud.plist            # macOS collector (launchd)
    dev.baton.hud-forwarder.plist  # macOS satellite (launchd)
    hud.service                    # Linux collector (systemd --user)
    hud-forwarder.service          # Linux satellite (systemd --user)
    hud-forwarder-task.xml  NEW    # Windows satellite (Task Scheduler)
  frontends/
    hud.js          NEW  # shared SSE client + theme + formatters (same-origin, no libs)
    board.html cockpit.html deck.html minimal.html
    machines.html   NEW
    themes/{dark,sapphire,lapis-velvet,sandstone,obsidian}.css   # obsidian NEW
  versions/v1..v4/       # FROZEN — never edited; v5 appended at M6
  tokens.json            # gitignored, 0600, hashed secrets
  tests/
```

`.gitignore` additions: `hud/hud.db*`, `hud/tokens.json`. (The spool lives at `$BATON_HOME/hud-spool.jsonl`, outside the repo.)

---

## 3. Ingest seam and source adapters

The **only** integration seam is `POST /ingest` carrying a `hud.event/v1` envelope. Every adapter is a separate process that translates its world into envelopes. Adding a source never touches `server.py`.

### 3.1 `claude-hook` — SHIPPED, unchanged

`hud/hook_emit.py`, wired via `hooks/hooks.json` at M7 (§8.7). Kinds per prototype spec §4.

### 3.2 `baton-journal` / `baton-run` — the journal tailer (M3)

Baton's journal is written in five places; the tailer must read all of them:

| written by | file | format |
|---|---|---|
| `scripts/hooks/log-tool-call.ps1:243`, `scripts/fleet-lib.ps1:706`, `scripts/code-lib.ps1:210`, `scripts/parse-otel.ps1:232`, `scripts/start-lib.ps1:224` | `$BATON_HOME/model-routing-log.md` | pipe-delimited: `<ts> \| <source> \| <target> \| … \| job:<id> \| phase:<p> \| host:<h> \| tier:<t> \| tok:<n>(basis)`; sources `hook \| otel \| note \| lesson \| fleet \| dashboard` |
| `scripts/routing-dispatch.ps1:73` | `$BATON_HOME/routing-journal.jsonl` | JSONL dispatch attempts: `capability, candidate, cost_tier, exit_code, duration_s, passed, score, reason, grader, stage` |
| `scripts/window-budget-lib.ps1:674` | `$BATON_HOME/routing-journal.jsonl` | JSONL `event: window_pressure` — Governor de-ranks |
| `scripts/conductor-lib.ps1:361,367` | `$BATON_HOME/runs/<run-id>/{events,decisions}.jsonl` | JSONL conductor run events + decisions |
| `scripts/fleet-executor-lib.ps1:2283` | `$BATON_HOME/runs/<id>/tasks/<t>/attempts.jsonl` | JSONL per-task attempts |
| `scripts/runs-lib.ps1:65` | `$BATON_HOME/runs/<id>/events.jsonl` | JSONL run lifecycle |

Reuse the parse rules already proven in `dashboard/readers/journal.py` — in particular `_extract_trailing_tags`, which peels `job:`/`phase:` and drops `host:`/`tier:`/`tok:`, and stops on unknown trailing tags (fail-closed). Port it, don't re-derive it.

Mechanics:
- cursor file `$BATON_HOME/hud-tail-cursor.json` → `{path: {inode, offset}}`; truncation or inode change ⇒ re-read from 0 (dedup by `event_uid` makes that safe).
- `event_uid = sha256(path + "@" + byte_offset + "|" + line)[:32]` — deterministic, so a re-read is idempotent. The offset is required: two byte-identical journal lines (same timestamp, same content) are legal and must not collapse into one event.
- **backfill** on first run: `--since 7d` default, so the HUD is not empty on day one.
- polling `stat()` at 1 Hz. No inotify/FSEvents dependency; the files are small and append-only.

### 3.3 Other harnesses (M6)

| harness | signal available | adapter approach |
|---|---|---|
| Codex (`codex:codex-rescue`, `/baton:codex`) | dispatch already lands in the journal | mostly free via §3.2; adapter adds turn-level events where the CLI writes a session file |
| grok / cursor-agent via Herdr | Herdr owns the workspace; agents write report files | poll `herdr agent list --json` + the agent's workspace for state transitions → `harness_state`, `harness_turn` |
| opencode | `opencode run` is one-shot | wrap the invocation: emit `session_start` / `stop` around it, `dispatch` from the exit code |

Every harness adapter emits `source: <harness>` and sets `session_id` per the convention table in §4.2. Where a harness exposes tool-level detail, reuse the existing `pre_tool_use` / `post_tool_use` kinds so the front-ends need no changes.

### 3.4 `machine` — the metrics reporter (M4)

`hud/adapters/machine.py`, one per box, every 15 s (`HUD_SAMPLE_S`):

- `machine_sample` — `{cpu_pct, load1, mem_used_gb, mem_total_gb, disk_free_gb, disk_total_gb, gpu_gb, gpu_used_gb, uptime_s}`
- `agent_alive` — roster: `{agents: [{kind, pid, session_id, cwd, last_seen}]}`, sourced from `$BATON_HOME/sessions/*.json` (the session-marker files — `{agent, session_id, cwd, started_at, last_seen_at, kind}`) plus a process scan for known harness binaries.

Dependency policy: `psutil` if importable, else a stdlib fallback per platform — `os.getloadavg` and `shutil.disk_usage` everywhere, plus `sysctl -n hw.memsize` + `vm_stat` on darwin and `/proc/meminfo` + `/proc/stat` on Linux. Windows has no `os.getloadavg` equivalent, so `psutil` is effectively required there; the stdlib fallback (ctypes `GlobalMemoryStatusEx` for memory, `GetSystemTimes` deltas for a rough CPU%, no load-average concept) is best-effort only and flagged as such in the sample payload. All three platforms are first-class from M2 (§8.5). The GPU / LM Studio fields overlay `$BATON_HOME/systems/inventory.json` when present.

---

## 4. `hud.event/v1` evolution

### 4.1 What stays frozen

The seven required fields — `schema, ts, session_id, source, kind, seq, payload` — plus `agent` and `machine`. All five front-ends and the four frozen `versions/vN` galleries depend on exactly this shape. **Nothing is removed, renamed, or retyped.**

### 4.2 What extends

**New `source` values** (whitelisted server-side, bound to the ingest token — §8.2):
`claude-hook | baton-journal | baton-run | codex | grok | cursor | opencode | machine | manual`

This reverses correctness-fix C4, which pinned `source` to `"claude-hook"` unconditionally. It must be replaced by a token-scoped whitelist, never by trusting the body.

**`session_id` conventions** — the field keeps its name and its role as the `seq` partition key and the per-lane identity:

| source | `session_id` |
|---|---|
| `claude-hook` | Claude Code session id (unchanged) |
| `baton-journal` | `job:<job-id>` if tagged, else `run:<run-id>`, else `journal:<YYYY-MM-DD>` |
| `baton-run` | `run:<run-id>` |
| harnesses | harness session id, else `<harness>:<pid>@<machine>` |
| `machine` | `machine:<hostname>` |

**New optional envelope fields** (readers must ignore unknown fields; absence is always legal):

| field | type | meaning |
|---|---|---|
| `event_uid` | str ≤64 | emitter-assigned idempotency key. `UNIQUE`; duplicate ⇒ `INSERT OR IGNORE`, return existing id |
| `recv_ts` | str | **server-assigned** arrival time (collector clock). Never client-settable |
| `project` | str ≤64 | Baton project id, for per-project views |
| `job_id` / `run_id` | str ≤64 | Baton correlation |

**New kinds:**

| kind | source family | payload |
|---|---|---|
| `dispatch` | journal / fleet | `provider, model, capability, cost_tier, duration_s, exit_code, passed, score, reason, grader, stage` |
| `tokens` | journal (otel) | `model, in, out, cost_usd` |
| `gate` | journal | `gate, verdict (accept\|polish\|reject), score, reason` |
| `governor` | journal | `model, pressure, adjust, reason, capability` |
| `job_phase` | journal | `job_id, from, to` |
| `run_state` | run | `run_id, status, step, parked_question` |
| `note` / `lesson` | journal | `target\|category, text` |
| `machine_sample` | machine | see §3.4 |
| `agent_alive` | machine | see §3.4 |
| `harness_state` / `harness_turn` | harness | `state`/`summary, tokens_in, tokens_out` |
| `control` | server (self-audit) | `action, target, actor, result` |

Every new payload field gets a clamp in `_PAYLOAD_CAPS` (`server.py:132`). The existing caps (`tool_input_summary` 120, `message`/`prompt`/`cwd` 500, `error` 200) stay. Numeric fields are coerced or dropped; a non-scalar is dropped, never stored.

### 4.3 The versioning contract

`schema` stays the literal `"hud.event/v1"` through this entire build-out. The rule:

- **Additive-optional ⇒ still v1.** New `kind`, new `source`, new optional field, new payload key. Consumers ignore what they don't know.
- **`hud.event/v2` only when** a required field is removed or renamed, an existing field's type changes, or `session_id`'s partition semantics change.
- On a v2, the collector accepts **both** on `/ingest` and up-converts on write, so a stale emitter on a satellite box never black-holes. `/events` and `/stream` always emit the newest version.

Concretely: nothing in M1–M7 is expected to require v2. If it does, that is the signal to stop and re-spec.

---

## 5. Storage

### 5.1 Schema evolution

`hud/migrations.py`: an ordered list of `(version, [sql, …])`, applied in one transaction at startup, gated on `PRAGMA user_version`. Forward-only. **Never drop a column** — a rolled-back binary must still read the file.

```sql
-- m2: multi-machine + idempotency
ALTER TABLE events ADD COLUMN event_uid TEXT;
ALTER TABLE events ADD COLUMN recv_ts   TEXT;
ALTER TABLE events ADD COLUMN project   TEXT;
ALTER TABLE events ADD COLUMN job_id    TEXT;
ALTER TABLE events ADD COLUMN run_id    TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS ux_events_uid      ON events(event_uid) WHERE event_uid IS NOT NULL;
CREATE INDEX        IF NOT EXISTS ix_events_mach_ts  ON events(machine, ts);
CREATE INDEX        IF NOT EXISTS ix_events_src_kind ON events(source, kind);
CREATE INDEX        IF NOT EXISTS ix_events_recv     ON events(recv_ts);
CREATE INDEX        IF NOT EXISTS ix_events_project  ON events(project, ts);

-- m3: board projection
CREATE TABLE IF NOT EXISTS sessions (
  session_id   TEXT PRIMARY KEY,
  machine      TEXT, source TEXT, project TEXT, agent TEXT,
  first_ts     TEXT, last_ts TEXT, last_recv_ts TEXT,
  last_kind    TEXT, last_detail TEXT,
  status       TEXT,          -- running|needs_you|stopped|failed|stale
  n_events     INTEGER DEFAULT 0,
  n_errors     INTEGER DEFAULT 0,
  needs_you_since TEXT,
  tokens_in INTEGER DEFAULT 0, tokens_out INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS ix_sessions_status ON sessions(status, last_ts DESC);
CREATE INDEX IF NOT EXISTS ix_sessions_mach   ON sessions(machine, last_ts DESC);

-- m4: retention survivors
CREATE TABLE IF NOT EXISTS rollups_hourly (
  bucket_ts TEXT, machine TEXT, source TEXT, kind TEXT, project TEXT, model TEXT,
  n INTEGER, n_errors INTEGER, tokens_in INTEGER, tokens_out INTEGER, cost_usd REAL,
  PRIMARY KEY (bucket_ts, machine, source, kind, project, model)
);
```

The existing `ix_events_session`, `ix_events_kind`, `ix_events_ts`, `ix_events_session_seq` all stay.

### 5.2 `seq` under multi-machine

`seq` remains **collector arrival order within a `session_id`**, assigned under `BEGIN IMMEDIATE` + the process lock (`store.py:108–113`). Honest limitation: a spool drained after an outage gets seq numbers reflecting arrival, not emission. Emitters that care set `payload.emit_seq`. Do not try to make `seq` globally meaningful — it is a per-lane tiebreaker, and `ts`/`recv_ts` carry time.

### 5.3 Retention, roll-up, backup

- `HUD_RETENTION_DAYS` default **30** for raw rows.
- Before deleting, the pruner rolls the row's contribution into `rollups_hourly`. Cost/token history is therefore **kept indefinitely** at hourly granularity; raw event bodies are not.
- `HUD_MAX_ROWS` default 2,000,000 as a hard second bound (whichever binds first).
- Pruner runs hourly as an asyncio task, in bounded batches (10k rows) with `PRAGMA incremental_vacuum`; a weekly `VACUUM` at 04:11 local.
- Nightly backup via the `sqlite3` online backup API → `$BATON_HOME/backups/hud-YYYYMMDD.db`, keep 7. The DB itself stays gitignored; **it is never committed** (per `publishing-guard.md` — it contains prompt text and command lines).

### 5.4 Where the event store is *not* the source of truth

Deliberate hybrid. Config-shaped, slowly-changing data is read directly at request time, not forced through the event log:

`fleet.yaml` (providers/machines catalog) · `$BATON_HOME/jobs/<id>/manifest` · `$BATON_HOME/projects/` registry · `~/.claude/knowledge` (KB) · `systems/inventory.json` · `hud/data/api-rates.json`.

Rule of thumb: **if it has a timestamp and happened, it's an event; if it describes how things are configured, it's a read.**

---

## 6. Derived state — server-side, query-driven

The prototype's front-ends each compute board columns and cockpit tiles in JavaScript from the SSE tail. That was a prototype shortcut with three real defects: every viewer can disagree, a fresh page load only sees the replay window, and nothing outside the browser can query it. Build-out moves all of it server-side.

### 6.1 The `sessions` projection

Updated **in the same transaction as the event insert** (`store.insert_event`), so the board is never stale relative to the stream. Status rules, evaluated in order:

| status | rule |
|---|---|
| `needs_you` | last kind is `notification`, or `run_state.status == 'parked'`, with no later `user_prompt` / `pre_tool_use` |
| `failed` | last `run_state.status == 'failed'`, or a `gate` with `verdict == reject`, or ≥1 `post_tool_use.ok == false` since the last `user_prompt` |
| `stopped` | last kind ∈ {`stop`, `subagent_stop`, `harness_state:done`} |
| `stale` | no event for `HUD_STALE_S` (default 900) and not already `stopped` |
| `running` | otherwise |

`stale` is new versus the prototype and is the honest answer to a crashed agent — the prototype would have shown it as `running` forever.

A backfill/rebuild path (`derive.rebuild_sessions()`) recomputes the whole projection from `events`; it runs on a migration that changes the status rules, and is exposed as `baton hud rebuild`.

### 6.2 Aggregates

`derive.py` owns the queries; no aggregate is computed in a front-end.

- **cockpit**: `active_sessions`, `events_per_min` (rolling `window` s, default 60), `tool_calls`, `errors`, `tokens_in/out`, `cost_usd`, `by_model[]`, `by_machine[]`. Windows ≤ 24 h read `events`; longer windows read `rollups_hourly`.
- **machines**: last `machine_sample` per host, live-agent roster, event rate, `last_seen`, `online` (`recv_ts` within 3× sample interval), `skew_s`.
- **gauges**: 5 h window burn per project + cap snapshots, from `tokens`/`dispatch`/`governor` — the parity target for `dashboard/readers/gauges.py`.

### 6.3 Push, not poll

`/stream` gains **topics**. Alongside the raw `hud` event, the server pushes recomputed snapshots as named SSE events, throttled to ≤ 1/s and only when the snapshot actually changed:

```
event: hud       data: {…envelope…}          # raw, unchanged
event: board     data: {sessions:[…], counts:{…}}
event: cockpit   data: {…aggregates…}
event: machines  data: {…per-host…}
```

`GET /stream?topics=hud,board` subscribes selectively. Front-ends that only render the board no longer parse every raw event.

### 6.4 Resume

Every SSE frame carries `id: <event id>`. On reconnect `EventSource` sends `Last-Event-ID`; the server replays **from that id** instead of a fixed window. This closes a real prototype gap: today `/stream?replay=200` plus a replayed-id set silently loses events if a client is disconnected for longer than 200 events. Fixed-window replay remains for a cold client (`?replay=N`, N ≤ 2000).

---

## 7. Route surface

### 7.1 Ingest and transport

| Route | Scope | Behaviour |
|---|---|---|
| `POST /ingest` | `ingest` | one envelope. Body ≤ 64 KB. `source` must be in the token's allowed set; `machine` must match the token's bound machine (or the token must be unbound). `INSERT OR IGNORE` on `event_uid`. → `{"ok":true,"id":N,"seq":M,"dup":bool}` |
| `POST /ingest/batch` | `ingest` | `{"events":[…]}`, ≤ 500 events, ≤ 1 MB total. Per-event result array; a bad event is reported, not fatal. The forwarder drain path. |
| `GET /stream` | `read` | SSE. `?topics=hud,board,cockpit,machines&replay=N&machine=&project=`. Honors `Last-Event-ID`. `id:` on every frame. `: ping` every 15 s. Bounded per-subscriber queue, evict slow clients (unchanged). |
| `GET /events` | `read` | `?since=&limit=≤500&session=&kind=&source=&machine=&project=` → JSON array ascending by id |

### 7.2 Derived / query

| Route | Returns |
|---|---|
| `GET /api/board?machine=&project=&status=` | the `sessions` projection + column counts |
| `GET /api/cockpit?window=60&machine=&project=` | §6.2 aggregates |
| `GET /api/machines` | per-host state, agent roster, online/skew |
| `GET /api/sessions/{sid}` | session header + paged events |
| `GET /api/projects` / `GET /api/projects/{id}` | per-project roll-up (events, cost, jobs, last activity) |
| `GET /api/gauges?window=5h` | 5 h burn + cap snapshots |
| `GET /api/runs` / `GET /api/runs/{id}` | conductor runs from `run_state` + `runs/<id>/` reads |
| `GET /api/jobs` / `GET /api/jobs/{id}` | job index from `job_phase` + manifest reads |
| `GET /api/agents` | declared-vs-observed agents (parity target: `readers/agent_observability.py`) |
| `GET /api/alerts` | derived health alerts (parity target: `readers/factory_health.py`) |

All read endpoints accept `?machine=` — **machine-scoped views are a first-class filter**, not a client-side facet.

### 7.3 Views, admin, health

| Route | Scope | Behaviour |
|---|---|---|
| `GET /` | `read` | default front-end redirect, else chooser (unchanged) |
| `GET /v/{name}` · `GET /themes/{name}.css` · `GET /versions` · `GET /{vid}/…` | `read` | unchanged; `_SEG_RE` allowlist stays |
| `GET /static/hud.js` | `read` | the shared front-end module (§9.2) |
| `POST /config` | `admin` | `{default_frontend, default_theme}` — **the only write endpoint in the whole surface** |
| `GET /healthz` | public | `{ok, events, sessions, uptime_s, db_bytes, subscribers, ingest_rate_1m, spool_drops, last_event_recv_ts, migration_version}` |
| `GET /readyz` | public | 200 once migrations applied and the DB is writable |

`/healthz` and `/readyz` are **deliberately exempted** from the auth middleware (which today 401s every route off-loopback) so launchd, the forwarder and an uptime check can probe without a credential. They carry counters only — never event content, never a session id, never a hostname other than the collector's own.

### 7.4 Controls — **not built** (D13)

An earlier draft of this spec put a `POST /control/{action}` allowlist in M7: the legacy ollama / LM Studio controls plus the parked-question reply `runs/{id}/answer`. **Kevin cut it** (2026-09-10). The HUD is an observe-only control plane; control stays in the CLI and, prospectively, a Hermes / claw bot.

Consequences, applied throughout this spec:

- No `POST /control/*` route. `POST /config` is the only write endpoint, and it writes a 40-byte preferences file, not fleet state.
- The `admin` scope (§8.2) shrinks to `POST /config` alone.
- The `control` kind (§4.2) stays defined but is **unused** — reserved so a future control layer emitting into the HUD does not need an envelope change.
- `dashboard/routers/controls.py` and the `runs/{id}/answer` POST are **dropped, not ported** (§10.1).

The one item still in play is Maestro hold/release, which Kevin asked to keep. It is a write, so it is scoped but gated — §10.1 and §15.1.

Whatever eventually owns control will very likely need to *see* what the HUD sees. The HUD's answer to that is `GET /api/*` + `/stream` with a `read`-scoped token, not a control endpoint bolted onto the collector.

---

## 8. Security and deployment

The perimeter is now the whole story: multi-machine ingest means the token model, TrustedHost allowlist, 64 KB body cap and Origin checks from the security fix pass are **required baseline**, not hardening extras.

### 8.1 What is already true (keep, don't regress)

Default bind `127.0.0.1` · off-loopback without `HUD_TOKEN` fails closed (401 everything) + loud stderr warning · JSON-only `Content-Type` (415 otherwise) · cross-`Origin` write refused (403) · `TrustedHostMiddleware` allowlist · 64 KB body cap on `/ingest` and `/config` · payload clamps in `_fill` · `_SEG_RE` path allowlist (NUL ⇒ 404) · `asyncio.to_thread` for every SQLite call · `openapi_url=None` · `MAX_SESSIONS=200` DOM eviction · `==`-pinned deps · `hmac.compare_digest` token comparison.

Opus's review found **no XSS, no SQLi, no path traversal**. Front-ends render untrusted event data through `textContent` only. That property is a **hard invariant** for every new front-end and every new payload field: no `innerHTML` with interpolation, ever.

### 8.2 Token model (M2)

A single shared secret does not survive multi-machine: a satellite's ingest token must not be able to read every prompt on droid.

`hud/tokens.json` (0600, gitignored) or `HUD_TOKENS`:

```json
[{"name":"droid-local","sha256":"…","scopes":["ingest","read","admin"],"sources":["*"],"machines":["droid"]},
 {"name":"box2-ingest","sha256":"…","scopes":["ingest"],"sources":["claude-hook","machine","codex"],"machines":["box2"]},
 {"name":"kevin-browser","sha256":"…","scopes":["read"],"sources":[],"machines":[]}]
```

- Secrets stored as **sha256 hashes**; compared with `hmac.compare_digest`.
- Scopes: `ingest` (POST /ingest* only) · `read` (all GETs) · `admin` (**`POST /config` only** — the HUD is observe-only, D13, so `admin` grants preference changes and nothing else).
- An `ingest` token's `sources` and `machines` are **enforced against the envelope** — a satellite cannot forge `source: claude-hook, machine: droid`.
- Plain `HUD_TOKEN` stays as the all-scopes single-box fallback so nothing breaks between M1 and M2.
- Per-token ingest rate limit: token bucket, default 200 ev/s, 429 over.

### 8.3 Browser auth

`EventSource` cannot set headers, so `?t=` stays as the bootstrap. But a token in the URL leaks into history, referrers and logs. Fix: on a successful `?t=` request, set `hud_sess` — `HttpOnly; SameSite=Strict; Path=/; Secure` when TLS — and have the front-end strip `?t=` with `history.replaceState`. Reconnects then carry the cookie.

Because a cookie is now ambient, the existing Origin + `Content-Type: application/json` checks on writes become **load-bearing CSRF defence**. They are already implemented (`_require_json_write`, `server.py:88`); they must never be relaxed. Observe-only (D13) shrinks what CSRF could achieve to "change Kevin's default layout", but the checks stay — `POST /ingest` is still a write, and forged `notification` events on the board are a social-engineering surface (security finding HIGH-2).

### 8.4 Transport

- Home LAN: plain HTTP on `0.0.0.0:8765`, TrustedHost limited to `droid`, `droid.local`, loopback + `HUD_ALLOWED_HOSTS`.
- Off-LAN: **tailnet only**. `tailscale serve` terminates TLS with a real `*.ts.net` cert; add the MagicDNS name to `HUD_ALLOWED_HOSTS`. No self-signed certs (they train bad habits and break `EventSource` silently in some browsers).
- Never WAN-exposed. No port forwarding. Announce URLs per the standing network-reachable-dev-servers rule: `http://droid:8765/` for LAN, the MagicDNS name off-LAN — never `localhost` to a remote operator.

### 8.5 Service management

Three supervisors: one of Kevin's candidate satellite boxes is Windows (confirmed 2026-09-11), so macOS, Linux, and Windows are all first-class from M2 — see D15. `baton hud install-service` detects the platform and installs the right unit; `baton hud status` reports supervisor state + `/healthz` from any of the three.

**macOS — `hud/service/dev.baton.hud{,-forwarder}.plist` → `~/Library/LaunchAgents/`:**

- `RunAtLoad` + `KeepAlive` (`SuccessfulExit: false`), `ThrottleInterval 10`
- `EnvironmentVariables`: `HUD_HOST=0.0.0.0`, `HUD_PORT=8765`, `BATON_HOME`, `HUD_TOKENS`
- `StandardOutPath`/`StandardErrorPath` → `$BATON_HOME/logs/hud.{out,err}.log`

**Linux — `hud/service/hud{,-forwarder}.service` → `~/.config/systemd/user/`:**

- `[Service] Restart=always`, `RestartSec=10`, `Type=simple`
- `EnvironmentFile=$BATON_HOME/hud.env` (same variables; keeps `HUD_TOKENS` out of the unit file, which is world-readable by default)
- Logs to the journal (`journalctl --user -u hud`); the file-rotation logic in `retention.py` is macOS-only and no-ops here
- `systemctl --user enable --now hud`; needs `loginctl enable-linger $USER` so it survives logout — `install-service` checks for it and says so rather than silently installing something that dies at logout

**Windows — `hud/service/hud-forwarder-task.xml` → registered via `schtasks /create /xml`:**

- A Task Scheduler task, not a Windows Service — no admin rights and no MSI needed, matching the zero-install spirit of the launchd/systemd units.
- Trigger `AtLogon` (the current user), `RestartOnFailure` with a 10 s interval and no retry cap (Task Scheduler's own restart policy, the closest analogue to `KeepAlive`/`Restart=always`).
- Environment carried via a small `hud-forwarder.cmd` wrapper the task actually launches (Task Scheduler XML environment blocks are awkward to author by hand); the wrapper reads `%BATON_HOME%\hud.env` for `HUD_TOKENS` etc., mirroring the Linux `EnvironmentFile` pattern instead of inventing a third config shape.
- Logs to `$BATON_HOME/logs/hud-forwarder.{out,err}.log`, same convention as macOS.
- The **collector** role is not offered on Windows in M2 — only the forwarder. Running the actual event store + SSE server on a Windows box is not a design problem, just untested scope; nothing here prevents it later, but droid (or any Linux/macOS box) stays the collector for now.

The **collector** unit is normally only installed on droid; the **forwarder** unit on every satellite, whatever its OS. Nothing about the collector is macOS-specific, so a Linux box could take over as collector without a code change.

### 8.6 Failure behaviour — stated explicitly

| event | behaviour |
|---|---|
| collector restart | emitters keep POSTing to loopback (droid) / the forwarder (satellite). Browsers reconnect via `EventSource` and resume from `Last-Event-ID`. WAL means no corruption. |
| network partition | forwarder spools; drains on recovery with backoff. At-least-once + `event_uid` dedup ⇒ no duplicates in the store. |
| spool full | oldest dropped, `spool_drops` counter surfaced in `/healthz` and on the machines panel. Loud, not silent. |
| clock skew | `recv_ts` (collector clock) is authoritative for ordering; `ts` (emitter) is displayed. Skew > 120 s ⇒ `payload.ts_skew_s` stamped and the machine flagged in `/api/machines`. |
| collector disk full | ingest returns 507, pruner runs early, `/healthz` goes red. Emitters fail open (they always did). |
| satellite emits an unknown `kind` | stored with a slugified kind — never dropped (prototype rule, preserved) |

### 8.7 Plugin lifecycle and the opt-in guard

At M7 the 8 hook matchers move from Kevin's hand-edited `~/.claude/settings.json` into the plugin's own `hooks/hooks.json`, pointing at `${CLAUDE_PLUGIN_ROOT}/hud/hook_emit.py` — so installing Baton installs HUD telemetry.

Because the HUD **ships in 2.x**, that is no longer a hypothetical: it would silently start recording prompts, file paths and Bash command lines for every Baton user who upgrades. Guard: `hook_emit.py` returns immediately unless `$BATON_HOME/hud-enabled` exists (or `HUD_ENABLED=1`) — an `os.path.exists` check **before** any import, so the disabled path costs ~15 ms. The file is created by `baton hud install-service` (i.e. by the act of deliberately standing the HUD up), never by installing or upgrading the plugin.

This is the single most important line in the 2.x release. It is tested (`test_hook_emit.py`: guard absent ⇒ zero network, zero DB writes, exit 0, < 20 ms) and it is what §12.3's probe asserts on a fresh install. It is also the seam a future multi-tenant mode would build on.

---

## 9. Front-end

### 9.1 Which layouts graduate

| layout | verdict | role |
|---|---|---|
| `board` | **graduates — primary** | replaces the legacy home page and cockpit grid. Columns Running / Needs You / Failed / Stopped, machine-scoped, `?machine=` filter. Absorbs `cards` as a grid/column toggle. |
| `cockpit` | **graduates** | aggregates, economics, gauges. The `/api/cockpit` + `/api/gauges` surface. |
| `machines` | **new, graduates** | per-box panel: samples, live agents, online/skew, spool drops. Has no legacy equivalent worth porting. |
| `deck` | kept as alternate | ambient/wall display. The look Kevin liked; not the working view. |
| `minimal` | kept as alternate | accessible baseline **and** the no-SSE fallback. Must keep working with JS disabled for history (`/events` rendered server-side). |
| `cards` | **demoted** | folded into `board` as a layout toggle. It duplicated board's data with a different arrangement. |

"Graduates" has a concrete meaning: the layout reads the derived `/api/*` endpoints and the named SSE topics, is machine-scopable, and has a parity gate (§12.4) behind it. A layout still deriving state in JavaScript has not graduated.

### 9.2 Shared module

Five self-contained files duplicated the SSE client, theme picker and formatters 5×; at build-out size that is a maintenance tax and a correctness hazard (MED-2 had to be fixed in three files). Introduce exactly **one** shared same-origin module `hud/frontends/hud.js`, served at `/static/hud.js`: EventSource client with resume, topic subscription, theme bootstrap, time/number formatters, and the `MAX_SESSIONS` eviction helper.

Each layout keeps its own CSS and DOM. The invariants hold: **no external network requests, no third-party libraries, no CDN.** `versions/vN/` keeps its inlined copies and is not touched.

### 9.3 Gallery

`/versions`, `/{vid}/…` stay. `hud/versions/v1..v4/` remain **frozen** — no edits, ever. M6 appends `v5` (the first build-out UI) and updates `versions/index.json`. The gallery is design history, and it is the reason the visual regressions in the security fixes were provably contained.

### 9.4 Themes

`dark`, `sapphire`, `lapis-velvet`, `sandstone` ship today. M6 adds **`obsidian`** — a faithful port of `dashboard/Design from Google stitch/DESIGN.md` ("Obsidian Command": acid green = live, electric purple = decision-needed/human-in-the-loop, neon cyan = data/steering; Hanken Grotesk + JetBrains Mono; 4 px radii; luminescent strokes instead of shadows). This is how the prior Flight Deck design intent survives the retirement of `dashboard/`. Fonts must be self-hosted or fall back to system stacks — no Google Fonts request.

**Default theme: `sapphire`** (Kevin, 2026-09-10 — the prototype's open theme question is now closed). The shipped prototype defaults to `dark`; flipping that default is a small M1 change in three places:

1. `hud/config.py` `_DEFAULT` gains `"default_theme": "sapphire"`.
2. The theme-bootstrap script in each front-end and in `_chooser_html` (`server.py:329`, `:435`) falls back to the server default instead of the literal `"dark"`. The `ALLOWED` whitelist check stays exactly as it is (security finding LOW-1).
3. `POST /config` accepts `default_theme`, validated against `THEME_NAMES`.

The picker and per-browser `localStorage` override both stay — `sapphire` is the default, not a lock. Because the default now lives server-side, every browser and every machine agrees on it out of the box; `localStorage` only records a deliberate per-device deviation. `obsidian` arriving at M6 does not change the default.

---

## 10. Feature-parity map vs `dashboard/`

The contract for deleting `dashboard/`. Every router and reader is accounted for: ported, deferred, or **dropped on purpose**.

### 10.1 Routers

| legacy | routes | HUD equivalent | M | notes |
|---|---|---|---|---|
| `main.py` `/` + `home.py` | `/`, `/partials/home-{header,floor}`, `/api/home-board`, `/api/command-palette` | `/api/board` + `/api/projects` → `board` front-end | M4 | attention rail = the `needs_you` column. Command palette dropped (Kevin uses slash commands). |
| `cockpit.py` | `/partials/cockpit-grid`, `/api/cockpit-grid` | `/api/board`, `/api/cockpit` | M4 | legacy's "live pane tails" **dropped** — §16 |
| `machines.py` | `/machines` | `/api/machines` + `machines.html` | M4 | HUD's is live samples; legacy's was static `fleet.yaml` |
| `jobs.py` | `/partials/jobs`, `/jobs/{id}` | `/api/jobs`, `/api/jobs/{id}` | M5 | index from `job_phase` events; detail still reads the manifest (§5.4) |
| `runs.py` | `/partials/runs`, `/partials/assignments`, `/runs/{id}` | `/api/runs`, `/api/runs/{id}` | M5 | read side ported. **`POST /runs/{id}/answer` is dropped, not ported** (D13) — the HUD shows a run is parked and what it is asking; answering happens in the CLI. |
| `projects.py` | `/projects`, `/projects/{id}`, `/partials/projects` | `/api/projects` | M5 | needs the `project` envelope field |
| `gauges.py` | `/gauges`, `/partials/gauges`, `/api/gauges` | `/api/gauges` | M5 | biggest reader (431 loc); the quota *probes* stay pwsh and feed `governor` events |
| `dark_factory.py` | `/dark-factory/status`, `/dark-factory/partials/panel` | `/api/board?source=baton-journal` + a panel | M5 | legacy shells out to pwsh per request; HUD reads events |
| `controls.py` | `POST /controls/ollama/stop-all`, `/controls/lmstudio/{load,unload,server/stop}` | **dropped for now** — the CLI (and a future Hermes/claw bot) owns control | — | D13. Not a capability loss: `/baton:models`, `/baton:fleet` and the LM Studio CLI already do all four. |
| `kb.py` | `/kb/search`, `/partials/{kb-search,decision}` | **dropped** | — | confirmed (Kevin, 2026-09-11) — it's a search box, not a monitor; use `/baton:kb-search` |
| `maestro.py` (239 loc) | `/maestro/{status,jobs,budget}`, `/partials/{status,compose}`, `POST /maestro/jobs/{id}/{hold,release}`, `POST /maestro/transcribe` | **ported — read side at M5; hold/release conditional at M7** | M5 / M7 | Kevin: keep hold/release, drop voice. Read side (`/api/maestro`: job/assignment board, held vs released, budget) is plain observation and is unconditionally in at M5. `POST /transcribe` + `maestro-voice.js` **dropped** (§16). The two hold/release POSTs are writes and collide with D13 — scoped for M7, gated on §15.1. |
| `mydashboard.py` | `/mydashboard/*` | **dropped** | — | reads `~/Dev/MyDashboard`; outside Baton's scope |
| `api.py` | `/api/stats` | `/api/cockpit` | M4 | |

### 10.2 Readers

| legacy reader | loc | HUD equivalent | M |
|---|---|---|---|
| `journal.py` | 149 | **ported** into `adapters/journal.py` (parse rules reused verbatim) | M3 |
| `runs.py`, `jobs.py`, `ensembles.py` | 133/156/205 | `run_state` / `job_phase` / `dispatch` events + `/api/{runs,jobs}` | M3–M5 |
| `home_board.py`, `command_hero.py`, `display_goal.py` | 315/33/34 | `sessions` projection + board header | M4 |
| `cockpit_grid.py` | 300 | `/api/board` | M4 |
| `pane_truth.py` | 153 | superseded — the HUD gets `notification` first-hand from the hook | M4 |
| `stats.py` | 76 | `/api/cockpit` + `/api/machines` | M4 |
| `machines.py` | 266 | `/api/machines` (live) + `fleet.yaml` overlay | M4 |
| `gauges.py`, `claude_quota.py` | 431/141 | `/api/gauges`; `governor` events; pwsh probe still the writer | M5 |
| `project_economics.py` | 206 | `tokens`/`dispatch` roll-ups by `project`; `api-rates.json` moves to `hud/data/` | M5 |
| `projects.py` | 308 | `/api/projects` | M5 |
| `dark_factory.py` | 113 | `/api/board?source=baton-journal` | M5 |
| `maestro_jobs.py` | 327 | `/api/maestro` — job store at `$BATON_HOME/maestro/jobs/<id>.json` + `events.jsonl`; the `events.jsonl` becomes a tailer source feeding `run_state` | M5 |
| `agent_observability.py` | 513 | `/api/agents` from `agent_alive` + subagent events — event-native, not a re-derivation | M6 |
| `factory_health.py` | 76 | `/api/alerts` | M6 |
| `mydashboard_intel.py` | 151 | **dropped** | — |
| `transcribe.py` | 100 | **dropped** (STT out of scope) | — |
| `models/{events,runs}.py` | — | superseded by the envelope + `derive.py` types | M3 |

### 10.3 Assets

| legacy | disposition |
|---|---|
| `static/vendor/{htmx,chart.umd}.min.js` | **dropped.** HUD is dependency-free; sparklines are hand-drawn SVG. |
| `static/{app,cockpit,theme,command-palette,maestro-voice}.js` | dropped; behaviour lives in `hud.js` where it survives at all |
| `templates/**` (Jinja + partials) | dropped |
| `data/api-rates.json` | **moved** to `hud/data/api-rates.json` — the only data file |
| `Design from Google stitch/` | **moved** to `docs/design/baton-flight-deck/`; `DESIGN.md` becomes the `obsidian` theme spec. Note the three `.zip` + `.png` assets are design exports — keep them out of any public push per `publishing-guard.md`. |
| `dashboard/tests/**` (33 files) | dropped with the code; their *assertions about domain behaviour* are the seed for the parity gates (§12.4) |

---

## 11. Migration and cutover

### 11.1 The port collision

Both bind 8765 (`dashboard/main.py:166` hardcodes it; `hud/__main__.py` defaults to it). Resolution:

- **HUD keeps 8765.** It is what `hook_emit.py`, all five front-ends, the README and Kevin's muscle memory already point at, and it is the surviving service.
- **`dashboard/` moves to 8766** for the parallel period — a one-line change to read `BATON_DASHBOARD_PORT` (default 8766) in `dashboard/main.py`. Rejected alternative: HUD on 8766 until cutover, which would mean re-pointing every emitter twice.

### 11.2 Parallel running

Both run during M1–M6. `dashboard/` is untouched except for the port line — no new features, no bug fixes. Each milestone's exit criteria name the legacy routes it retires; when a route's parity gate is green, that legacy page is dead weight.

### 11.3 Retire checklist (M7)

1. Every row in §10 is ported with a green gate, or explicitly dropped with Kevin's sign-off. KB router and `mydashboard` are resolved (both dropped); Maestro hold/release (§15) is the only row still open, tracked to M7.
2. Two weeks of parallel running with no legacy-only route needed — backed by the M4 access log (D16), not judgment alone.
3. `hud/data/api-rates.json` in place and `project_economics` parity green.
4. `dashboard/Design from Google stitch/` → `docs/design/baton-flight-deck/`.
5. `git rm -r dashboard/` in one commit. Delete `dashboard/requirements.txt`.
6. Update `README.md`, `docs/COMMANDS.md`, `docs/agent-handoffs.md`, `AGENTS.md`/`GEMINI.md`/`GROK.md`, and any `pwsh` script that launches the dashboard.
7. Hooks move into `hooks/hooks.json` with the opt-in guard (§8.7).
8. `baton hud` documented as the only dashboard entry point.
9. **2.x release gate:** plugin version bumped to 2.0.0 in `.claude-plugin/plugin.json`; a fresh install with no `hud-enabled` file emits nothing (§8.7 test green); the README documents standing the HUD up and, explicitly, that it records prompt text and command lines locally.

### 11.4 Data migration

**None.** `dashboard/` owns no database. Its readers read `$BATON_HOME`, which the journal tailer also reads — and the M3 backfill (`--since 7d`) populates the HUD with recent history at adapter start. The only file that moves is `api-rates.json`.

---

## 12. Testing strategy

### 12.1 Unit (`hud/tests/`, pytest — extends the existing 44)

- **schema**: every new kind normalizes correctly; unknown kind still falls back and is never dropped; unknown envelope fields tolerated; every new payload field clamped; non-scalar dropped not stored.
- **store/migrations**: a v1 DB fixture migrates forward cleanly and idempotently; `event_uid` dedup; `sessions` projection updates in the insert transaction; retention math (roll-up totals equal the deleted rows' totals — the invariant that makes pruning safe).
- **derive**: status rules as a table-driven matrix (one row per rule, including precedence between `needs_you` and `failed`).
- **adapters**: every journal line type → envelope, including malformed lines, torn last lines, `job:`/`phase:`/`host:`/`tier:`/`tok:` tag peeling, and the unknown-trailing-tag fail-closed case.
- **auth**: scope enforcement matrix — ingest token cannot read; wrong `source` ⇒ 403; wrong `machine` ⇒ 403; hashed comparison is constant-time.

### 12.2 Integration

- Multi-source ingest: all four families into one DB; assert board/cockpit/machines are correct and machine-scoped filters partition cleanly.
- SSE: `Last-Event-ID` resume across a simulated disconnect loses nothing; named topics deliver only what was subscribed; slow-client eviction still holds.
- Forwarder: spool-and-drain across a 60 s simulated collector outage — zero loss, zero duplicates; spool cap drops oldest and counts.
- Restart: kill -9 the collector mid-stream; WAL recovers; no partial rows; browsers resume.

### 12.3 Live black-box probe

Keep the pattern that found the real bugs. `hud/tests/probe_live.py` runs a real uvicorn (not `TestClient` — several findings only reproduced under uvicorn) and asserts the security matrix: traversal set (the twelve encodings from the review), NUL-in-segment ⇒ 404, non-JSON `Content-Type` ⇒ 415, cross-Origin write ⇒ 403, spoofed `Host` ⇒ 400, oversized body ⇒ 413, forged `source`/`machine` ⇒ 403, rate limit ⇒ 429, `/openapi.json` ⇒ 404. Runs at each milestone exit gate, not in the default unit run.

### 12.4 Parity gates — the thing that justifies the delete

`hud/tests/test_parity.py`. A shared fixture `$BATON_HOME` (journal, jobs, runs, sessions, systems) is fed to **both** the legacy reader and the HUD adapter+query. Assert the same key facts — counts, ids, statuses, cost totals — not the same rendering.

One gate per §10 row that names a HUD equivalent and a milestone. Rows marked **deferred** or **dropped** have no gate — they have a sign-off in §15 instead. A milestone does not exit until its gates are green. This is what makes "retire `dashboard/`" a defensible claim rather than an assertion.

### 12.5 Performance

Synthetic 50k-event DB: `/api/board` p95 < 150 ms, `/api/cockpit?window=60` p95 < 100 ms, sustained ingest ≥ 500 ev/s with 5 SSE subscribers attached and no heartbeat gap > 20 s.

---

## 13. Milestones

Each milestone is independently shippable and leaves the tree working.

### M1 — The HUD becomes a service
Merge `hud-prototype-grok` to `master`. launchd unit on droid. `baton hud {serve,status,install-service,rebuild}`. Migrations framework + `recv_ts`/`event_uid` columns. Retention pruner + nightly backup. `Last-Event-ID` resume. Extended `/healthz`. **Default theme flips `dark` → `sapphire`** (§9.4) — three small edits, no new machinery.
**Exit:** survives a reboot unattended; `/healthz` green; a live stream loses zero events across a `kill -9` + restart; DB stops growing without bound; a browser with empty `localStorage` lands on `sapphire`; existing 44 tests plus migration/retention/resume/theme-default tests pass.

### M2 — Multi-machine ingest (macOS, Linux, and Windows satellites)
`hud/auth.py` token store with scopes/source/machine binding. `POST /ingest/batch`. `hud/forwarder.py` + spool + drain. Satellite service units for launchd, systemd, **and Windows Task Scheduler** (§8.5, D15), with the platform-detecting `install-service`. Machine sampler gets its Linux and Windows branches. TrustedHost extended to the tailnet name (`tailscale serve`, §8.4). Skew detection. Bare `/api/machines`.
**Exit:** a Claude Code session on a second box — macOS, Linux, **or Windows** — appears in the HUD within 2 s; the collector down for 60 s loses nothing on recovery; an `ingest`-scoped token gets 401 on `/events` and 403 on a forged `source`/`machine`; `install-service` on Linux refuses to pretend it worked when lingering is disabled; the Windows forwarder task survives a logoff/logon cycle.

### M3 — Journal / fleet adapter
`hud/adapters/journal.py` + `runs.py`: tailer, cursor, 7-day backfill. Kinds `dispatch`, `tokens`, `gate`, `governor`, `job_phase`, `run_state`, `note`, `lesson`. `project`/`job_id`/`run_id` fields.
**Exit:** a `/baton:codex` dispatch appears in the HUD; `/events?source=baton-journal` count matches the fixture journal's parsable line count exactly; parity gate vs `readers/journal.py`.

### M4 — Derived state; board + cockpit + machines graduate
`sessions` projection, `derive.py`, `/api/{board,cockpit,machines,sessions}`, named SSE topics, `hud/adapters/machine.py`, `machines.html`. `board`/`cockpit` rewired off client-side derivation. Also lands a one-line access log on `dashboard/` routes (D16) — the data behind the M7 cutover call.
**Exit:** parity gates vs `home_board`, `cockpit_grid`, `pane_truth`, `stats`, `machines`, `api/stats`. Two browsers on different machines show an identical board. Perf targets in §12.5 met. `dashboard/` access log is writing and readable.

### M5 — Economics, projects, jobs, runs, Maestro (read)
`/api/{projects,gauges,jobs,runs,maestro}`, `rollups_hourly`, `api-rates.json` moved. Dark-factory panel. Maestro job/assignment board — held vs released, budget, assignments — as **observation only**.
**Exit:** parity gates vs `gauges`, `claude_quota`, `project_economics`, `projects`, `ensembles`, `jobs`, `runs`, `dark_factory`, `maestro_jobs`. A 5 h burn number matches the legacy gauges page within rounding. A job held via the CLI shows as held in the HUD within one sample.

### M6 — Harness adapters, agents, design pass
Codex / grok / cursor-agent / opencode adapters. `/api/agents`, `/api/alerts`. Shared `hud.js`. `obsidian` theme (default stays `sapphire`). `v5` gallery snapshot.
**Exit:** a Herdr-driven grok run appears as its own lane with correct status transitions; parity gates vs `agent_observability`, `factory_health`; five layouts still render with zero external network requests (asserted by the probe).

### M7 — Ship in Baton 2.x + retire `dashboard/`
Hooks into `hooks/hooks.json` behind the opt-in guard. Port cutover. `dashboard/` deleted, design docs moved, all docs updated. Plugin version → 2.0.0, release notes, README section on standing the HUD up and what it records. **Conditional:** Maestro hold/release, only if M5's read-side usage flips the default in §15.1 — the planning default is leave-to-CLI, so M7 ships with no write endpoint beyond `POST /config` unless that changes.
**Exit:** `dashboard/` is gone; no §10 row unaccounted for; the retire checklist (§11.3) is fully ticked including the 2.x release gate; a fresh Baton plugin install with `hud-enabled` absent emits nothing and costs < 20 ms per hook.

---

## 14. Decisions made

**D1 — Replace `dashboard/` rather than extend it.**
*Alternatives:* port the 25 readers into `hud/` wholesale; strangler-pattern inside `dashboard/`.
*Rationale:* the readers' value is domain knowledge, not code. Their architecture — re-parse files per request, htmx poll, pwsh shell-outs — is what we are trying to leave. Reimplementing them as adapters against an event store is less code (5,312 → adapters) and gives multi-machine for free.

**D2 — Hybrid truth: events for what happened, direct reads for how things are configured.**
*Alternatives:* everything through the event log; keep reading files for everything.
*Rationale:* forcing `fleet.yaml` and job manifests through an append-only log is ceremony with no payoff, and it would make the HUD wrong whenever a config file is edited by hand. §5.4 draws the line.

**D3 — Emitters always POST to loopback; a per-box forwarder owns the network.**
*Alternatives:* hooks POST directly to the collector.
*Rationale:* preserves `hook_emit.py`'s 0.25 s fail-open budget (it cannot retry), keeps security finding LOW-4's protection (a compromised session cannot redirect telemetry off-box), and gives at-least-once delivery with one spool implementation instead of one per emitter.

**D4 — Extend `session_id` by convention rather than adding `stream_id`.**
*Alternatives:* a new `stream_id` field with `session_id` deprecated.
*Rationale:* keeps `hud.event/v1` shape-frozen, keeps `seq` partitioning unchanged, and keeps all five front-ends and four frozen galleries working without edits. The cost is a convention table (§4.2), which is cheaper than a schema break.

**D5 — Additive-optional evolution stays `hud.event/v1`; `/v2` only on a break, and then dual-accept.**
*Alternatives:* bump the version on every addition.
*Rationale:* satellite boxes will run stale emitters. A version bump per addition guarantees a black-hole the first time a box is behind. Consumers ignoring unknown fields is the cheap, standard answer.

**D6 — Scoped, hashed tokens bound to source + machine.**
*Alternatives:* one shared secret (today's model); mTLS; OAuth.
*Rationale:* one secret means a satellite's ingest credential reads every prompt on droid — unacceptable once the token leaves the box. mTLS/OAuth are disproportionate for a two-to-three box home fleet. `?t=` is upgraded to an HttpOnly cookie so the secret stops living in URLs.

**D7 — HUD keeps 8765; `dashboard/` moves to 8766 during cutover.**
*Alternatives:* the reverse.
*Rationale:* every emitter, front-end, README line and the operator's habit already point at 8765, and the HUD is the survivor. Moving the doomed service costs one line.

**D8 — Derived state is a server-side projection updated in the insert transaction.**
*Alternatives:* compute per request; keep computing client-side.
*Rationale:* the board must be identical for every viewer and correct on a cold page load, not only within the SSE replay window; and non-browser consumers need it. Per-request computation was the fallback — rejected because the board is the highest-traffic query and the projection makes it an index seek.

**D9 — 30-day raw retention with indefinite hourly roll-ups.**
*Alternatives:* keep everything; keep 7 days.
*Rationale:* raw rows carry prompt text and command lines — the thing that made HIGH-1 serious — so they should expire. Cost and token history is the data with long-term value and it survives at hourly granularity for a rounding error of space.

**D10 — `cards` folded into `board`; `deck`/`minimal` kept as alternates.**
*Alternatives:* graduate all five.
*Rationale:* `cards` and `board` render the same data; maintaining both doubles the surface with no new information. `deck` earns its keep as an ambient display and `minimal` as the accessible / no-JS fallback.

**D11 — One shared same-origin `hud.js`; still no libraries, no CDN.**
*Alternatives:* keep every front-end fully self-contained.
*Rationale:* MED-2 had to be fixed in three files independently. At build-out size that pattern produces divergent bugs. One module preserves the real invariant (zero external requests) while removing the 5× duplication. Frozen `versions/` keeps its inline copies.

**D12 — Plugin-installed telemetry is opt-in via `$BATON_HOME/hud-enabled`.**
*Alternatives:* on by default once the plugin ships the hooks; never ship the hooks in the plugin.
*Rationale:* Baton is a public plugin; silently starting to record other people's prompts is not acceptable. A single `os.path.exists` before any import makes the disabled path nearly free, and it is the seam a multi-tenant mode would extend.

**D13 — The HUD is observe-only; fleet control stays in the CLI (and, later, a bot).**
*Alternatives:* build the `POST /control/{action}` allowlist (ollama / LM Studio) + `runs/{id}/answer` write-back at M7, as an earlier draft did; leave the door fully shut and never revisit.
*Rationale:* Kevin (2026-09-10): "I want to write back… but I don't really know if that is wise. It may be better to just leave it to the CLI or other interface and this is just a control plane to see what is going on." Write-back is the single largest blast-radius increase in the plan — it turns the browser's read cookie into a fleet-actuation credential and forces an `admin` scope with teeth. Deferring it keeps the token model small (`admin` = `POST /config` only), keeps the CSRF surface trivial, and loses no capability: `/baton:models`, `/baton:fleet` and the run CLI already cover every dropped action. If a dedicated control layer (a Hermes / "claw" bot) materialises, it owns write-back — not the HUD. The one live edge is Maestro hold/release (§15.1).

**D14 — The HUD ships as a feature of Baton 2.x, not a Kevin-local tool.**
*Alternatives:* keep it local until a real multi-tenant story exists; ship it in a 1.x point release.
*Rationale:* Kevin (2026-09-10): "let's make the HUD a 2.x release, we may be close to that." Retiring `dashboard/` and turning telemetry on for every Baton user is a breaking, headline change — that is a major version. It also promotes D12's opt-in `$BATON_HOME/hud-enabled` guard from precaution to release-blocker: an upgrade must never silently start recording a stranger's prompts. Each install stays single-operator (§1.3); multi-tenant remains designed-for, not built.

**D15 — Windows is a first-class M2 satellite via Task Scheduler, not deferred.**
*Alternatives:* defer Windows past M2 (rev 2's position, when Kevin's candidate boxes were assumed macOS/Linux); install Windows as a real Service (needs an installer/admin rights) instead of a Scheduled Task.
*Rationale:* Kevin confirmed (2026-09-11) one of his candidate satellite boxes is Windows, so "defer" would block M2 on his actual hardware. A Task Scheduler task with `AtLogon` + restart-on-failure matches the zero-install, no-admin-rights spirit of the launchd/systemd units without the packaging overhead a real Windows Service demands. The Windows *collector* role is out of scope for M2 (forwarder only) — that is untested surface, not a design objection, and can be picked up later without a redesign.

**D16 — Add a one-line `dashboard/` access log at M4 so the M7 cutover call is data-backed.**
*Alternatives:* keep the cutover gate as pure judgment (rev 2's position); instrument the HUD side instead (meaningless — the question is whether `dashboard/` still has traffic).
*Rationale:* Kevin picked the spec's own recommendation: "two weeks parallel, no telemetry" was flagged as an honest gap in rev 2, not a preference. A single access-log line costs nothing and turns "does anyone still hit `dashboard/`" from a guess into a fact the retire checklist (§11.3) can point to.

---

## 15. Open questions for Kevin

Resolved since rev 2, now folded into the body: default theme → **`sapphire`** (§9.4); write-back → **cut, observe-only** (D13); ship target → **Baton 2.x** (D14); Maestro read side → **kept, voice dropped** (§10.1); satellite OS → **macOS, Linux, and Windows all in scope for M2** (§8.5, D15); tailnet TLS → **`tailscale serve`, confirmed** (§8.4); KB router → **dropped** (§10.1); `mydashboard` → **dropped, confirmed** (§10.1); cutover gate → **a one-line `dashboard/` access log lands at M4** so the call is data-backed (§11.3, D16); retention → **30 days raw / hourly roll-ups forever, confirmed** (D9).

One item stays genuinely open:

1. **Maestro hold/release.** The read side (job/assignment board, budget) is in at M5 unconditionally, not gated on this. The two write endpoints (`POST /maestro/jobs/{id}/{hold,release}`) collide with observe-only (D13) — building them at M7 would be the sole write exception in the whole surface. Kevin's answer (2026-09-11): "probably leave to the CLI" but wants to keep the option open rather than close it now. **Planning default: leave to the CLI** — M7 (§13) stays conditional on this exactly as written, and the real call gets made once M5's read-side board has seen actual use: if hold/release turns out to be something Kevin reaches for from the dashboard often, build it at M7; otherwise M7 ships with no write endpoint beyond `POST /config`.

Not blocking anything, but still outstanding: name the first Windows/macOS/Linux satellite box(es) once chosen (§8.5) — M2 can start before this is named; it only needs a concrete target by M2's exit criteria.

---

## 16. Explicitly out of scope

- **Live pane tails / terminal scrollback capture** (legacy `cockpit_grid` did a form of this). It is transcript capture by another name; it conflicts with the payload-clamp rule and it is the single fastest way to leak a secret into the store.
- **STT / voice** (`readers/transcribe.py`, `maestro-voice.js`). Not a monitoring concern.
- **Writing back to agents / actuating the fleet.** The HUD is observe-only (D13). The sole exception still under review is Maestro job hold/release (§15.1). No prompt injection into a running session, no arbitrary command execution, ever — a real control layer is a future CLI / bot concern, not the HUD's.
- **WAN exposure**, port forwarding, self-signed certs, any auth provider.
- **Multi-tenant / hosted mode.** The HUD ships in 2.x (D14) but every install is single-operator. Multi-tenant is designed-for (D12), not built.
- **Editing `hud/versions/vN/`.** Frozen history.
- **Metrics export** (Prometheus/OTLP). `/healthz` carries the counters; a real exporter is a later question.
- **Alerting** — push notifications, email, Slack on `needs_you`. Tempting, deliberately deferred past M7.
- **A task-by-task implementation breakdown.** This document defines *what* and *why*; the per-milestone plans define *how*.
