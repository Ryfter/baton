#!/usr/bin/env python3
# baton-health-canary.py -- SessionStart loud check for cross-platform control-plane breakage.
# Writes ~/.baton/logs/health-canary.log and prints CRITICAL lines to stderr so they show up.
# Exit 0 always (never block the session); the point is visibility, not gating.
#
# Ported from baton-health-canary.ps1 (2026-09-07): removes pwsh from the
# SessionStart hot path. The pwsh *probe* stays -- it is the thing being checked.

import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def iso_utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


def probe_pwsh(issues):
    # 1) pwsh must start.
    try:
        if shutil.which("pwsh") is None:
            issues.append(
                "pwsh not on PATH. Baton hooks that shell to pwsh are dead. "
                "Re-apply DOTNET_ROOT pin on Homebrew pwsh."
            )
            return
        proc = subprocess.run(
            ["pwsh", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=8,
        )
        ver = proc.stdout.decode("utf-8", "replace").strip()
        if proc.returncode != 0 or not ver:
            issues.append(
                "pwsh probe failed (exit=%d). Baton hooks that shell to pwsh are dead. "
                "Re-apply DOTNET_ROOT pin on Homebrew pwsh." % proc.returncode
            )
    except Exception as e:
        issues.append("pwsh probe threw: %s. Baton hooks that shell to pwsh are dead." % e)


def _iter_strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _iter_strings(v)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            yield from _iter_strings(v)


def check_settings(issues):
    # 2) Parse Claude settings as JSON; flag real Windows path separators in string
    #    values (/Users/...\<name-char>). Test each parsed string -- NOT a JSON
    #    re-dump, where a real "\" is escaped to "\\" and never matches.
    win_sep = re.compile(r'/Users/[^\\"]*\\[A-Za-z]')
    for sp in (Path.home() / ".claude" / "settings.json",
               Path.home() / ".claude" / "settings.local.json"):
        if not sp.is_file():
            continue
        try:
            obj = json.loads(sp.read_text(encoding="utf-8"))
        except Exception as e:
            issues.append("Could not parse %s as JSON: %s" % (sp, e))
            continue
        if any(win_sep.search(s) for s in _iter_strings(obj)):
            issues.append(
                "Windows-style path separators in %s -- hooks/config will not resolve on macOS." % sp
            )


def check_guard(issues):
    # 3) Dead-pwsh fail-open wrapper present in source.
    guard = Path(__file__).resolve().parent / "pwsh-guard.py"
    if not guard.is_file():
        issues.append("Missing %s -- dead-pwsh fail-open not installed in source." % guard)


def main() -> int:
    log_dir = Path.home() / ".baton" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log = log_dir / "health-canary.log"

    ts = iso_utc_now()
    issues = []
    probe_pwsh(issues)
    check_settings(issues)
    check_guard(issues)

    line = ("[%s] OK pwsh+paths" % ts if not issues
            else "[%s] CRITICAL %d issue(s): %s" % (ts, len(issues), " | ".join(issues)))
    try:
        with open(log, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass

    for issue in issues:
        sys.stderr.write("BATON HEALTH CRITICAL: %s\n" % issue)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
