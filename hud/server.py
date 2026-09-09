"""FastAPI HUD server: ingest, SSE stream, history, chooser, config."""
from __future__ import annotations

import asyncio
import json
import socket
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response, StreamingResponse

from hud import config as hud_config
from hud import store
from hud.schema import SCHEMA_ID, validate_envelope

FRONTENDS_DIR = Path(__file__).resolve().parent / "frontends"
THEMES_DIR = FRONTENDS_DIR / "themes"
THEME_NAMES = ("dark", "sapphire", "lapis-velvet", "sandstone")
STARTED_AT = time.time()

_subscribers: set[asyncio.Queue] = set()
_QUEUE_MAX = 256

CHOOSER_DESCRIPTIONS = {
    "deck": "Flight-deck swim-lanes — one horizontal strip per session, colour-coded event chips scrolling right.",
    "board": "Mission board with three bays: Running, Needs You, Stopped. Cards slide between columns on state change.",
    "cockpit": "Instrument panel: four stat tiles, hand-drawn throughput sparkline, compact reverse-chron feed.",
    "cards": "Session cards in a vertical stack — deck chip language, status pill, most-recent session on top.",
    "minimal": "Accessible structured table — tabular time, session, kind, detail. Errors in red only.",
}


def _utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _frontend_names() -> list[str]:
    if not FRONTENDS_DIR.is_dir():
        return []
    names = sorted(p.stem for p in FRONTENDS_DIR.glob("*.html") if p.is_file())
    return names


def _frontend_path(name: str) -> Optional[Path]:
    if not name or "/" in name or "\\" in name or ".." in name:
        return None
    path = (FRONTENDS_DIR / ("%s.html" % name)).resolve()
    try:
        path.relative_to(FRONTENDS_DIR.resolve())
    except ValueError:
        return None
    if path.is_file():
        return path
    return None


def _theme_path(name: str) -> Optional[Path]:
    if not name or "/" in name or "\\" in name or ".." in name:
        return None
    if name.endswith(".css"):
        name = name[:-4]
    if name not in THEME_NAMES:
        return None
    path = (THEMES_DIR / ("%s.css" % name)).resolve()
    try:
        path.relative_to(THEMES_DIR.resolve())
    except ValueError:
        return None
    if path.is_file():
        return path
    return None


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
    return {
        "schema": SCHEMA_ID,
        "ts": body.get("ts") or _utcnow(),
        "session_id": str(session_id),
        "source": body.get("source") or "claude-hook",
        "kind": str(kind),
        "agent": agent,
        "machine": body.get("machine") or socket.gethostname(),
        "payload": payload,
    }


def _sse(event: dict[str, Any]) -> str:
    return "event: hud\ndata: %s\n\n" % json.dumps(event, default=str, ensure_ascii=False)


async def _broadcast(event: dict[str, Any]) -> None:
    dead: list[asyncio.Queue] = []
    for q in list(_subscribers):
        try:
            q.put_nowait(event)
        except asyncio.QueueFull:
            dead.append(q)
        except Exception:
            dead.append(q)
    for q in dead:
        _subscribers.discard(q)
        try:
            q.put_nowait(None)
        except Exception:
            pass


def _chooser_html(names: list[str]) -> str:
    cards = []
    for name in names:
        desc = CHOOSER_DESCRIPTIONS.get(name, "HUD front-end variant.")
        cards.append(
            """
            <article class="card">
              <h2>%s</h2>
              <p>%s</p>
              <div class="row">
                <a href="/v/%s">just view once</a>
                <button type="button" data-name="%s">Set as default</button>
              </div>
            </article>
            """
            % (name, desc, name, name)
        )
    return """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>HUD — choose a view</title>
  <link rel="stylesheet" id="hud-theme" href="/themes/dark.css">
  <style>
    *, *::before, *::after { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: var(--hud-font-sans, ui-sans-serif, system-ui, sans-serif);
      background: var(--hud-bg, #0b0e14);
      color: var(--hud-text, #c9d1d9);
      min-height: 100vh;
    }
    header {
      padding: 28px 32px 16px;
      border-bottom: 1px solid var(--hud-border, #1c2330);
      background: var(--hud-header-bg, rgba(11,14,20,.92));
    }
    .top-row {
      display: flex; align-items: flex-end; justify-content: space-between;
      gap: 16px; flex-wrap: wrap;
    }
    h1 {
      margin: 0 0 6px; font-size: 11px; letter-spacing: .22em;
      text-transform: uppercase; color: var(--hud-text-strong, #e6edf3);
    }
    .sub { color: var(--hud-text-muted, #8b949e); font-size: 14px; margin: 0; max-width: 520px; line-height: 1.5; }
    .theme-bar {
      display: flex; align-items: center; gap: 10px;
      font-size: 12px; color: var(--hud-text-muted, #8b949e);
    }
    .theme-bar select {
      background: var(--hud-surface, #11161f);
      color: var(--hud-text, #c9d1d9);
      border: 1px solid var(--hud-border, #1c2330);
      border-radius: 4px; font: inherit; font-size: 12px;
      padding: 6px 10px; cursor: pointer;
    }
    main {
      display: flex; flex-direction: column; gap: 14px;
      padding: 24px 32px 48px; max-width: 920px;
    }
    .card {
      background: var(--hud-surface, #11161f);
      border: 1px solid var(--hud-border, #1c2330);
      border-left: 3px solid var(--hud-accent-dim, #3d5a80);
      border-radius: 8px;
      padding: 18px 20px 16px;
      transition: border-left-color .2s;
    }
    .card:hover { border-left-color: var(--hud-accent, #8ec8ff); }
    h2 {
      margin: 0 0 6px; font-size: 16px; font-family: var(--hud-font-mono, monospace);
      color: var(--hud-link, #8ec8ff); letter-spacing: .04em;
    }
    p {
      margin: 0 0 14px; color: var(--hud-text-muted, #8b949e);
      font-size: 13px; line-height: 1.55;
    }
    .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    a {
      color: var(--hud-link, #8ec8ff); text-decoration: none; font-size: 13px;
      border: 1px solid var(--hud-border, #1c2330); border-radius: 4px;
      padding: 7px 12px;
    }
    a:hover { border-color: var(--hud-accent, #8ec8ff); }
    button {
      background: var(--hud-text-strong, #e6edf3);
      color: var(--hud-bg, #0b0e14);
      border: 0; border-radius: 4px;
      padding: 7px 12px; cursor: pointer; font-weight: 600; font-size: 13px;
    }
    button:hover { opacity: .92; }
  </style>
</head>
<body>
  <header>
    <div class="top-row">
      <div>
        <h1>Mission Control HUD</h1>
        <p class="sub">Pick a layout for live agent telemetry. Set as default remembers your choice on this machine.</p>
      </div>
      <div class="theme-bar">
        <label for="theme-pick">Theme</label>
        <select id="theme-pick" aria-label="Theme">
          <option value="dark">dark</option>
          <option value="sapphire">sapphire</option>
          <option value="lapis-velvet">lapis-velvet</option>
          <option value="sandstone">sandstone</option>
        </select>
      </div>
    </div>
  </header>
  <main>
    %s
  </main>
  <script>
    (function () {
      var pick = document.getElementById("theme-pick");
      var link = document.getElementById("hud-theme");
      var t = localStorage.getItem("hud-theme") || "dark";
      pick.value = t;
      link.href = "/themes/" + t + ".css";
      pick.addEventListener("change", function () {
        localStorage.setItem("hud-theme", pick.value);
        link.href = "/themes/" + pick.value + ".css";
      });
    })();
    document.querySelectorAll("button[data-name]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var name = btn.getAttribute("data-name");
        fetch("/config", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ default_frontend: name })
        }).then(function () { location.href = "/v/" + name; });
      });
    });
  </script>
</body>
</html>
""" % "\n".join(cards)


app = FastAPI(title="hud", docs_url=None, redoc_url=None)


@app.post("/ingest")
async def ingest(request: Request) -> dict[str, Any]:
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=422, detail="invalid json")
    if not isinstance(body, dict):
        raise HTTPException(status_code=422, detail="invalid body")
    try:
        event = _fill(body)
        event_id = store.insert_event(event)
        event["id"] = event_id
        validate_envelope(event)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=422, detail=str(exc) or "invalid event") from exc
    await _broadcast(event)
    return {"ok": True, "id": event_id, "seq": event["seq"]}


@app.get("/stream")
async def stream(replay: int = Query(default=200)) -> StreamingResponse:
    n = replay
    try:
        n = int(n)
    except (TypeError, ValueError):
        n = 200
    n = max(0, min(n, 2000))

    async def gen():
        q: asyncio.Queue = asyncio.Queue(maxsize=_QUEUE_MAX)
        _subscribers.add(q)
        max_id = 0
        try:
            replayed = await asyncio.to_thread(store.replay_events, n)
            if not replayed:
                yield ": stream-open\n\n"
            for ev in replayed:
                eid = int(ev.get("id") or 0)
                if eid > max_id:
                    max_id = eid
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
                if eid and eid <= max_id:
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


@app.get("/events")
async def events(
    since: Optional[int] = None,
    limit: int = 2000,
    session: Optional[str] = None,
    kind: Optional[str] = None,
) -> list[dict[str, Any]]:
    try:
        cap = 2000 if limit is None else int(limit)
    except (TypeError, ValueError):
        cap = 2000
    cap = max(0, min(cap, 2000))
    return store.query_events(since=since, limit=cap, session=session, kind=kind)


@app.get("/")
async def root() -> Any:
    cfg = hud_config.read_config()
    name = cfg.get("default_frontend")
    if name:
        raw = str(name)
        if raw.endswith(".html"):
            raw = raw[:-5]
        path = _frontend_path(raw)
        if path is not None:
            return RedirectResponse(url="/v/%s" % path.stem, status_code=302)
    names = _frontend_names()
    return HTMLResponse(_chooser_html(names))


@app.get("/v/{name}")
async def view(name: str) -> Any:
    path = _frontend_path(name)
    if path is None:
        raise HTTPException(status_code=404, detail="unknown front-end")
    return FileResponse(path, media_type="text/html; charset=utf-8")


@app.get("/themes/{name}.css")
async def theme_css(name: str) -> Any:
    path = _theme_path(name)
    if path is None:
        raise HTTPException(status_code=404, detail="unknown theme")
    return FileResponse(path, media_type="text/css; charset=utf-8")


@app.post("/config")
async def post_config(request: Request) -> dict[str, Any]:
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=422, detail="invalid json")
    if not isinstance(body, dict):
        raise HTTPException(status_code=422, detail="invalid body")
    if "default_frontend" not in body:
        raise HTTPException(status_code=422, detail="default_frontend required")
    val = body.get("default_frontend")
    if val is not None:
        val = str(val)
        if val.endswith(".html"):
            val = val[:-5]
        if val == "" or val.lower() == "null":
            val = None
        elif _frontend_path(val) is None:
            raise HTTPException(status_code=422, detail="unknown front-end")
    return hud_config.write_config(val)


@app.get("/favicon.ico", include_in_schema=False)
async def favicon() -> Response:
    return Response(status_code=204)


@app.get("/healthz")
async def healthz() -> dict[str, Any]:
    return {
        "ok": True,
        "events": store.count_events(),
        "uptime_s": int(time.time() - STARTED_AT),
    }
