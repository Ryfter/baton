# HUD prototype

Throwaway-or-keep live agent-activity HUD. Separate from the legacy `dashboard/`
(do not start both). Transport is SSE. Storage is SQLite (`hud/hud.db`, gitignored).

## Run

```
cd /Users/kev/Dev/Baton              # or this build worktree
pip install -r hud/requirements.txt
python -m hud                         # binds 0.0.0.0:8765
```

Kevin views from another PC. The server binds **all interfaces** on port **8765**.
Open **http://droid:8765/** (not localhost).

CLI overrides: `python -m hud --host 0.0.0.0 --port 8765`
Env: `HUD_HOST` (default `0.0.0.0`), `HUD_PORT` (default `8765`).

Demo traffic without a live Claude session:

```
python hud/fake_traffic.py --fast
```

## Port collision

Port 8765 is also the legacy `dashboard/`'s port. They cannot both run. This
prototype takes 8765; do not start the old dashboard alongside it.

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
They connect with `new EventSource('/stream?replay=200')`.
