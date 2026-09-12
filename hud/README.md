# HUD

Baton's live agent-activity dashboard. Runs as a service (`baton hud install-service`
on macOS; Linux/Windows land in M2). Separate from the legacy `dashboard/` (do not
start both — see `docs/superpowers/specs/2026-09-10-hud-dashboard-buildout-design.md`
§11.1 for the port-collision resolution). Transport is SSE with resume-on-reconnect.
Storage is SQLite with hourly retention rollups (`hud/hud.db`, gitignored).

**Retention scope (M1):** the pruner enforces **30-day time-based retention only**.
A hard row-count cap (`HUD_MAX_ROWS`) and periodic space reclamation
(`PRAGMA incremental_vacuum` / a weekly `VACUUM`, spec §5.3) are **deferred to a
follow-up** — not implemented in this milestone. Time-based retention bounds
steady-state growth, but there is currently no hard cap on row count and no
space reclamation once rows are pruned.

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
