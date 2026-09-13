import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EMIT = ROOT / "hud" / "hook_emit.py"


def test_backend_down_exits_zero_fast_no_stdout():
    env = os.environ.copy()
    env["HUD_PORT"] = "1"
    env.pop("HUD_DEBUG", None)
    env.pop("HUD_INGEST_URL", None)
    payload = json.dumps({"hook_event_name": "Stop", "session_id": "down"}).encode()
    t0 = time.perf_counter()
    proc = subprocess.run(
        [sys.executable, str(EMIT)],
        input=payload,
        capture_output=True,
        timeout=2,
        env=env,
        cwd=str(ROOT),
    )
    elapsed = time.perf_counter() - t0
    assert proc.returncode == 0
    assert proc.stdout == b""
    assert elapsed < 0.3


def test_backend_up_event_lands_with_right_kind(live_server, monkeypatch):
    env = os.environ.copy()
    env["HUD_PORT"] = str(live_server["port"])
    env.pop("HUD_DEBUG", None)
    env["HUD_INGEST_URL"] = live_server["url"] + "/ingest"
    payload = json.dumps(
        {
            "hook_event_name": "Notification",
            "session_id": "hook-up",
            "message": "needs you",
        }
    ).encode()
    proc = subprocess.run(
        [sys.executable, str(EMIT)],
        input=payload,
        capture_output=True,
        timeout=3,
        env=env,
        cwd=str(ROOT),
    )
    assert proc.returncode == 0
    assert proc.stdout == b""
    with urllib.request.urlopen(live_server["url"] + "/events?session=hook-up", timeout=2) as resp:
        events = json.loads(resp.read().decode("utf-8"))
    assert len(events) == 1
    assert events[0]["kind"] == "notification"
    assert events[0]["payload"]["message"] == "needs you"
