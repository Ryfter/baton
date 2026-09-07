#!/usr/bin/env python3
"""Robust launcher for the Baton MCP stdio server, with a dependency fallback.

Claude Code starts an MCP server with a minimal PATH and no venv activation, so
the interpreter that runs this file may not have `mcp` / `numpy` / `httpx`.
`.mcp.json` runs us as `python3 -c "<find root>; exec _launch.py"`. From there:

  1. this interpreter already has the deps  -> run the server in-process
  2. `uv` is on PATH                         -> re-exec via `uv run`
  3. `<root>/.venv` exists                   -> re-exec with that interpreter
  4. none of the above                       -> print how to fix, exit 1

`_BATON_MCP_RELAUNCHED=1` guards against an infinite re-exec loop: if the deps
are still missing after step 2/3, stop and print the diagnostic.

Only stdlib is imported at module top level -- the third-party deps may be
absent in the interpreter that first runs this file.

Note: `.mcp.json` uses `command: "python3"`, which resolves on macOS/Linux. A
Windows host whose Python is only `python` / `py` needs a shim (follow-up).
"""
import glob
import os
import shutil
import sys

_REQ = ("mcp>=1.25,<2", "numpy", "httpx")   # fallback if requirements.txt is absent


def plugin_root() -> str:
    env = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    if env and os.path.isdir(os.path.join(env, "baton_mcp")):
        return env
    hits = sorted(
        glob.glob(os.path.expanduser(
            "~/.claude/plugins/cache/ryfter/baton/*/baton_mcp")),
        key=os.path.getmtime, reverse=True,
    )
    if hits:
        return os.path.dirname(hits[0])
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _venv_python(root: str) -> str:
    if os.name == "nt":
        return os.path.join(root, ".venv", "Scripts", "python.exe")
    return os.path.join(root, ".venv", "bin", "python")


def _diagnostic(root: str) -> None:
    req = os.path.join(root, "requirements.txt")
    sys.stderr.write(
        "baton-mcp: cannot start -- this interpreter has no `mcp` package and no\n"
        "fallback interpreter is available.\n"
        f"  interpreter : {sys.executable}\n"
        f"  plugin root : {root}\n"
        "Fix any one of:\n"
        "  - install uv (https://docs.astral.sh/uv/) -- it is the default launcher\n"
        f"  - pip install 'mcp<2' numpy httpx   into {sys.executable}\n"
        f"  - create {root}/.venv  (python -m venv .venv && .venv/bin/pip install\n"
        f"    -r {req})\n"
    )


def _reexec(root: str) -> None:
    if os.environ.get("_BATON_MCP_RELAUNCHED") == "1":
        _diagnostic(root)                       # already tried once -- do not loop
        sys.exit(1)
    os.environ["_BATON_MCP_RELAUNCHED"] = "1"
    me = os.path.abspath(__file__)
    req = os.path.join(root, "requirements.txt")

    uv = shutil.which("uv")
    if uv:
        args = [uv, "run", "--quiet", "--no-project"]
        if os.path.isfile(req):
            args += ["--with-requirements", req]        # single source of truth
        else:
            for spec in _REQ:
                args += ["--with", spec]
        args += ["python", me]
        try:
            os.execv(uv, args)
        except OSError:
            pass

    vpy = _venv_python(root)
    if os.path.isfile(vpy):
        try:
            os.execv(vpy, [vpy, me])
        except OSError:
            pass

    _diagnostic(root)
    sys.exit(1)


def _run() -> None:
    root = plugin_root()
    if root not in sys.path:
        sys.path.insert(0, root)
    os.environ.setdefault(
        "BATON_MCP_BRIDGE", os.path.join(root, "scripts", "mcp-bridge.ps1"))
    try:
        from baton_mcp.server import main
    except ImportError:
        _reexec(root)
        return                                 # unreachable -- _reexec exits or execs
    main()


if __name__ == "__main__":
    _run()
