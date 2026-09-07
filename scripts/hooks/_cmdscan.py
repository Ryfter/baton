#!/usr/bin/env python3
"""Shared command-line scanning primitives for the Bash PreToolUse guards.

`rm-rf-guard.py` and `publish-guard.py` both need the same lossy parse:

  * split a compound command into independently-scannable segments
    (statement / substitution boundaries: ; | & && || newline ( ) ` { } $( ),
  * drop quotes and backslash escapes -- safe, because guards never execute; a
    guard reading `\\rm` / `rm "-rf"` as the token `rm -rf` is the point,
  * strip leading env-assignments (`FOO=1`) and wrapper commands
    (`sudo`, `env`, `timeout N`, `sh -c`, `doas`, `setsid`, ...) so the *real*
    command head is exposed for inspection.

Kept small and stdlib-only; imported by the co-located hook scripts (their own
directory is always on sys.path[0], in the repo and in the plugin cache).
"""
import re

# Statement / substitution boundaries -- each side is scanned on its own.
BOUNDARY = re.compile(r"\n|\|\||&&|\$\(|[;|&()`{}]")

# Command prefixes that delegate to whatever command follows them.
WRAPPERS = {
    "sudo", "doas", "command", "builtin", "exec", "eval", "env",
    "nice", "nohup", "time", "timeout", "gtimeout", "stdbuf", "xargs",
    "setsid", "unshare", "chroot", "setarch", "ionice", "proot", "catchsegv",
    "bash", "sh", "zsh", "dash", "ksh", "fish",
    "then", "do", "else", "if", "elif", "while", "until", "!",
}
# Wrappers whose first *non-flag* argument is a path/target, not the command
# (`chroot NEWROOT CMD ...`). Flag-driven sandboxers like proot are not here.
PATHARG_WRAPPERS = {"chroot"}

ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*=")
DURATION = re.compile(r"^\d+(\.\d+)?[smhdSMHD]?$")


def unquote(s):
    s = re.sub(r"\\(.)", r"\1", s)                 # \x -> x  (\rm, \ , \; ...)
    return s.replace('"', "").replace("'", "")


def segments(cmd):
    """Yield non-empty, stripped segments of a compound command."""
    for seg in BOUNDARY.split(cmd):
        seg = seg.strip()
        if seg:
            yield seg


def basename(tok):
    return tok.lstrip("\\").rsplit("/", 1)[-1]


def strip_prefix(tokens, start, heads):
    """Index of the real command head in ``tokens``, at or after ``start``,
    past env-assignments and wrapper commands (with their flags, an optional
    flag value, `timeout` durations, and one `chroot` path arg).

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
                # another wrapper -- then the flag was a bare toggle. This skips
                # `-s KILL`, `-u kev`, `-n 10` without ever swallowing `rm`.
                if (i < len(tokens)
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
