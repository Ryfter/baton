#!/usr/bin/env python3
"""Claude Code hook → POST /ingest. Fail-open: always exit 0, never write stdout."""
from __future__ import annotations

import json
import os
import socket
import sys
import threading
import urllib.error
import urllib.request

# `python3 hud/hook_emit.py` puts this file's dir on sys.path[0], not the repo root.
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from hud.schema import normalize_hook  # noqa: E402


def _debug(msg: object) -> None:
    if os.environ.get("HUD_DEBUG") == "1":
        try:
            sys.stderr.write("hud hook_emit: %s\n" % (msg,))
        except Exception:
            pass


def _ingest_url() -> str:
    override = os.environ.get("HUD_INGEST_URL")
    if override:
        return override
    port = os.environ.get("HUD_PORT", "8765")
    return "http://127.0.0.1:%s/ingest" % (port,)


def _post(envelope: dict) -> None:
    url = _ingest_url()
    body = json.dumps(envelope).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    def worker() -> None:
        try:
            urllib.request.urlopen(req, timeout=0.25)
        except Exception as exc:
            _debug(exc)

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    thread.join(0.25)


def main() -> None:
    try:
        raw = sys.stdin.read()
        if raw and raw.strip():
            data = json.loads(raw)
            envelope = normalize_hook(data)
            _post(envelope)
    except Exception as exc:
        _debug(exc)
    sys.exit(0)


if __name__ == "__main__":
    try:
        socket.setdefaulttimeout(0.25)
        main()
    except SystemExit:
        raise
    except BaseException:
        sys.exit(0)
