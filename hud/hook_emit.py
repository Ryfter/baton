#!/usr/bin/env python3
"""Claude Code hook → POST /ingest. Fail-open: always exit 0, never write stdout."""
from __future__ import annotations

import json
import os
import select
import socket
import sys
import threading
import urllib.error
import urllib.request
from urllib.parse import urlsplit

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


_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def _ingest_url() -> str:
    override = os.environ.get("HUD_INGEST_URL")
    if override:
        host = (urlsplit(override).hostname or "").lower()
        if host in _LOOPBACK_HOSTS:
            return override
        _debug("HUD_INGEST_URL host %r is not loopback; ignoring" % (host,))
    port = os.environ.get("HUD_PORT", "8765")
    return "http://127.0.0.1:%s/ingest" % (port,)


def _read_stdin() -> str:
    try:
        if sys.stdin.isatty():
            return ""
    except Exception:
        pass
    try:
        ready, _, _ = select.select([sys.stdin], [], [], 0.2)
        if not ready:
            return ""
    except Exception:
        pass
    return sys.stdin.read()


def _post(envelope: dict) -> None:
    url = _ingest_url()
    body = json.dumps(envelope).encode("utf-8")
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
        raw = _read_stdin()
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
