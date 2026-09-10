"""Perimeter tests: bind/token auth, CSRF-shaped writes, body cap, NUL paths."""
from __future__ import annotations


def test_token_not_required_on_loopback(client, monkeypatch):
    monkeypatch.setenv("HUD_HOST", "127.0.0.1")
    monkeypatch.delenv("HUD_TOKEN", raising=False)
    r = client.get("/healthz")
    assert r.status_code == 200
    r = client.get("/events")
    assert r.status_code == 200


def test_token_required_off_loopback_without_token(client, monkeypatch):
    monkeypatch.setenv("HUD_HOST", "0.0.0.0")
    monkeypatch.delenv("HUD_TOKEN", raising=False)
    r = client.get("/healthz")
    assert r.status_code == 401
    r = client.get("/events")
    assert r.status_code == 401
    r = client.post("/ingest", json={"session_id": "s", "kind": "stop", "payload": {}})
    assert r.status_code == 401


def test_token_header_and_query_unlock_off_loopback(client, monkeypatch):
    monkeypatch.setenv("HUD_HOST", "0.0.0.0")
    monkeypatch.setenv("HUD_TOKEN", "secret")
    assert client.get("/healthz").status_code == 401
    assert client.get("/healthz", headers={"X-HUD-Token": "wrong"}).status_code == 401
    assert client.get("/healthz", headers={"X-HUD-Token": "secret"}).status_code == 200
    assert client.get("/healthz", params={"t": "secret"}).status_code == 200
    assert client.get("/events", params={"t": "secret"}).status_code == 200
    r = client.post(
        "/ingest",
        json={"session_id": "s", "kind": "stop", "payload": {}},
        headers={"X-HUD-Token": "secret"},
    )
    assert r.status_code == 200


def test_token_required_on_loopback_when_set(client, monkeypatch):
    monkeypatch.setenv("HUD_HOST", "127.0.0.1")
    monkeypatch.setenv("HUD_TOKEN", "secret")
    assert client.get("/healthz").status_code == 401
    assert client.get("/healthz", headers={"X-HUD-Token": "secret"}).status_code == 200


def test_non_json_content_type_415(client):
    body = b'{"session_id":"s","kind":"stop","payload":{}}'
    r = client.post("/ingest", content=body, headers={"Content-Type": "text/plain"})
    assert r.status_code == 415
    r = client.post(
        "/config",
        content=b'{"default_frontend":"deck"}',
        headers={"Content-Type": "text/plain;charset=UTF-8"},
    )
    assert r.status_code == 415


def test_cross_origin_write_403(client):
    r = client.post(
        "/ingest",
        json={"session_id": "s", "kind": "stop", "payload": {}},
        headers={"Origin": "https://evil.example"},
    )
    assert r.status_code == 403
    r = client.post(
        "/config",
        json={"default_frontend": "deck"},
        headers={"Origin": "https://evil.example"},
    )
    assert r.status_code == 403


def test_null_byte_path_404(client):
    assert client.get("/v/%00deck").status_code == 404
    assert client.get("/v1/themes/a%00b.css").status_code == 404


def test_oversized_body_413(client):
    big = {"session_id": "s", "kind": "stop", "payload": {"x": "a" * (65 * 1024)}}
    r = client.post("/ingest", json=big)
    assert r.status_code == 413


def test_same_host_origin_write_allowed(client):
    r = client.post(
        "/ingest",
        json={"session_id": "s", "kind": "stop", "payload": {}},
        headers={"Origin": "http://droid:8765"},
    )
    assert r.status_code == 200
