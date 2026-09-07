#!/usr/bin/env python3
"""Shared command-line scanning primitives for the Bash PreToolUse guards.

`rm-rf-guard.py` and `publish-guard.py` both need the same lossy parse:

  * split a compound command into independently-scannable segments on shell
    operators (; | & && || newline ( ) ` { }) -- but ONLY when the operator is
    not inside single/double quotes, so `git commit -m 'a; b'` stays one
    segment,
  * drop the remaining quotes and backslash escapes -- safe, because guards
    never execute; a guard reading `\\rm` / `rm "-rf"` as the token `rm -rf`
    is the point,
  * strip leading env-assignments (`FOO=1`) and wrapper commands
    (`sudo`, `env`, `timeout N`, `sh -c`, `doas`, `setsid`, ...) so the *real*
    command head is exposed for inspection,
  * surface nested command strings (`sh -c '<cmd>'`, `eval <cmd>`) so a guard
    can re-scan them.

Kept small and stdlib-only; imported by the co-located hook scripts (their own
directory is put on sys.path[0] first, in the repo and in the plugin cache).
"""
import re

# Command prefixes that delegate to whatever command follows them.
WRAPPERS = {
    "sudo", "doas", "command", "builtin", "exec", "eval", "env",
    "nice", "nohup", "time", "timeout", "gtimeout", "stdbuf", "xargs",
    "setsid", "unshare", "chroot", "setarch", "linux32", "linux64",
    "ionice", "proot", "catchsegv", "nsenter", "script",
    "busybox", "coreutils", "toybox",
    "bash", "sh", "zsh", "dash", "ksh", "fish",
    "then", "do", "else", "if", "elif", "while", "until", "!",
}
# Wrappers whose first *non-flag* argument is a path/target, not the command
# (`chroot NEWROOT CMD ...`, `setarch ARCH CMD ...`). Flag-driven sandboxers
# like proot/nsenter are not here.
PATHARG_WRAPPERS = {"chroot", "setarch"}

# Flags that carry a full command string as their value (`sh -c '<cmd>'`).
CMDSTR_FLAGS = {"-c", "--command"}

ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*=")
DURATION = re.compile(r"^\d+(\.\d+)?[smhdSMHD]?$")

_OPS = set(";|&\n()`{}")


def unquote(s):
    s = re.sub(r"\\(.)", r"\1", s)                 # \x -> x  (\rm, \ , \; ...)
    return s.replace('"', "").replace("'", "")


def segments(cmd):
    """Yield non-empty, stripped segments split on shell operators that are
    NOT inside quotes. Segments are returned still-quoted -- the caller decides
    when to unquote (rm-rf-guard unquotes each segment; publish-guard shlexes)."""
    buf = []
    q = None                                       # None | "'" | '"'
    i, n = 0, len(cmd)
    while i < n:
        c = cmd[i]
        if q:
            buf.append(c)
            if c == q:
                q = None
            elif c == "\\" and q == '"' and i + 1 < n:
                buf.append(cmd[i + 1])
                i += 1
            i += 1
            continue
        if c in ("'", '"'):
            q = c
            buf.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:                # keep escape + escaped char
            buf.append(c)
            buf.append(cmd[i + 1])
            i += 2
            continue
        if c in _OPS:
            s = "".join(buf).strip()
            if s:
                yield s
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    s = "".join(buf).strip()
    if s:
        yield s


def basename(tok):
    return tok.lstrip("\\").rsplit("/", 1)[-1]


def nested_command_bodies(tokens):
    """Command strings carried as an argument: `-c '<cmd>'` / `--command=<cmd>`
    and everything after a bare `eval`. The caller re-scans each as a command."""
    out = []
    for idx, t in enumerate(tokens):
        if t in CMDSTR_FLAGS and idx + 1 < len(tokens):
            out.append(tokens[idx + 1])
        elif t.startswith("--command="):
            out.append(t.split("=", 1)[1])
        elif basename(t).lower() == "eval" and idx + 1 < len(tokens):
            out.append(" ".join(tokens[idx + 1:]))
    return out


def strip_prefix(tokens, start, heads):
    """Index of the real command head in ``tokens``, at or after ``start``,
    past env-assignments and wrapper commands (with their flags, an optional
    flag value, `timeout` durations, and one `chroot`/`setarch` path arg).

    ``heads`` is the set of command basenames the caller is hunting for (e.g.
    ``("rm",)`` / ``("git",)``); it only sharpens the "does this flag take a
    value?" heuristic. The return value may equal ``len(tokens)``.
    """
    heads = tuple(h.lower() for h in heads)

    def is_head(x):
        return basename(x).lower() in heads

    i = start
    while i < len(tokens):
        t = tokens[i]
        if ASSIGN.match(t):
            i += 1
            continue
        w = basename(t).lower()
        if w not in WRAPPERS:
            break
        i += 1
        while i < len(tokens):                      # the wrapper's own args
            ti = tokens[i]
            if ti.startswith("-"):
                i += 1
                # A flag consumes the next token as its value unless that token
                # is itself a flag, the command we're hunting (`env -i rm`), or
                # another wrapper -- then the flag was a bare toggle. A `--x=y`
                # flag is self-contained and consumes nothing.
                if ("=" not in ti
                        and i < len(tokens)
                        and not tokens[i].startswith("-")
                        and not is_head(tokens[i])
                        and basename(tokens[i]).lower() not in WRAPPERS):
                    i += 1
            elif DURATION.match(ti):                # `timeout 5 rm ...`
                i += 1
            else:
                break
        if (w in PATHARG_WRAPPERS and i < len(tokens)
                and not tokens[i].startswith("-") and not is_head(tokens[i])):
            i += 1                                  # `chroot NEWROOT rm ...`
    return i
