"""FastAPI HUD server: ingest, SSE stream, history, chooser, config."""
from __future__ import annotations

import asyncio
import hmac
import json
import logging
import os
import re
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional
from urllib.parse import quote, urlsplit

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response, StreamingResponse
from starlette.middleware.trustedhost import TrustedHostMiddleware

from hud import config as hud_config
from hud import store
from hud.schema import SCHEMA_ID, validate_envelope

logger = logging.getLogger("hud")

_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def host_is_loopback(host: str | None = None) -> bool:
    h = (host if host is not None else os.environ.get("HUD_HOST", "127.0.0.1")).strip().lower()
    return h in _LOOPBACK_HOSTS


def warn_if_unauthed_lan(host: str | None = None) -> None:
    h = (host if host is not None else os.environ.get("HUD_HOST", "127.0.0.1")).strip()
    if host_is_loopback(h) or os.environ.get("HUD_TOKEN"):
        return
    msg = (
        "WARNING: HUD is bound to %s (not loopback) without HUD_TOKEN. "
        "All requests will be rejected with 401. Set HUD_TOKEN and pass it "
        "as the X-HUD-Token header or ?t= query parameter. "
        "Example: HUD_HOST=0.0.0.0 HUD_TOKEN=secret python -m hud\n" % (h or "?",)
    )
    try:
        sys.stderr.write(msg)
        sys.stderr.flush()
    except Exception:
        pass
    logger.warning(msg.strip())


def _with_t(path: str, token: str) -> str:
    if not token:
        return path
    sep = "&" if "?" in path else "?"
    return path + sep + "t=" + quote(token, safe="")


def allowed_hosts() -> set[str]:
    hosts = {
        "testserver",
        "localhost",
        "127.0.0.1",
        "::1",
        "[::1]",
        "droid",
        "droid.local",
    }
    extra = os.environ.get("HUD_ALLOWED_HOSTS", "")
    for part in extra.split(","):
        h = part.strip().lower()
        if h:
            hosts.add(h)
    try:
        hn = socket.gethostname().strip().lower()
        if hn:
            hosts.add(hn)
            if "." not in hn:
                hosts.add(hn + ".local")
    except Exception:
        pass
    return hosts


def _require_json_write(request: Request) -> None:
    ctype = (request.headers.get("content-type") or "").lower()
    if not ctype.startswith("application/json"):
        raise HTTPException(status_code=415, detail="application/json required")
    origin = request.headers.get("origin")
    if origin:
        host = urlsplit(origin).hostname
        if not host or host.lower() not in allowed_hosts():
            raise HTTPException(status_code=403, detail="cross-origin write refused")


async def _read_json_object(request: Request) -> dict[str, Any]:
    _require_json_write(request)
    raw = await request.body()
    if len(raw) > MAX_BODY:
        raise HTTPException(status_code=413, detail="payload too large")
    try:
        body = json.loads(raw)
    except Exception:
        raise HTTPException(status_code=422, detail="invalid json")
    if not isinstance(body, dict):
        raise HTTPException(status_code=422, detail="invalid body")
    return body


def _clamp_payload(payload: dict[str, Any]) -> dict[str, Any]:
    out = dict(payload)
    for key, cap in _PAYLOAD_CAPS.items():
        if key in out and out[key] is not None:
            out[key] = str(out[key])[:cap]
    return out

FRONTENDS_DIR = Path(__file__).resolve().parent / "frontends"
VERSIONS_DIR = Path(__file__).resolve().parent / "versions"
_VID_RE = re.compile(r"^v\d+$")
_SEG_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
THEMES_DIR = FRONTENDS_DIR / "themes"
THEME_NAMES = ("dark", "sapphire", "lapis-velvet", "sandstone")
STARTED_AT = time.time()

_subscribers: set[asyncio.Queue] = set()
_QUEUE_MAX = 256
MAX_BODY = 64 * 1024
EVENTS_LIMIT = 500
_PAYLOAD_CAPS = {
    "tool_input_summary": 120,
    "message": 500,
    "prompt": 500,
}

CHOOSER_DESCRIPTIONS = {
    "deck": "Flight deck — one swim-lane per session; origin pinned, short verb chips, newest grows right.",
    "board": "Mission board — Running / Needs You / Stopped. Cards show why they moved.",
    "cockpit": "Instrument panel — four stats, 60s throughput ribbon, click-to-filter feed.",
    "cards": "Session cards on a responsive grid — compare sessions as objects, last chips inside each card.",
    "minimal": "Accessible event table — time, session, kind, detail. Colour only for errors.",
}


def _utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _frontend_names() -> list[str]:
    if not FRONTENDS_DIR.is_dir():
        return []
    names = sorted(p.stem for p in FRONTENDS_DIR.glob("*.html") if p.is_file())
    return names


def _safe_seg(name: str) -> bool:
    return bool(_SEG_RE.match(name or "")) and ".." not in name


def _frontend_path(name: str) -> Optional[Path]:
    if not _safe_seg(name):
        return None
    try:
        path = (FRONTENDS_DIR / ("%s.html" % name)).resolve()
        path.relative_to(FRONTENDS_DIR.resolve())
    except ValueError:
        return None
    if path.is_file():
        return path
    return None


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
    if sub and not _safe_seg(sub):
        return None
    try:
        base = (VERSIONS_DIR / vid).resolve()
        rel = ("%s/%s.html" % (sub, name)) if sub else ("%s.html" % name)
        path = (base / rel).resolve() if not sub else (base / sub / ("%s.html" % name)).resolve()
        path.relative_to(base)
    except ValueError:
        return None
    return path if path.is_file() else None


def _version_css(vid: str, name: str) -> Optional[Path]:
    if not (_VID_RE.match(vid) and _safe_seg(name)):
        return None
    try:
        base = (VERSIONS_DIR / vid / "themes").resolve()
        path = (base / ("%s.css" % name)).resolve()
        path.relative_to(base)
    except ValueError:
        return None
    return path if path.is_file() else None


def _theme_path(name: str) -> Optional[Path]:
    if name.endswith(".css"):
        name = name[:-4]
    if not _safe_seg(name) or name not in THEME_NAMES:
        return None
    try:
        path = (THEMES_DIR / ("%s.css" % name)).resolve()
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
        "payload": _clamp_payload(payload),
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


def _chooser_html(names: list[str], token: str = "") -> str:
    cards = []
    for name in names:
        desc = CHOOSER_DESCRIPTIONS.get(name, "HUD front-end variant.")
        cards.append(
            """
            <article class="card">
              <h2>%s</h2>
              <p>%s</p>
              <div class="row">
                <a href="%s">just view once</a>
                <button type="button" data-name="%s">Set as default</button>
              </div>
            </article>
            """
            % (name, desc, _with_t("/v/%s" % name, token), name)
        )
    return """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>HUD — choose a view</title>
  <script>
    (function () {
      var ALLOWED = ["dark", "sapphire", "lapis-velvet", "sandstone"];
      var q = new URLSearchParams(location.search);
      var t = q.get("theme");
      if (t && ALLOWED.indexOf(t) >= 0) localStorage.setItem("hud-theme", t);
      else t = localStorage.getItem("hud-theme") || "dark";
      if (ALLOWED.indexOf(t) < 0) t = "dark";
      document.write('<link rel="stylesheet" id="hud-theme" href="/themes/' + t + '.css">');
    })();
  </script>
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
      margin: 0 0 6px; font-size: 18px; font-weight: 650;
      font-family: var(--hud-font-display, var(--hud-font-sans, sans-serif));
      color: var(--hud-text-strong, #e6edf3);
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
    .theme-bar select:focus-visible, a:focus-visible, button:focus-visible {
      outline: 2px solid var(--hud-accent, #8ec8ff); outline-offset: 2px;
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
        <h1>Mission control HUD</h1>
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
      var q = new URLSearchParams(location.search).get("theme");
      var t = q || localStorage.getItem("hud-theme") || "dark";
      pick.value = t;
      if (link) link.href = "/themes/" + t + ".css";
      pick.addEventListener("change", function () {
        localStorage.setItem("hud-theme", pick.value);
        if (link) link.href = "/themes/" + pick.value + ".css";
        var u = new URL(location.href);
        u.searchParams.set("theme", pick.value);
        history.replaceState(null, "", u);
      });
    })();
    document.querySelectorAll("button[data-name]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var name = btn.getAttribute("data-name");
        var tok = new URLSearchParams(location.search).get("t") || "";
        var headers = { "Content-Type": "application/json" };
        if (tok) headers["X-HUD-Token"] = tok;
        var cfgUrl = "/config" + (tok ? "?t=" + encodeURIComponent(tok) : "");
        fetch(cfgUrl, {
          method: "POST",
          headers: headers,
          body: JSON.stringify({ default_frontend: name })
        }).then(function () {
          location.href = "/v/" + name + (tok ? "?t=" + encodeURIComponent(tok) : "");
        });
      });
    });
  </script>
</body>
</html>
""" % "\n".join(cards)


app = FastAPI(title="hud", docs_url=None, redoc_url=None)
app.add_middleware(
    TrustedHostMiddleware,
    allowed_hosts=list(allowed_hosts()) + ["*.local"],
    www_redirect=False,
)


@app.middleware("http")
async def _auth(request: Request, call_next):
    token = os.environ.get("HUD_TOKEN") or ""
    off_loopback = not host_is_loopback()
    if token or off_loopback:
        provided = request.headers.get("x-hud-token") or request.query_params.get("t") or ""
        if not token or not hmac.compare_digest(provided, token):
            return Response(status_code=401)
    return await call_next(request)


@app.post("/ingest")
async def ingest(request: Request) -> dict[str, Any]:
    body = await _read_json_object(request)
    try:
        event = _fill(body)
        event_id = await asyncio.to_thread(store.insert_event, event)
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
    limit: int = EVENTS_LIMIT,
    session: Optional[str] = None,
    kind: Optional[str] = None,
) -> list[dict[str, Any]]:
    try:
        cap = EVENTS_LIMIT if limit is None else int(limit)
    except (TypeError, ValueError):
        cap = EVENTS_LIMIT
    cap = max(0, min(cap, EVENTS_LIMIT))
    return await asyncio.to_thread(
        store.query_events, since=since, limit=cap, session=session, kind=kind
    )


@app.get("/")
async def root(request: Request) -> Any:
    cfg = hud_config.read_config()
    token = request.query_params.get("t") or ""
    name = cfg.get("default_frontend")
    if name:
        raw = str(name)
        if raw.endswith(".html"):
            raw = raw[:-5]
        path = _frontend_path(raw)
        if path is not None:
            return RedirectResponse(url=_with_t("/v/%s" % path.stem, token), status_code=302)
    names = _frontend_names()
    return HTMLResponse(_chooser_html(names, token=token))


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
    body = await _read_json_object(request)
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
        "events": await asyncio.to_thread(store.count_events),
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
async def version_chooser(vid: str, request: Request) -> Any:
    if not _VID_RE.match(vid) or vid not in _version_ids():
        raise HTTPException(status_code=404, detail="unknown version")
    names = sorted(p.stem for p in (VERSIONS_DIR / vid).glob("*.html"))
    token = request.query_params.get("t") or ""
    html = _chooser_html(names, token=token).replace('href="/v/', 'href="/%s/v/' % vid)
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
