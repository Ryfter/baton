#!/usr/bin/env python3
"""Run a Baton hook, but never let a broken pwsh break the session.

Why Python: the guard must start when pwsh cannot. A PowerShell guard is
launched BY pwsh, so it dies with the thing it guards (verified: exit 131,
same fatal error). bash would work on macOS/Linux but is absent from a stock
Windows box. Python is present on both, so one implementation covers Firefly
(Windows) and droid (macOS).

Usage from hooks.json:
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/pwsh-guard.py" \
          "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/<real-hook>.ps1"

One pwsh spawn per call. Hook stdin is forwarded intact; hook stdout/stderr
pass through unchanged unless the runtime itself failed.

Fail-open is absolute: a hung pwsh (timeout), a decode error on odd output,
any non-zero exit (every wrapped hook is advisory / "exit 0 always" by
design), or an unhandled exception -- all log a line and return 0.
"""
import os, sys, subprocess, datetime, shutil

FATAL = (
    "You must install .NET",
    "FileLoadException",
    "An error has occurred that was not properly handled",
    "Unhandled exception.",
)
TIMEOUT_S = 60

def note(msg):
    try:
        d = os.path.join(os.path.expanduser("~"), ".baton", "logs")
        os.makedirs(d, exist_ok=True)
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(os.path.join(d, "hook-guard.log"), "a", encoding="utf-8") as f:
            f.write("[%s] %s\n" % (ts, msg))
    except Exception:
        pass

def main():
    if len(sys.argv) < 2:
        return 0
    hook = sys.argv[1]
    name = os.path.basename(hook)

    exe = shutil.which("pwsh") or shutil.which("pwsh-preview") or shutil.which("powershell")
    if not exe:
        note("pwsh not on PATH; skipped %s" % name)
        return 0

    try:
        payload = sys.stdin.read() if not sys.stdin.isatty() else ""
    except Exception:
        payload = ""
    try:
        p = subprocess.run(
            [exe, "-NoProfile", "-File", hook] + sys.argv[2:],
            input=payload, capture_output=True, text=True,
            errors="replace", timeout=TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        note("pwsh hook timed out after %ss; skipped %s" % (TIMEOUT_S, name))
        return 0
    except OSError as e:
        note("pwsh launch failed (%s); skipped %s" % (type(e).__name__, name))
        return 0

    blob = (p.stdout or "") + (p.stderr or "")
    if any(sig in blob for sig in FATAL):
        note("pwsh runtime failure; skipped %s (rc=%s)" % (name, p.returncode))
        return 0
    if p.returncode != 0:
        # every pwsh-guard-wrapped hook is advisory / "exit 0 always" by
        # design, so any non-zero is a runtime failure, not a hook verdict.
        note("pwsh hook exited %s; skipped %s" % (p.returncode, name))
        return 0

    if p.stdout: sys.stdout.write(p.stdout)
    if p.stderr: sys.stderr.write(p.stderr)
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)          # fail open, always
