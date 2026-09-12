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
