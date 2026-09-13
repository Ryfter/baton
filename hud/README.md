# HUD

Baton's live agent-activity dashboard. Runs as a service (`baton hud install-service`
on macOS; Linux/Windows land in M2). Separate from the legacy `dashboard/` (do not
start both — see `docs/superpowers/specs/2026-09-10-hud-dashboard-buildout-design.md`
§11.1 for the port-collision resolution). Transport is SSE with resume-on-reconnect.
Storage is SQLite with hourly retention rollups (`hud/hud.db`, gitignored).

**Retention (M1, spec §5.3 — fully implemented):** the pruner enforces 30-day
time-based retention (`HUD_RETENTION_DAYS`, default 30) AND a hard row-count
cap (`HUD_MAX_ROWS`, default 2,000,000) — whichever binds first. Both prune
passes roll a row's contribution into `rollups_hourly` before deleting it, so
cost/token history survives at hourly granularity even after the raw event
is gone. The cutoff and rollup bucket are keyed on `recv_ts` (the
server-assigned collector clock), not the emitter-supplied `ts`, so a bad
emitter clock can't skew what gets pruned or when (falls back to `ts` only
for pre-migration rows that predate `recv_ts`). Space is actually reclaimed
as rows are deleted: the DB runs with `PRAGMA auto_vacuum=INCREMENTAL`
(converted in place via migrations.py for any DB that predates this), and
each prune batch runs `PRAGMA incremental_vacuum` afterward. A full `VACUUM`
also runs roughly weekly (7+ days since the last one). Nightly backups
(`backup_now`, keep 7) seed their "last backup" timer from the newest
existing backup file's mtime at startup, so a crash-looping process doesn't
mistake a restart for "no backup has ever run" and rotate away real history;
the weekly `VACUUM` seeds the same way from a small marker file touched after
each run, for the same reason (a launchd crash-loop must not re-trigger a
full-file rewrite on every ~10s restart). Both `backup_now` and `vacuum_now`
hold the store's write lock for their full duration (blocking ingest/read
traffic meanwhile) -- acceptable at current scale, worth revisiting if the DB
grows large.

## Run

```
cd /Users/kev/Dev/Baton              # or this build worktree
pip install -r hud/requirements.txt
python -m hud                         # binds 127.0.0.1:8765
```

Default bind is **loopback only** (`127.0.0.1:8765`). That is the safe default.

### LAN access (view from another PC)

Kevin views from another PC at **http://droid:8765/**. That is opt-in — bind all
interfaces **and** set a shared token:

```
HUD_HOST=0.0.0.0 HUD_TOKEN=pick-a-long-secret python -m hud
# equivalent: python -m hud --host 0.0.0.0
```

When bound off-loopback, `HUD_TOKEN` is **required**. Without it the process logs a
loud warning and every request returns 401.

Pass the token:

- Browser: open `http://droid:8765/?t=pick-a-long-secret`. Front-ends keep `?t=`
  on the SSE URL (`/stream`) and on chooser links.
- `hook_emit.py` / `fake_traffic.py`: send `X-HUD-Token` from the same
  `HUD_TOKEN` env var. Export it in the environment Claude Code inherits so
  hooks can ingest.

CLI: `python -m hud --host 0.0.0.0 --port 8765`
Env: `HUD_HOST` (default `127.0.0.1`), `HUD_PORT` (default `8765`), `HUD_TOKEN`
(required when `HUD_HOST` is not loopback). Extra `Host` names (beyond
`droid` / `droid.local` / localhost) go in `HUD_ALLOWED_HOSTS` (comma-separated).

Demo traffic without a live Claude session:

```
python hud/fake_traffic.py --fast
```

## Port collision

Port 8765 is also the legacy `dashboard/`'s port. They cannot both run. This
prototype takes 8765; do not start the old dashboard alongside it.

## Running as a service (macOS)

```
baton hud install-service          # writes ~/Library/LaunchAgents/dev.baton.hud.plist, loads it
baton hud status                   # human-readable /healthz summary
baton hud rebuild                  # WAL checkpoint + integrity check + row count
launchctl unload ~/Library/LaunchAgents/dev.baton.hud.plist   # stop
```

`install-service` on Linux/Windows currently refuses with a clear message — systemd and
Task Scheduler land in M2 (see `docs/superpowers/specs/2026-09-10-hud-dashboard-buildout-design.md` §8.5, D15).

## Hooks

`settings-hooks.snippet.json` (repo root) is the `~/.claude/settings.json` `hooks`
block. Each of the 8 Claude Code events runs:

```
python3 /Users/kev/Dev/Baton/hud/hook_emit.py
```

When testing from a **worktree**, point that path at the worktree copy instead,
e.g. `/Users/kev/Dev/Baton/.worktrees/hud-prototype-grok/hud/hook_emit.py`.

`hook_emit.py` is fail-open: 0.25s timeout, never writes stdout, always exits 0.

Global install means every Claude Code session on droid emits — intended.

## Front-ends

Chooser at `/`. Direct: `/v/deck`, `/v/board`, `/v/cockpit`, `/v/minimal`.
POST `/config` with `{"default_frontend":"deck"}` (or `null`) sets the default.
Each page is one self-contained HTML file (inline CSS/JS, no CDN, no libraries).
They connect with `new EventSource('/stream?replay=200')` (and `&t=` when a
token is present in the page URL).
