#!/usr/bin/env python3
"""Stop / SubagentStop gate -- the agent does not finish while tests are red.

Opt-in per project. On a Stop event the guard looks for `.claude/test-gate.sh`
in the session's cwd:

  - not there, or not executable -> no gate, the agent stops normally.
  - there and executable -> run it under `bash`. The project script decides
    *what* to run and whether the pending changes even need testing at all (it
    can `git diff --quiet -- scripts/` and exit 0 in a millisecond). Exit 0 ->
    stop allowed. Non-zero -> the agent is blocked from stopping and handed the
    tail of the script's output.

Design (matches publish-guard.py / rm-rf-guard.py house style):
  - `stop_hook_active` short-circuit FIRST, or a blocked stop loops.
  - Fails OPEN on internal error -- missing bash, an unreadable payload, an
    unhandled exception. A broken gate must never wedge a session.
  - A run that EXCEEDS RUN_TIMEOUT blocks, not fails open: an unfinished suite
    is red until proven otherwise, and a gate that opens on timeout is not a
    gate. `stop_hook_active` short-circuits the retry, so it blocks once.
  - Block protocol: {"decision": "block", "reason": ...} on stdout, exit 0.

The project script runs verbatim in the project cwd, so it uses the project's
own toolchain -- never rebuilt from this hook's interpreter environment.
"""
import json
import os
import subprocess
import sys

GATE_SCRIPT = ".claude/test-gate.sh"
RUN_TIMEOUT = 540         # hooks.json wires this Stop hook at 600; stay under it
TAIL_CHARS = 3000
BASH = "/bin/bash" if sys.platform == "darwin" else "bash"  # macOS: system 3.2


def block(reason):
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.stderr.write(reason + "\n")
    sys.exit(0)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0                                    # fail open
    if not isinstance(data, dict):
        return 0                                    # fail open on odd payload

    if data.get("stop_hook_active"):                # loop guard -- must be first
        return 0

    cwd = data.get("cwd") or os.getcwd()
    script = os.path.join(cwd, GATE_SCRIPT)
    if not (os.path.isfile(script) and os.access(script, os.X_OK)):
        return 0                                    # project hasn't opted in

    try:
        p = subprocess.run(
            [BASH, script], cwd=cwd, capture_output=True,
            text=True, errors="replace", timeout=RUN_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        # a gate that fails OPEN on timeout is not a gate -- an unfinished
        # suite is red until proven otherwise. (stop_hook_active short-circuits
        # the retry, so this blocks once, not forever.)
        block(
            f"BLOCKED by test-gate: {GATE_SCRIPT} did not finish within "
            f"{RUN_TIMEOUT}s in {cwd}.\n"
            "Treat an unfinished gate as red -- speed up or split the suite, or "
            f"make {GATE_SCRIPT} exit 0 / drop its +x bit to bypass."
        )
        return 0
    except Exception:
        return 0                                    # missing bash, unreadable, ...

    if p.returncode == 0:
        return 0

    out = ((p.stdout or "") + (p.stderr or "")).strip() or "(no output)"
    tail = out[-TAIL_CHARS:]
    if len(out) > TAIL_CHARS:
        tail = "...\n" + tail
    block(
        f"BLOCKED by test-gate: {GATE_SCRIPT} exited {p.returncode} in {cwd}.\n"
        "Tests are red or a required check failed -- fix them before finishing.\n\n"
        f"{tail}\n\n"
        f"To bypass deliberately, make {GATE_SCRIPT} exit 0 or drop its +x bit."
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)          # fail open, always
