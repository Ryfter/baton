#!/usr/bin/env python3
"""Probe table for rm-rf-guard.py.  Run: python3 scripts/hooks/test_rm_rf_guard.py

The repo has no Python test harness yet, so this is a standalone, exit-code-
meaningful check (0 = all pass, 1 = a row regressed). Every BLOCK row must be
denied; every ALLOW row must pass through untouched. Rows are the bypasses and
false-positives found in the 2026-09-03 Grok review of commit b95359a.
"""
import json
import pathlib
import subprocess
import sys

GUARD = pathlib.Path(__file__).with_name("rm-rf-guard.py")

BLOCK = [
    "rm -rf /tmp/x",
    "rm -fr /tmp/x",
    "rm -Rf /tmp/x",
    "rm -RF /tmp/x",
    "rm -r -f /tmp/x",
    "rm -r --force /tmp/x",
    "rm --recursive --force /tmp/x",
    "rm -vrf /tmp/x",
    "rm -rf -- /tmp/x",
    "/bin/rm -rf /tmp/x",
    "./rm -rf /tmp/x",
    "\\rm -rf /tmp/x",
    "RM -rf /tmp/x",
    'rm "-rf" /tmp/x',
    "rm '-rf' /tmp/x",
    'rm -r "-f" /tmp/x',
    "FOO=1 rm -rf /tmp/x",
    "IFS= rm -rf /tmp/x",
    "command rm -rf /tmp/x",
    "builtin rm -rf /tmp/x",
    "env rm -rf /tmp/x",
    "env FOO=1 rm -rf /tmp/x",
    "env -i rm -rf /tmp/x",
    "nice rm -rf /tmp/x",
    "nice -n 10 rm -rf /tmp/x",
    "time rm -rf /tmp/x",
    "timeout 5 rm -rf /tmp/x",
    "timeout --signal=KILL 5s rm -rf /tmp/x",
    "sudo rm -rf /tmp/x",
    "sudo -n rm -rf /tmp/x",
    "sudo -u kev rm -rf /tmp/x",
    "sudo -- rm -rf /tmp/x",
    "bash -c 'rm -rf /tmp/x'",
    'sh -c "rm -rf /tmp/x"',
    "echo hi && rm -rf /tmp/x",
    "echo hi; rm -rf /tmp/x",
    "true || rm -rf /tmp/x",
    "( rm -rf /tmp/x )",
    "{ rm -rf /tmp/x; }",
    "if true; then rm -rf /tmp/x; fi",
    "$(rm -rf /tmp/x)",
    "`rm -rf /tmp/x`",
    "false\nrm -rf /tmp/x",
    "xargs rm -rf",
    "xargs -I {} rm -rf {}",
    "find . -exec rm -rf {} +",
    "find . -execdir rm -rf {} \\;",
    # H1 -- wrappers between -exec and rm (were bypassing: -exec only matched
    # rm as the immediate next token).
    "find . -exec sudo rm -rf {} +",
    "find . -exec env rm -rf {} \\;",
    "find . -exec timeout 5 rm -rf {} +",
    "find . -exec sh -c 'rm -rf \"$1\"' _ {} \\;",
    "find . -execdir bash -c 'rm -rf .' \\;",
    # M1 -- privilege / namespace wrappers.
    "doas rm -rf /tmp/x",
    "doas -u root rm -rf /tmp/x",
    "setsid rm -rf /tmp/x",
    "unshare -m rm -rf /tmp/x",
    "chroot /jail rm -rf /tmp/x",
]

ALLOW = [
    "rm -r /tmp/x",                       # recursive, not force
    "rm -f /tmp/x",                       # force, not recursive
    "rm /tmp/x",
    "rm -r -- -f",                        # -- ends options: -f is a filename
    "rmdir /tmp/x",
    "git rm -rf tracked/file",            # git rm is not the concern
    "grep -rf pattern /rm/path",          # -rf here is grep's flags
    "echo rm -rf /tmp/x",                 # printed, not executed
    "echo 'sudo rm -fr /var/data'",       # the false-positive that bit this session
    'git commit -m "harden rm -rf guard"',
    "python3 -c 'import shutil; shutil.rmtree(x)'",
    "find . -name '*.log' -exec cat {} +",       # -exec, but not rm
    "find . -exec ls -la {} \\;",
    "doas systemctl restart nginx",              # wrapper, but not rm
]


def run_guard(cmd):
    """Return (is_denied, returncode). BLOCK => JSON deny + exit 2; ALLOW => exit 0."""
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    p = subprocess.run([sys.executable, str(GUARD)], input=payload,
                       capture_output=True, text=True)
    return (bool(p.stdout.strip()) and '"deny"' in p.stdout), p.returncode


def main():
    bad = []
    for c in BLOCK:
        d, rc = run_guard(c)
        if not d:
            bad.append(("should BLOCK, allowed", c))
        elif rc != 2:
            bad.append((f"blocked but exit {rc}, want 2", c))
    for c in ALLOW:
        d, rc = run_guard(c)
        if d:
            bad.append(("should ALLOW, blocked", c))
        elif rc != 0:
            bad.append((f"allowed but exit {rc}, want 0", c))
    for kind, c in bad:
        print(f"FAIL  {kind}: {c!r}")
    total = len(BLOCK) + len(ALLOW)
    print(f"\n{total - len(bad)}/{total} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
