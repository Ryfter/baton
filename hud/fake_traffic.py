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

SCRIPT: list[tuple[float, dict]] = [
    (
        0.25,
        {
            "session_id": "sess-alpha",
            "kind": "session_start",
            "agent": "main",
            "payload": {"source": "startup", "cwd": "/Users/kev/Dev/Baton"},
        },
    ),
    (
        0.15,
        {
            "session_id": "sess-alpha",
            "kind": "user_prompt",
            "payload": {"prompt": "Ship the HUD prototype"},
        },
    ),
    (
        0.12,
        {
            "session_id": "sess-alpha",
            "kind": "pre_tool_use",
            "payload": {"tool_name": "Read", "tool_input_summary": "docs/spec.md"},
        },
    ),
    (
        0.12,
        {
            "session_id": "sess-alpha",
            "kind": "post_tool_use",
            "payload": {"tool_name": "Read", "ok": True},
        },
    ),
    (
        0.12,
        {
            "session_id": "sess-alpha",
            "kind": "pre_tool_use",
            "payload": {"tool_name": "Bash", "tool_input_summary": "pytest hud/tests -q"},
        },
    ),
    (
        0.12,
        {
            "session_id": "sess-alpha",
            "kind": "post_tool_use",
            "payload": {"tool_name": "Bash", "ok": False, "error": "exit 1"},
        },
    ),
    (
        0.20,
        {
            "session_id": "sess-beta",
            "kind": "session_start",
            "payload": {"source": "resume", "cwd": "/tmp"},
        },
    ),
    (
        0.12,
        {
            "session_id": "sess-beta",
            "kind": "notification",
            "payload": {"message": "Permission required: git push"},
        },
    ),
    (
        0.12,
        {
            "session_id": "sess-beta",
            "kind": "pre_compact",
            "payload": {"trigger": "auto"},
        },
    ),
    (
        0.15,
        {
            "session_id": "sess-gamma",
            "kind": "session_start",
            "payload": {"source": "startup", "cwd": "/opt"},
        },
    ),
    (
        0.10,
        {
            "session_id": "sess-gamma",
            "kind": "pre_tool_use",
            "payload": {"tool_name": "Agent", "tool_input_summary": "explore codebase"},
        },
    ),
    (
        0.10,
        {
            "session_id": "sess-gamma",
            "kind": "subagent_stop",
            "agent": "Explore",
            "payload": {"agent": "Explore"},
        },
    ),
    (
        0.10,
        {
            "session_id": "sess-gamma",
            "kind": "stop",
            "payload": {},
        },
    ),
    (
        0.10,
        {
            "session_id": "sess-alpha",
            "kind": "notification",
            "payload": {"message": "Waiting on Kevin"},
        },
    ),
    (
        0.10,
        {
            "session_id": "sess-alpha",
            "kind": "stop",
            "payload": {},
        },
    ),
]

EVENT_COUNT = len(SCRIPT)


def _url(port: str) -> str:
    override = os.environ.get("HUD_INGEST_URL")
    if override:
        return override
    return "http://127.0.0.1:%s/ingest" % port


def post_event(url: str, event: dict) -> None:
    body = json.dumps(event).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=5)


def run(fast: bool = False, port: str | None = None) -> int:
    port = port or os.environ.get("HUD_PORT", "8765")
    url = _url(str(port))
    sent = 0
    for delay, event in SCRIPT:
        if not fast and delay:
            time.sleep(delay)
        post_event(url, event)
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
