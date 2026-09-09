"""FastAPI HUD server: ingest, SSE stream, history, chooser, config."""
from __future__ import annotations

import asyncio
import json
import re
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
VERSIONS_DIR = Path(__file__).resolve().parent / "versions"
_VID_RE = re.compile(r"^v\d+$")
STARTED_AT = time.time()

_subscribers: set[asyncio.Queue] = set()
_QUEUE_MAX = 256

CHOOSER_DESCRIPTIONS = {
    "deck": "Dark monospace swim-lanes, one per session — the disler-flavored look.",
    "board": "Mission-control bays: Running / Needs You / Stopped, with status-striped cards.",
    "cockpit": "Stat tiles, a hand-drawn events/min sparkline, and a compact feed.",
    "cards": "Deck's chip language as a session card grid — same dark canvas, wrapping chips.",
    "minimal": "Accessible table, system font, colour only for errors.",
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


def _safe_seg(name: str) -> bool:
    return bool(name) and "/" not in name and "\\" not in name and ".." not in name


def _version_ids() -> list[str]:
    if not VERSIONS_DIR.is_dir():
        return []
    ids = [p.name for p in VERSIONS_DIR.iterdir() if p.is_dir() and _VID_RE.match(p.name)]
    return sorted(ids, key=lambda s: int(s[1:]))


def _version_index() -> list[dict[str, Any]]:
    idx = VERSIONS_DIR / "index.json"
    meta: dict[str, dict[str, Any]] = {}
    if idx.is_file():
        try:
            raw = json.loads(idx.read_text("utf-8"))
            for row in raw.get("versions", []):
                if isinstance(row, dict) and row.get("id"):
                    meta[str(row["id"])] = row
        except (json.JSONDecodeError, OSError):
            pass
    out = []
    for vid in _version_ids():
        row = dict(meta.get(vid, {}))
        row["id"] = vid
        row.setdefault("label", vid)
        row["layouts"] = sorted(p.stem for p in (VERSIONS_DIR / vid).glob("*.html"))
        out.append(row)
    return out


def _version_file(vid: str, name: str, sub: str = "") -> Optional[Path]:
    if not (_VID_RE.match(vid) and _safe_seg(name)):
        return None
    base = (VERSIONS_DIR / vid).resolve()
    rel = ("%s/%s.html" % (sub, name)) if sub else ("%s.html" % name)
    if sub and not _safe_seg(sub):
        return None
    path = (base / rel).resolve() if not sub else (base / sub / ("%s.html" % name)).resolve()
    try:
        path.relative_to(base)
    except ValueError:
        return None
    return path if path.is_file() else None


def _version_css(vid: str, name: str) -> Optional[Path]:
    if not (_VID_RE.match(vid) and _safe_seg(name)):
        return None
    base = (VERSIONS_DIR / vid / "themes").resolve()
    path = (base / ("%s.css" % name)).resolve()
    try:
        path.relative_to(base)
    except ValueError:
        return None
    return path if path.is_file() else None


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
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: ui-sans-serif, system-ui, sans-serif;
           background: #10141c; color: #e8edf5; }
    header { padding: 28px 32px 8px; }
    h1 { margin: 0 0 6px; font-size: 22px; letter-spacing: .04em; }
    .sub { color: #9aa6b8; font-size: 14px; }
    main { display: grid; gap: 16px; padding: 24px 32px 48px;
           grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); }
    .card { background: #1a2130; border: 1px solid #2a3548; border-radius: 12px;
            padding: 18px 18px 16px; }
    h2 { margin: 0 0 8px; font-size: 18px; text-transform: lowercase; }
    p { margin: 0 0 16px; color: #b7c2d3; font-size: 14px; line-height: 1.4; }
    .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    a { color: #8ec8ff; }
    button { background: #e8edf5; color: #10141c; border: 0; border-radius: 8px;
             padding: 8px 12px; cursor: pointer; font-weight: 600; }
    button:hover { background: #fff; }
  </style>
</head>
<body>
  <header>
    <h1>HUD</h1>
    <p class="sub">Pick a front-end. Set as default remembers it on this box.</p>
  </header>
  <main>
    %s
  </main>
  <script>
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


def _versions_index_html(rows: list[dict[str, Any]]) -> str:
    items = []
    for r in rows:
        links = " · ".join(
            '<a href="/%s/v/%s">%s</a>' % (r["id"], lay, lay) for lay in r["layouts"]
        )
        items.append(
            '<li><b>%s</b> <span class="d">%s</span><br><span class="n">%s</span>'
            '<br><a href="/%s/">chooser</a> — %s</li>'
            % (r.get("label", r["id"]), r.get("date", ""), r.get("note", ""), r["id"], links)
        )
    return (
        "<!doctype html><meta charset=utf-8><title>HUD — versions</title>"
        "<style>body{background:#0b0e14;color:#dbe4f0;font:14px/1.5 ui-sans-serif,system-ui;"
        "margin:0;padding:32px}h1{margin:0 0 4px}a{color:#6aa8ff}li{margin:0 0 20px;list-style:none}"
        "ul{padding:0;max-width:820px}.d{color:#6b7787}.n{color:#9aa7b6}</style>"
        "<h1>HUD versions</h1><p><a href=\"/\">→ latest</a></p><ul>%s</ul>"
        % "\n".join(items)
    )


@app.get("/versions")
async def versions() -> Any:
    return HTMLResponse(_versions_index_html(_version_index()))


@app.get("/{vid}")
async def version_chooser(vid: str) -> Any:
    if not _VID_RE.match(vid) or vid not in _version_ids():
        raise HTTPException(status_code=404, detail="unknown version")
    names = sorted(p.stem for p in (VERSIONS_DIR / vid).glob("*.html"))
    html = _chooser_html(names).replace('href="/v/', 'href="/%s/v/' % vid)
    html = html.replace("<body>", '<body><p style="padding:0 20px"><a href="/versions">← all versions</a> · %s</p>' % vid)
    return HTMLResponse(html)


@app.get("/{vid}/v/{name}")
async def version_view(vid: str, name: str) -> Any:
    path = _version_file(vid, name)
    if path is None:
        raise HTTPException(status_code=404, detail="unknown version front-end")
    return FileResponse(path, media_type="text/html; charset=utf-8")


@app.get("/{vid}/themes/{name}.css")
async def version_theme(vid: str, name: str) -> Any:
    path = _version_css(vid, name)
    if path is None:
        raise HTTPException(status_code=404, detail="unknown version theme")
    return FileResponse(path, media_type="text/css; charset=utf-8")
