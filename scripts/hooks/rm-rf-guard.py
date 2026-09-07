#!/usr/bin/env python3
"""PreToolUse:Bash guard -- the agent never runs a recursive-force delete.

`rm -rf` in any spelling is blocked unconditionally, in any segment of a
compound command and behind common wrappers:

  spellings : -rf / -fr / -Rf / -RF / -r -f / --recursive --force / clustered
              (-vrf) ; `--` ends option scanning (GNU): `rm -r -- -f` is NOT force.
  names     : rm, /bin/rm, ./rm, \\rm, RM  (case-insensitive -- APFS resolves it)
  wrappers  : sudo/doas [flags], command, builtin, exec, eval, env [VAR=v|-i],
              nice, nohup, time, timeout N, stdbuf, xargs [-I x|-n N],
              setsid, unshare, chroot NEWROOT, bash|sh|zsh -c, and VAR=val prefixes
  nesting   : $(...) , `...` , (...) , { ...; } , if/then/while/until/do , and
              statement boundaries ; && || | & newline
  find      : find ... -exec / -execdir [wrapper ...] rm -rf {} \\;

The agent must hand Kevin the command, the target paths, and the reason it's
needed; Kevin runs it himself (or via the `! ` prompt prefix).

Design (matches publish-guard.py house style):
  - Fails OPEN on any internal error -- a broken guard must never wedge a
    session. The ENTIRE body is wrapped; only an explicit deny() is non-open.
  - Detection is quote-lossy on purpose: we never execute, so collapsing quotes
    and backslashes to read `rm "-rf"` / `\\rm` as plain tokens is safe.
  - Emits the PreToolUse deny protocol as JSON on stdout, reason on stderr.
  - Segment-split / unquote / wrapper-strip live in _cmdscan.py, shared with
    publish-guard.py so the wrapper list is hardened in one place.

To loosen (e.g. allow deletes under a scratch dir), add a path allow-list
check just before deny() in main().
"""
import json
import sys

import _cmdscan as cs


def read_command():
    data = json.load(sys.stdin)
    ti = data.get("tool_input") or {}
    return ti.get("command", "") if isinstance(ti, dict) else ""


def flags_of(tokens):
    """(has_recursive, has_force) over flag tokens, stopping at a bare `--`."""
    rec = force = False
    for tok in tokens:
        if tok == "--":
            break
        if tok.startswith("--"):
            if tok.startswith("--r"):          # for rm, only --recursive is --r*
                rec = True
            if tok.startswith("--f"):          # for rm, only --force is --f*
                force = True
        elif tok.startswith("-") and len(tok) > 1:
            body = tok[1:].lower()
            if "r" in body:
                rec = True
            if "f" in body:
                force = True
    return rec, force


def _check_rm(arg_tokens):
    """Target string if these `rm` args are recursive AND force, else None."""
    rec, force = flags_of(arg_tokens)
    if rec and force:
        return " ".join(t for t in arg_tokens
                        if t != "--" and not t.startswith("-")) or "(none parsed)"
    return None


def _is_rm(tok):
    return cs.basename(tok).lower() == "rm"


def scan_segment(seg):
    """Target string if this segment invokes `rm` recursively+forced, else None."""
    tokens = seg.split()
    i = cs.strip_prefix(tokens, 0, heads=("rm",))
    if i < len(tokens) and _is_rm(tokens[i]):
        hit = _check_rm(tokens[i + 1:])
        if hit is not None:
            return hit
    for j, t in enumerate(tokens):            # find ... -exec [wrapper ...] rm -rf {} \;
        if t in ("-exec", "-execdir"):
            k = cs.strip_prefix(tokens, j + 1, heads=("rm",))
            if k < len(tokens) and _is_rm(tokens[k]):
                hit = _check_rm(tokens[k + 1:])
                if hit is not None:
                    return hit
    return None


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}}))
    sys.stderr.write(reason + "\n")
    sys.exit(2)          # JSON decision + exit 2 -- match publish-guard, cover hosts
                         # that honour only one of the two signals


def main():
    cmd = read_command()
    if not cmd or "rm" not in cmd.lower():
        return
    for seg in cs.segments(cs.unquote(cmd)):
        if "rm" not in seg.lower():
            continue
        targets = scan_segment(seg)
        if targets is not None:
            deny(
                "BLOCKED - recursive-force delete. The agent never runs `rm -rf`.\n"
                f"  segment : {seg}\n"
                f"  targets : {targets}\n"
                "Hand this to Kevin with the reason it's needed; he runs it "
                "himself (or via the `! ` prompt prefix).\n"
                "To loosen this guard, edit scripts/hooks/rm-rf-guard.py."
            )


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)  # fail open, always
