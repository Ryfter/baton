import json
import threading
import time
import urllib.request

from hud.config import read_config, write_config


def test_ingest_stores_and_returns_id_seq(client):
    r = client.post("/ingest", json={"session_id": "s1", "kind": "stop", "payload": {}})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["id"] >= 1
    assert body["seq"] == 1
    r2 = client.post("/ingest", json={"session_id": "s1", "kind": "notification", "payload": {"message": "x"}})
    assert r2.json()["seq"] == 2


def test_stream_receives_subsequently_ingested_event(live_server):
    url = live_server["url"]
    got = []
    err = []

    def listen():
        try:
            req = urllib.request.Request(url + "/stream?replay=0")
            with urllib.request.urlopen(req, timeout=8) as resp:
                while True:
                    line = resp.readline()
                    if not line:
                        break
                    if line.startswith(b"data:"):
                        got.append(json.loads(line[5:].decode("utf-8")))
                        return
        except Exception as exc:
            err.append(exc)

    t = threading.Thread(target=listen, daemon=True)
    t.start()
    time.sleep(0.25)
    body = json.dumps({"session_id": "live-1", "kind": "notification", "payload": {"message": "hi"}}).encode()
    req = urllib.request.Request(
        url + "/ingest",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=2)
    t.join(timeout=5)
    assert not err, err
    assert got, "subscriber received no SSE data"
    assert got[0]["session_id"] == "live-1"
    assert got[0]["kind"] == "notification"


def test_events_filters(client):
    client.post("/ingest", json={"session_id": "a", "kind": "stop", "payload": {}})
    client.post("/ingest", json={"session_id": "b", "kind": "notification", "payload": {"message": "n"}})
    all_ev = client.get("/events").json()
    assert len(all_ev) == 2
    assert all_ev[0]["id"] < all_ev[1]["id"]
    only_b = client.get("/events", params={"session": "b"}).json()
    assert len(only_b) == 1 and only_b[0]["session_id"] == "b"
    only_n = client.get("/events", params={"kind": "notification"}).json()
    assert len(only_n) == 1 and only_n[0]["kind"] == "notification"
    since = client.get("/events", params={"since": all_ev[0]["id"]}).json()
    assert len(since) == 1 and since[0]["id"] == all_ev[1]["id"]


def test_root_chooser_when_no_default(client):
    write_config(None)
    r = client.get("/", follow_redirects=False)
    assert r.status_code == 200
    text = r.text
    assert "deck" in text and "board" in text and "cockpit" in text and "minimal" in text
    assert "Set as default" in text
    assert "just view once" in text


def test_root_redirects_when_default_set(client):
    write_config("deck")
    r = client.get("/", follow_redirects=False)
    assert r.status_code == 302
    assert r.headers["location"].rstrip("/").endswith("/v/deck")


def test_v_deck_serves_v_bogus_404(client):
    r = client.get("/v/deck")
    assert r.status_code == 200
    assert "text/html" in r.headers.get("content-type", "")
    assert "EventSource('/stream?replay=200'" in r.text
    r404 = client.get("/v/bogus")
    assert r404.status_code == 404


def test_versions_index_lists_snapshots(client):
    r = client.get("/versions")
    assert r.status_code == 200
    assert "text/html" in r.headers.get("content-type", "")
    assert "/v1/v/deck" in r.text
    assert "/v2/v/cards" in r.text


def test_versioned_view_serves_snapshot(client):
    r = client.get("/v2/v/cards")
    assert r.status_code == 200
    assert "text/html" in r.headers.get("content-type", "")
    r1 = client.get("/v1/v/deck")
    assert r1.status_code == 200
    # v1 predates cards.html
    assert client.get("/v1/v/cards").status_code == 404
    # unknown version id
    assert client.get("/v9/v/deck").status_code == 404
    # path traversal rejected
    assert client.get("/v1/v/..%2f..%2fserver").status_code == 404


def test_version_chooser_links_are_scoped(client):
    r = client.get("/v2")
    assert r.status_code == 200
    assert 'href="/v2/v/' in r.text
    assert client.get("/v99").status_code == 404


def test_v3_snapshot_serves_scoped_themes(client):
    r = client.get("/v3/v/deck")
    assert r.status_code == 200
    # theme links in the frozen snapshot must be version-scoped, not the live /themes/
    assert "/v3/themes/" in r.text
    css = client.get("/v3/themes/dark.css")
    assert css.status_code == 200
    assert "text/css" in css.headers.get("content-type", "")
    assert client.get("/v3/themes/bogus.css").status_code == 404


def test_themes_css_serves(client):
    r = client.get("/themes/dark.css")
    assert r.status_code == 200
    assert "text/css" in r.headers.get("content-type", "")
    assert "--hud-bg" in r.text
    r404 = client.get("/themes/bogus.css")
    assert r404.status_code == 404
    r_bad = client.get("/themes/../server.css")
    assert r_bad.status_code == 404


def test_v4_snapshot_present(client):
    assert client.get("/v4/v/deck").status_code == 200
    assert "/v4/themes/" in client.get("/v4/v/board").text
    assert client.get("/v4/themes/sandstone.css").status_code == 200
    assert "/v4/v/deck" in client.get("/versions").text


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert isinstance(body["events"], int)
    assert isinstance(body["uptime_s"], int)


def test_config_round_trip(client):
    r = client.post("/config", json={"default_frontend": "deck"})
    assert r.status_code == 200
    assert r.json()["default_frontend"] == "deck"
    assert read_config()["default_frontend"] == "deck"
    r = client.post("/config", json={"default_frontend": None})
    assert r.status_code == 200
    assert r.json()["default_frontend"] is None
    assert read_config()["default_frontend"] is None


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


def _read_sse_lines(url, headers=None, timeout=2.0, max_lines=4):
    """Open a real HTTP GET against a live server and read up to max_lines
    SSE lines (default 4 = one full frame: `id:`, `event:`, `data:`, blank).

    NOTE on two deliberate deviations from the task brief's literal test code
    here (both confirmed empirically, not guessed):

    1. This goes through a real live uvicorn server (`live_server` fixture +
       urllib), never the FastAPI/Starlette `TestClient` fixture, for the two
       "simple" tests too. httpx's `ASGITransport` (which backs `TestClient`)
       buffers an endpoint's ENTIRE response internally and only hands any
       bytes back to the caller once the ASGI application callable *returns*
       (httpx/_transports/asgi.py: `send()` appends every body chunk to
       `body_parts`; `handle_async_request` doesn't build a `Response` until
       `await self.app(...)` completes). `/stream`'s generator never returns
       on its own -- it loops forever emitting periodic `: ping` keep-alives
       -- so `client.stream(...).read()` / `.iter_lines()` against
       `TestClient` hangs forever for this endpoint. Confirmed by direct
       repro: it still hung with an explicit low per-call timeout and with
       incremental `iter_lines()`, because the transport withholds all bytes
       until the app coroutine finishes (which it never does). A real socket
       doesn't have that limitation -- reads return as data arrives, exactly
       like a real browser's EventSource -- matching this file's existing
       `test_stream_receives_subsequently_ingested_event` pattern.

    2. This reads line-by-line (`resp.readline()`), never `resp.read(N)` for
       a largeish N (e.g. 4096, as the brief's Step 5 snippet does). Confirmed
       by direct repro against a real uvicorn server: `HTTPResponse.read(N)`
       on a chunked-transfer-encoded response (no Content-Length; `/stream`
       has none) only returns once N bytes have arrived on the wire *or* the
       connection closes (`http.client.HTTPResponse._read_chunked` loops
       pulling additional chunks from the socket until `amt` is satisfied --
       it is not a partial/non-blocking read). One SSE frame here is
       ~150-300 bytes, and the connection deliberately stays open (SSE
       keep-alive), so `.read(4096)` blocks past any short timeout even
       though the bytes we need already arrived. `.readline()` returns each
       `\\n`-terminated line as soon as it's on the wire, so reading exactly
       the lines of one frame is both correct and fast (confirmed: returns
       in ~1ms).
    """
    import urllib.request

    req = urllib.request.Request(url, headers=headers or {})
    lines = []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for _ in range(max_lines):
            try:
                line = resp.readline()
            except (TimeoutError, OSError):
                break
            if not line:
                break
            lines.append(line.decode("utf-8"))
    return "".join(lines)


def test_sse_frames_carry_id(live_server):
    url = live_server["url"]
    body = json.dumps({"session_id": "s1", "kind": "stop"}).encode()
    req = urllib.request.Request(
        url + "/ingest", data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    eid = json.loads(urllib.request.urlopen(req, timeout=2).read())["id"]
    chunk = _read_sse_lines(url + "/stream?replay=10")
    assert ("id: %d\n" % eid) in chunk


def test_stream_honours_last_event_id_header(live_server):
    url = live_server["url"]

    def ingest(kind, payload=None):
        body = json.dumps({"session_id": "s1", "kind": kind, "payload": payload or {}}).encode()
        req = urllib.request.Request(
            url + "/ingest", data=body, headers={"Content-Type": "application/json"}, method="POST"
        )
        return json.loads(urllib.request.urlopen(req, timeout=2).read())["id"]

    first_id = ingest("stop")
    second_id = ingest("notification", {"message": "x"})
    chunk = _read_sse_lines(url + "/stream", headers={"Last-Event-ID": str(first_id)})
    # resume from first_id must NOT replay first_id itself, but MUST include second_id
    assert ("id: %d" % first_id) not in chunk
    assert ("id: %d" % second_id) in chunk


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
    # NOTE: urllib.request.urlopen() has no `headers=` kwarg (confirmed:
    # passing one raises TypeError) -- build a Request object instead, same
    # as the /stream request below already (correctly) does.
    ingest_req = urllib.request.Request(
        "http://127.0.0.1:%d/ingest" % port,
        data=b'{"session_id":"s1","kind":"stop"}',
        headers={"Content-Type": "application/json"},
    )
    r = urllib.request.urlopen(ingest_req, timeout=2)
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
    try:
        req = urllib.request.Request(
            "http://127.0.0.1:%d/stream" % port,
            headers={"Last-Event-ID": str(first_id)},
        )
        # NOTE: readline()-based read, not resp.read(4096) -- see _read_sse_lines'
        # docstring above for why .read(N) blocks past any short timeout on a
        # chunked-transfer SSE response that stays open (confirmed empirically).
        chunk_lines = []
        with urllib.request.urlopen(req, timeout=2) as resp:
            for _ in range(4):  # one full frame: id / event / data / blank
                line = resp.readline()
                if not line:
                    break
                chunk_lines.append(line.decode("utf-8"))
        chunk = "".join(chunk_lines)
        assert ("id: %d" % second_id) in chunk
        assert ("id: %d" % first_id) not in chunk
    finally:
        # Always torn down, even if an assertion above raises -- otherwise a
        # failing test (exactly the failure mode this test exists to catch)
        # leaks srv2's daemon thread still listening on `port` for the rest
        # of the test process.
        srv2.should_exit = True
        t2.join(timeout=3)


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


def test_retention_task_starts_unless_disabled(monkeypatch, isolated_state):
    monkeypatch.delenv("HUD_DISABLE_RETENTION", raising=False)
    from fastapi.testclient import TestClient
    from hud import server
    with TestClient(server.app):
        assert server._retention_task is not None
        assert not server._retention_task.done()


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
    # Find a version that has theme support (v3 or v4; v1-v2 predate it)
    vid = None
    layout = None
    for row in rows:
        if row["id"] in ("v3", "v4"):
            vid = row["id"]
            layout = row["layouts"][0]
            break
    assert vid is not None, "No theme-aware frozen version found"
    r = client.get("/%s/v/%s" % (vid, layout))
    assert r.status_code == 200
    # frozen versions are served via FileResponse (untouched by Task 6's templating)
    # and must keep whatever literal default they shipped with -- "dark" for v3-v4.
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


def test_version_chooser_still_defaults_to_dark(client):
    r = client.get("/v3")
    assert r.status_code == 200
    assert 'localStorage.getItem("hud-theme") || "dark"' in r.text


def test_post_config_theme_only_write_preserves_frontend(client):
    client.post("/config", json={"default_frontend": "deck"})
    r = client.post("/config", json={"default_theme": "lapis-velvet"})
    assert r.status_code == 200
    assert r.json()["default_frontend"] == "deck"
    assert r.json()["default_theme"] == "lapis-velvet"
