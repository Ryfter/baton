#!/usr/bin/env python3
"""Replay a scripted event sequence to POST /ingest. --fast drops sleeps."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone


def _ev(session: str, kind: str, payload: dict | None = None, **kw) -> dict:
    return {
        "session_id": session,
        "kind": kind,
        "agent": kw.get("agent", "main"),
        "machine": kw.get("machine", "droid"),
        "payload": payload if payload is not None else {},
    }


# Delays are logical seconds (sum ≈ 50s) so cockpit's 60s sparkline has a curve.
# --fast skips the sleep but still stamps ts from the cumulative delay.
SCRIPT: list[tuple[float, dict]] = [
    (0.4, _ev("sess-alpha", "session_start", {"source": "startup", "cwd": "/Users/kev/Dev/Baton"})),
    (0.3, _ev("sess-alpha", "user_prompt", {"prompt": "Ship the HUD prototype"})),
    (0.2, _ev("sess-alpha", "pre_tool_use", {"tool_name": "Read", "tool_input_summary": "docs/spec.md"})),
    (0.5, _ev("sess-alpha", "post_tool_use", {"tool_name": "Read", "ok": True})),
    (0.6, _ev("sess-beta", "session_start", {"source": "resume", "cwd": "/Users/kev/Dev/Baton"})),
    (0.3, _ev("sess-beta", "user_prompt", {"prompt": "Review the open PR before merge"})),
    (0.5, _ev("sess-gamma", "session_start", {"source": "startup", "cwd": "/Users/kev/Dev/Baton"})),
    (0.3, _ev("sess-gamma", "user_prompt", {"prompt": "Explore the store layer"})),
    (0.4, _ev("sess-alpha", "pre_tool_use", {"tool_name": "Bash", "tool_input_summary": "pytest hud/tests -q"})),
    (0.8, _ev("sess-alpha", "post_tool_use", {"tool_name": "Bash", "ok": False, "error": "exit 1"})),
    (1.4, _ev("sess-delta", "session_start", {"source": "startup", "cwd": "/Users/kev/Dev/Baton"}, machine="office-pc")),
    (0.3, _ev("sess-delta", "user_prompt", {"prompt": "Fix the ingest 422 on empty payload"}, machine="office-pc")),
    (0.4, _ev("sess-alpha", "pre_tool_use", {"tool_name": "Grep", "tool_input_summary": "test_healthz hud/tests"})),
    (0.5, _ev("sess-alpha", "post_tool_use", {"tool_name": "Grep", "ok": True})),
    (0.3, _ev("sess-alpha", "pre_tool_use", {"tool_name": "Edit", "tool_input_summary": "hud/tests/test_server.py"})),
    (0.6, _ev("sess-alpha", "post_tool_use", {"tool_name": "Edit", "ok": True})),
    (1.8, _ev("sess-epsilon", "session_start", {"source": "startup", "cwd": "/tmp/scratch"})),
    (0.3, _ev("sess-epsilon", "user_prompt", {"prompt": "Wrap this session and compact"})),
    (0.4, _ev("sess-beta", "pre_tool_use", {"tool_name": "Read", "tool_input_summary": "pr.diff"})),
    (0.7, _ev("sess-beta", "post_tool_use", {"tool_name": "Read", "ok": True})),
    (0.3, _ev("sess-gamma", "pre_tool_use", {"tool_name": "Agent", "tool_input_summary": "explore hud/store.py"})),
    (1.1, _ev("sess-gamma", "subagent_stop", {"agent": "Explore"}, agent="Explore")),
    (0.4, _ev("sess-gamma", "pre_tool_use", {"tool_name": "Grep", "tool_input_summary": "insert_event hud/store.py"})),
    (0.5, _ev("sess-gamma", "post_tool_use", {"tool_name": "Grep", "ok": True})),
    (2.2, _ev("sess-delta", "pre_tool_use", {"tool_name": "Read", "tool_input_summary": "hud/server.py"}, machine="office-pc")),
    (0.4, _ev("sess-delta", "post_tool_use", {"tool_name": "Read", "ok": True}, machine="office-pc")),
    (0.3, _ev("sess-delta", "pre_tool_use", {"tool_name": "Grep", "tool_input_summary": "validate_envelope hud/"}, machine="office-pc")),
    (0.9, _ev("sess-delta", "post_tool_use", {"tool_name": "Grep", "ok": False, "error": "no matches"}, machine="office-pc")),
    (0.3, _ev("sess-delta", "pre_tool_use", {"tool_name": "Edit", "tool_input_summary": "hud/schema.py"}, machine="office-pc")),
    (0.6, _ev("sess-delta", "post_tool_use", {"tool_name": "Edit", "ok": True}, machine="office-pc")),
    (2.8, _ev("sess-epsilon", "pre_compact", {"trigger": "auto"})),
    (0.5, _ev("sess-epsilon", "stop", {})),
    (0.6, _ev("sess-alpha", "pre_tool_use", {"tool_name": "Bash", "tool_input_summary": "pytest hud/tests -q"})),
    (1.0, _ev("sess-alpha", "post_tool_use", {"tool_name": "Bash", "ok": True})),
    (0.4, _ev("sess-alpha", "stop", {})),
    (1.2, _ev("sess-beta", "notification", {"message": "Permission required: git push"})),
    (0.5, _ev("sess-gamma", "pre_tool_use", {"tool_name": "Read", "tool_input_summary": "hud/store.py"})),
    (0.4, _ev("sess-gamma", "post_tool_use", {"tool_name": "Read", "ok": True})),
    (0.6, _ev("sess-delta", "pre_tool_use", {"tool_name": "Bash", "tool_input_summary": "python -m hud --port 8765"}, machine="office-pc")),
    (0.8, _ev("sess-delta", "post_tool_use", {"tool_name": "Bash", "ok": True}, machine="office-pc")),
]

EVENT_COUNT = len(SCRIPT)


def _url(port: str) -> str:
    override = os.environ.get("HUD_INGEST_URL")
    if override:
        return override
    return "http://127.0.0.1:%s/ingest" % port


def post_event(url: str, event: dict) -> None:
    body = json.dumps(event).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    token = os.environ.get("HUD_TOKEN")
    if token:
        headers["X-HUD-Token"] = token
    req = urllib.request.Request(
        url,
        data=body,
        headers=headers,
        method="POST",
    )
    urllib.request.urlopen(req, timeout=5)


def run(fast: bool = False, port: str | None = None) -> int:
    port = port or os.environ.get("HUD_PORT", "8765")
    url = _url(str(port))
    total_delay = sum(d for d, _ in SCRIPT)
    origin = time.time() - total_delay
    acc = 0.0
    sent = 0
    for delay, event in SCRIPT:
        acc += delay
        if not fast and delay:
            time.sleep(delay)
        ev = dict(event)
        ev["payload"] = dict(event.get("payload") or {})
        ts = datetime.fromtimestamp(origin + acc, tz=timezone.utc)
        ev["ts"] = ts.strftime("%Y-%m-%dT%H:%M:%SZ")
        post_event(url, ev)
        sent += 1
    return sent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Replay scripted HUD events")
    parser.add_argument("--fast", action="store_true", help="drop sleeps between events")
    args = parser.parse_args(argv)
    try:
        n = run(fast=args.fast)
    except Exception as exc:
        sys.stderr.write("fake_traffic failed: %s\n" % exc)
        return 1
    sys.stderr.write("fake_traffic sent %s events\n" % n)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
