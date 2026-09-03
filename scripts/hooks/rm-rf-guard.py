#!/usr/bin/env python3
"""PreToolUse:Bash guard -- the agent never runs a recursive-force delete.

`rm -rf` in any spelling is blocked unconditionally, in any segment of a
compound command and behind common wrappers:

  spellings : -rf / -fr / -Rf / -RF / -r -f / --recursive --force / clustered
              (-vrf) ; `--` ends option scanning (GNU): `rm -r -- -f` is NOT force.
  names     : rm, /bin/rm, ./rm, \\rm, RM  (case-insensitive -- APFS resolves it)
  wrappers  : sudo [flags], command, builtin, exec, eval, env [VAR=v|-i],
              nice, nohup, time, timeout N, stdbuf, xargs [-I x|-n N],
              bash|sh|zsh -c, and VAR=val prefixes
  nesting   : $(...) , `...` , (...) , { ...; } , if/then/while/until/do , and
              statement boundaries ; && || | & newline
  find      : find ... -exec / -execdir rm -rf {} \\;

The agent must hand Kevin the command, the target paths, and the reason it's
needed; Kevin runs it himself (or via the `! ` prompt prefix).

Design (matches publish-guard.py house style):
  - Fails OPEN on any internal error -- a broken guard must never wedge a
    session. The ENTIRE body is wrapped; only an explicit deny() is non-open.
  - Detection is quote-lossy on purpose: we never execute, so collapsing quotes
    and backslashes to read `rm "-rf"` / `\\rm` as plain tokens is safe.
  - Emits the PreToolUse deny protocol as JSON on stdout, reason on stderr.

To loosen (e.g. allow deletes under a scratch dir), add a path allow-list
check just before deny() in main().
"""
import json
import re
import sys

# Statement / substitution boundaries -- each side is scanned on its own.
_BOUNDARY = re.compile(r"\n|\|\||&&|\$\(|[;|&()`{}]")

# Command prefixes that delegate to whatever command follows them.
_WRAPPERS = {
    "sudo", "command", "builtin", "exec", "eval", "env", "nice", "nohup",
    "time", "timeout", "gtimeout", "stdbuf", "xargs",
    "bash", "sh", "zsh", "dash", "ksh", "fish",
    "then", "do", "else", "if", "elif", "while", "until", "!",
}
_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*=")
_DURATION = re.compile(r"^\d+(\.\d+)?[smhdSMHD]?$")


def read_command():
    data = json.load(sys.stdin)
    ti = data.get("tool_input") or {}
    return ti.get("command", "") if isinstance(ti, dict) else ""


def _unquote(s):
    s = re.sub(r"\\(.)", r"\1", s)                 # \x -> x   (\rm, \ , \; ...)
    return s.replace('"', "").replace("'", "")


def _basename(tok):
    return tok.lstrip("\\").rsplit("/", 1)[-1]


def _is_rm(tok):
    return _basename(tok).lower() == "rm"


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


def scan_segment(seg):
    """Target string if this segment invokes `rm` recursively+forced, else None."""
    tokens = seg.split()
    i = 0
    while i < len(tokens):                      # strip assignments + wrappers
        t = tokens[i]
        if _ASSIGN.match(t):
            i += 1
            continue
        if _basename(t).lower() in _WRAPPERS:
            i += 1
            while i < len(tokens):              # ... and the wrapper's own args
                ti = tokens[i]
                if ti.startswith("-"):
                    i += 1
                    # a flag may consume the next token as its value -- skip it
                    # only if that still lands us on the real command
                    if (i + 1 < len(tokens)
                            and not tokens[i].startswith("-")
                            and not _is_rm(tokens[i])
                            and _basename(tokens[i]).lower() not in _WRAPPERS
                            and (_is_rm(tokens[i + 1])
                                 or tokens[i + 1].startswith("-")
                                 or _basename(tokens[i + 1]).lower() in _WRAPPERS)):
                        i += 1
                elif _DURATION.match(ti):       # `timeout 5 rm ...`
                    i += 1
                else:
                    break
            continue
        break
    if i < len(tokens) and _is_rm(tokens[i]):
        hit = _check_rm(tokens[i + 1:])
        if hit is not None:
            return hit
    for j, t in enumerate(tokens):             # find ... -exec rm -rf {} \;
        if t in ("-exec", "-execdir") and j + 1 < len(tokens) and _is_rm(tokens[j + 1]):
            hit = _check_rm(tokens[j + 2:])
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
    for seg in _BOUNDARY.split(_unquote(cmd)):
        seg = seg.strip()
        if not seg or "rm" not in seg.lower():
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
