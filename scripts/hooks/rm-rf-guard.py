#!/usr/bin/env python3
"""PreToolUse:Bash guard — the agent never runs a recursive-force delete.

`rm -rf` in any spelling (`-rf`, `-fr`, `-Rf`, `-r -f`, `--recursive --force`,
with or without `sudo`, in any segment of a compound command) is blocked
unconditionally. The agent must hand Kevin the command, the target paths, and
the reason it's needed; Kevin runs it himself (or via the `! ` prompt prefix).

Design (matches publish-guard.py house style):
  - Fast path: no "rm" substring -> exit immediately.
  - Fails OPEN on any internal error -- a broken guard must never wedge a session.
  - Emits the PreToolUse deny protocol as JSON on stdout, reason on stderr.

To loosen (e.g. allow deletes under the scratchpad), add an ALLOW_PREFIXES check
in segment_targets_ok() below.
"""
import json
import re
import sys

# Catch `rm` at a command boundary, or after sudo / xargs / find -exec.
RM_SEG = re.compile(
    r"(?:^|[;&|]|&&|\|\||xargs(?:\s+-\S+)*\s+|-exec\s+|sudo\s+)"
    r"\s*(?:sudo\s+)?rm\s+([^;&|]*)",
    re.I,
)


def read_command():
    data = json.load(sys.stdin)
    ti = data.get("tool_input") or {}
    return ti.get("command", "") if isinstance(ti, dict) else ""


def flags_of(args):
    """Return (has_recursive, has_force) accumulated over every flag token."""
    rec = force = False
    for tok in args.split():
        if tok == "--":
            break
        if tok.startswith("--"):
            if tok.startswith("--recursive"):
                rec = True
            if tok.startswith("--force"):
                force = True
        elif tok.startswith("-") and len(tok) > 1:
            body = tok[1:]
            if "r" in body or "R" in body:
                rec = True
            if "f" in body:
                force = True
    return rec, force


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}}))
    sys.stderr.write(reason + "\n")
    sys.exit(0)


def main():
    try:
        cmd = read_command()
    except Exception:
        sys.exit(0)  # fail open

    if not cmd or "rm" not in cmd:
        sys.exit(0)

    for m in RM_SEG.finditer(cmd):
        args = m.group(1)
        rec, force = flags_of(args)
        if rec and force:
            targets = " ".join(t for t in args.split()
                               if not t.startswith("-")) or "(none parsed)"
            deny(
                "BLOCKED - recursive-force delete. The agent never runs `rm -rf`.\n"
                f"  command : rm {args.strip()}\n"
                f"  targets : {targets}\n"
                "Hand this to Kevin with the reason it's needed; he runs it "
                "himself (or via the `! ` prompt prefix).\n"
                "To loosen this guard, edit scripts/hooks/rm-rf-guard.py."
            )

    sys.exit(0)


if __name__ == "__main__":
    main()
