"""python -m tools.doctor — health-check every enabled tool in tools.yaml.

Probe by kind: python → module importable? cli → command on PATH? http → base_url
reachable? Prints a NAME/STATUS/DETAIL table; exits 1 if any enabled tool errs.
"""
from __future__ import annotations

import importlib.util
import shutil
import sys
import urllib.request
from pathlib import Path

from tools.registry import ToolSpec, read_tools


def probe_tool(spec: ToolSpec) -> tuple[str, str]:
    """Return (status, detail) where status is ok | err | skip."""
    if not spec.enabled:
        return "skip", "disabled in tools.yaml"
    if spec.kind == "python":
        if not spec.module:
            return "err", "no module declared"
        try:
            found = importlib.util.find_spec(spec.module) is not None
        except (ImportError, ValueError, ModuleNotFoundError):
            found = False
        return ("ok", f"import {spec.module}") if found else ("err", f"cannot import {spec.module}")
    if spec.kind == "cli":
        exe = (spec.command_template or "").split()[0] if spec.command_template else spec.name
        path = shutil.which(exe)
        return ("ok", f"{exe} on PATH") if path else ("err", f"{exe} not on PATH")
    if spec.kind == "http":
        if not spec.base_url:
            return "err", "no base_url declared"
        try:
            urllib.request.urlopen(spec.base_url, timeout=2)  # noqa: S310
            return "ok", f"{spec.base_url} alive"
        except Exception:  # noqa: BLE001 — any failure = unreachable
            return "err", f"{spec.base_url} unreachable"
    return "err", f"unknown kind: {spec.kind}"


def run_doctor(*, path: Path | None = None) -> int:
    specs = read_tools(path)
    rows = [(s.name, *probe_tool(s)) for s in specs]
    width = max((len(r[0]) for r in rows), default=4)
    print(f"{'NAME'.ljust(width)}  STATUS  DETAIL")
    print(f"{'-' * width}  ------  ------")
    any_err = False
    for name, status, detail in rows:
        if status == "err":
            any_err = True
        print(f"{name.ljust(width)}  {status.ljust(6)}  {detail}")
    enabled = sum(1 for s in specs if s.enabled)
    print(f"\n{enabled} enabled tool(s).")
    return 1 if any_err else 0


def main(argv: list[str] | None = None) -> int:
    return run_doctor()


if __name__ == "__main__":
    raise SystemExit(main())
