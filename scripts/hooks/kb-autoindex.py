#!/usr/bin/env python3
# kb-autoindex.py -- Claude Code PostToolUse hook: auto-indexes touched KB files.
#
# Reads the PostToolUse JSON payload from stdin. When Write/Edit touches a file
# under ~/.claude/knowledge/, starts `python -m kb.index --file <path>` in the
# background, re-indexing only the touched file rather than rescanning a scope.
#
# Ported from kb-autoindex.ps1 (2026-09-07). Behaviour identical except the
# background worker is launched with sys.executable (this hook's interpreter)
# instead of a bare `python` -- macOS/Homebrew ships only `python3`.

import json
import os
import subprocess
import sys


def main() -> int:
    try:
        raw = sys.stdin.read()
    except Exception:
        return 0
    if not raw or not raw.strip():
        return 0
    try:
        evt = json.loads(raw)
    except Exception:
        return 0

    file_path = (evt.get("tool_input") or {}).get("file_path")
    if not file_path:
        return 0

    knowledge_root = os.path.abspath(os.path.expanduser("~/.claude/knowledge")).rstrip("/\\")
    try:
        touched = os.path.abspath(os.path.expanduser(str(file_path)))
    except Exception:
        return 0

    if touched != knowledge_root:
        prefix = knowledge_root + os.sep
        if not touched.lower().startswith(prefix.lower()):
            return 0

    repo_root = None
    env_root = os.environ.get("CAO_REPO_ROOT")
    if env_root and os.path.isdir(os.path.join(env_root, "kb")):
        repo_root = os.path.abspath(env_root)
    else:
        candidate = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        if os.path.isdir(os.path.join(candidate, "kb")):
            repo_root = candidate

    kwargs = {
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "stdin": subprocess.DEVNULL,
        "start_new_session": True,
    }
    if repo_root:
        kwargs["cwd"] = repo_root
    try:
        subprocess.Popen([sys.executable, "-m", "kb.index", "--file", touched], **kwargs)
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
