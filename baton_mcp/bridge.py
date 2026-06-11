"""Subprocess bridge to scripts/mcp-bridge.ps1 — the single PS entry point.

Args travel via a temp JSON file (965-byte shell-arg rule). The bridge prints one
JSON envelope; we parse the last stdout line so stray lib chatter can't break it.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_TIMEOUT_S = 240


def bridge_script() -> Path:
    override = os.environ.get("BATON_MCP_BRIDGE", "")
    # An override containing "${" is an unexpanded template variable (e.g.
    # ${CLAUDE_PLUGIN_ROOT} when the host app didn't substitute it) — ignore it
    # and fall back to the package-sibling path, which is correct in both the
    # repo and plugin-cache layouts.
    if override and not ("${" in override and not Path(override).is_file()):
        return Path(override)
    return Path(__file__).resolve().parent.parent / "scripts" / "mcp-bridge.ps1"


def run_op(op: str, args: dict | None = None, timeout: int = DEFAULT_TIMEOUT_S) -> dict:
    argpath: str | None = None
    proc: subprocess.Popen | None = None
    try:
        if args:
            fd, argpath = tempfile.mkstemp(suffix=".json")
            os.close(fd)
            Path(argpath).write_text(json.dumps(args), encoding="utf-8")
        cmd = ["pwsh", "-NoProfile", "-File", str(bridge_script()), "-Op", op]
        if argpath:
            cmd += ["-ArgsPath", argpath]
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Windows: kill the whole process tree; Unix: fallback to proc.kill()
            if sys.platform == "win32":
                subprocess.run(
                    ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                    capture_output=True,
                )
            else:
                proc.kill()
            proc.communicate()
            return {"ok": False, "error": f"bridge op '{op}' timed out after {timeout}s"}
        out = (stdout or "").strip()
        if not out:
            return {"ok": False, "error": f"bridge produced no output (exit {proc.returncode}): {(stderr or '')[-400:]}"}
        try:
            return json.loads(out.splitlines()[-1])
        except json.JSONDecodeError:
            return {"ok": False, "error": f"bridge output was not JSON: {out[:400]}"}
    except FileNotFoundError as e:
        return {"ok": False, "error": f"pwsh not found: {e}"}
    finally:
        if argpath:
            Path(argpath).unlink(missing_ok=True)
