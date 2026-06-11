"""Subprocess bridge to scripts/mcp-bridge.ps1 — the single PS entry point.

Args travel via a temp JSON file (965-byte shell-arg rule). The bridge prints one
JSON envelope; we parse the last stdout line so stray lib chatter can't break it.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

DEFAULT_TIMEOUT_S = 240


def bridge_script() -> Path:
    override = os.environ.get("BATON_MCP_BRIDGE", "")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent / "scripts" / "mcp-bridge.ps1"


def run_op(op: str, args: dict | None = None, timeout: int = DEFAULT_TIMEOUT_S) -> dict:
    argpath: str | None = None
    try:
        if args:
            fd, argpath = tempfile.mkstemp(suffix=".json")
            os.close(fd)
            Path(argpath).write_text(json.dumps(args), encoding="utf-8")
        cmd = ["pwsh", "-NoProfile", "-File", str(bridge_script()), "-Op", op]
        if argpath:
            cmd += ["-ArgsPath", argpath]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (proc.stdout or "").strip()
        if not out:
            return {"ok": False, "error": f"bridge produced no output (exit {proc.returncode}): {(proc.stderr or '')[-400:]}"}
        try:
            return json.loads(out.splitlines()[-1])
        except json.JSONDecodeError:
            return {"ok": False, "error": f"bridge output was not JSON: {out[:400]}"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"bridge op '{op}' timed out after {timeout}s"}
    except FileNotFoundError as e:
        return {"ok": False, "error": f"pwsh not found: {e}"}
    finally:
        if argpath:
            Path(argpath).unlink(missing_ok=True)
