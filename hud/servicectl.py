"""Service install/status/rebuild logic behind `baton hud {install-service,status,rebuild}`.
Kept out of __main__.py so it's unit-testable without subprocess/argv plumbing."""
from __future__ import annotations

import platform
import subprocess
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from hud import store

PLIST_NAME = "dev.baton.hud.plist"

_PLIST_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.baton.hud</string>
  <key>ProgramArguments</key>
  <array>
    <string>%(python)s</string>
    <string>-m</string>
    <string>hud</string>
    <string>serve</string>
  </array>
  <key>WorkingDirectory</key><string>%(repo_root)s</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HUD_HOST</key><string>%(host)s</string>
    <key>HUD_PORT</key><string>%(port)s</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>%(repo_root)s/hud/logs/hud.out.log</string>
  <key>StandardErrorPath</key><string>%(repo_root)s/hud/logs/hud.err.log</string>
</dict>
</plist>
"""


class UnsupportedPlatform(RuntimeError):
    pass


class _FakeCompleted:
    returncode = 0


def render_launchd_plist(python_exe: str, repo_root: Path, *, host: str = "0.0.0.0", port: int = 8765) -> str:
    return _PLIST_TEMPLATE % {
        "python": python_exe,
        "repo_root": str(repo_root),
        "host": host,
        "port": port,
    }


def _launch_agents_dir() -> Path:
    return Path.home() / "Library" / "LaunchAgents"


def install_macos_service(repo_root: Path, *, host: str = "127.0.0.1", port: int = 8765,
                           python_exe: str = "") -> Path:
    import sys
    python_exe = python_exe or sys.executable
    (repo_root / "hud" / "logs").mkdir(parents=True, exist_ok=True)
    xml = render_launchd_plist(python_exe, repo_root, host=host, port=port)
    dest_dir = _launch_agents_dir()
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / PLIST_NAME
    dest.write_text(xml, encoding="utf-8")
    subprocess.run(["launchctl", "unload", str(dest)], capture_output=True)
    subprocess.run(["launchctl", "load", str(dest)], capture_output=True, check=False)
    return dest


def install_service(repo_root: Path, **kwargs: Any) -> Path:
    system = platform.system()
    if system == "Darwin":
        return install_macos_service(repo_root, **kwargs)
    raise UnsupportedPlatform(
        "install-service on %s lands in M2 (systemd user unit / Windows Task Scheduler). "
        "Run `python -m hud serve` directly for now." % system
    )


def status_summary(host: str, port: int, token: str = "") -> dict[str, Any]:
    url = "http://%s:%d/healthz" % (host if host not in ("0.0.0.0",) else "127.0.0.1", port)
    if token:
        url += "?t=" + token
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            import json
            body = json.loads(resp.read().decode("utf-8"))
        body["reachable"] = True
        return body
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"reachable": False, "error": str(exc)}


def rebuild_db() -> dict[str, Any]:
    """M1-provisional: WAL checkpoint + integrity check + row count.
    M4 extends this to also call derive.rebuild_sessions()."""
    conn = store.get_conn()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    integrity = conn.execute("PRAGMA integrity_check").fetchone()
    integrity_ok = bool(integrity and integrity[0] == "ok")
    events = store.count_events()
    return {"integrity_ok": integrity_ok, "events": events}
