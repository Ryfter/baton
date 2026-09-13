"""Shared fixtures: isolated SQLite + config, optional live uvicorn."""
from __future__ import annotations

import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def _free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return int(port)


@pytest.fixture
def isolated_state(tmp_path, monkeypatch):
    db = tmp_path / "hud.db"
    cfg = tmp_path / "config.json"
    cfg.write_text('{"default_frontend": null}\n', encoding="utf-8")
    monkeypatch.setenv("HUD_DB", str(db))
    monkeypatch.setenv("HUD_CONFIG", str(cfg))
    monkeypatch.setenv("HUD_HOST", "127.0.0.1")
    monkeypatch.delenv("HUD_TOKEN", raising=False)
    monkeypatch.setenv("HUD_DISABLE_RETENTION", "1")
    import hud.store as store

    store.reset()
    store.init_db()
    yield {"db": db, "config": cfg, "tmp": tmp_path}
    store.reset()


@pytest.fixture
def client(isolated_state):
    from fastapi.testclient import TestClient
    from hud.server import app

    with TestClient(app) as c:
        yield c


@pytest.fixture
def live_server(isolated_state):
    """In-process uvicorn on a free port; shares the isolated store."""
    import uvicorn
    from hud.server import app

    port = _free_port()
    config = uvicorn.Config(
        app, host="127.0.0.1", port=port, log_level="warning", lifespan="off"
    )
    server = uvicorn.Server(config)
    server.install_signal_handlers = lambda: None
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    url = "http://127.0.0.1:%s" % port
    deadline = time.time() + 5
    last_err = None
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url + "/healthz", timeout=0.2)
            break
        except Exception as exc:
            last_err = exc
            time.sleep(0.05)
    else:
        server.should_exit = True
        raise RuntimeError("hud test server failed to start: %s" % last_err)
    yield {"url": url, "port": port}
    server.should_exit = True
    thread.join(timeout=3)


def make_event(**overrides):
    event = {
        "schema": "hud.event/v1",
        "ts": "2026-09-09T07:40:00Z",
        "session_id": "abc123",
        "source": "claude-hook",
        "kind": "stop",
        "agent": "main",
        "machine": "droid",
        "payload": {},
    }
    event.update(overrides)
    return event
