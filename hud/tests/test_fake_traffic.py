import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

from hud.fake_traffic import EVENT_COUNT

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "hud" / "fake_traffic.py"


def test_fake_traffic_fast_produces_expected_count(live_server):
    env = os.environ.copy()
    env["HUD_PORT"] = str(live_server["port"])
    env["HUD_INGEST_URL"] = live_server["url"] + "/ingest"
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--fast"],
        capture_output=True,
        timeout=15,
        env=env,
        cwd=str(ROOT),
    )
    assert proc.returncode == 0, proc.stderr.decode()
    with urllib.request.urlopen(live_server["url"] + "/events?limit=2000", timeout=2) as resp:
        events = json.loads(resp.read().decode("utf-8"))
    assert len(events) == EVENT_COUNT
