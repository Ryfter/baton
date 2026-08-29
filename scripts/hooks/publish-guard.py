#!/usr/bin/env python3
"""PreToolUse guard: stop accidental publication of third-party/private material.

Enforces the `publishing-guard` rule mechanically instead of hoping an agent
remembers it. Two blocks:

  1. `git add -A|.|-u` / `git commit -a` while unreviewed untracked files exist.
     Blanket staging is how someone else's files get committed by accident.
  2. `git push` whose pending commits carry risky file types into a PUBLIC repo.

Fast path first: anything that is not a git add/commit/push exits immediately,
so the per-Bash-call cost is a regex match. Fails OPEN on any internal error —
a broken guard must never wedge the session.
"""
import json, os, re, subprocess, sys, time

CACHE = os.path.expanduser("~/.baton/cache/repo-visibility.json")
CACHE_TTL = 86400

# Extensions that are usually somebody else's work or carry real data.
RISKY_EXT = re.compile(r"\.(docx|doc|pptx|pdf|eml|msg|mbox|epub|mp4|mov|mp3|m4a|wav)$", re.I)

BLANKET_ADD = re.compile(r"\bgit\s+(-C\s+\S+\s+)?add\s+(-A\b|--all\b|-u\b|\.(?:\s|$))")
COMMIT_ALL  = re.compile(r"\bgit\s+(-C\s+\S+\s+)?commit\b[^|;&]*\s-(?:[a-zA-Z]*a[a-zA-Z]*)\b")
GIT_PUSH    = re.compile(r"\bgit\s+(-C\s+\S+\s+)?push\b")
DASH_C      = re.compile(r"\bgit\s+-C\s+(\S+)")

def sh(args, cwd=None, timeout=8):
    try:
        p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception:
        return 1, "", ""

def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}}))
    sys.stderr.write(reason + "\n")
    sys.exit(2)

def visibility(cwd):
    """Cached `gh repo view` — network call, so never on the hot path."""
    rc, url, _ = sh(["git", "remote", "get-url", "origin"], cwd)
    if rc or not url:
        return None, None
    slug = re.sub(r"\.git$", "", re.sub(r".*github\.com[:/]", "", url))
    try:
        cache = json.load(open(CACHE)) if os.path.exists(CACHE) else {}
    except Exception:
        cache = {}
    hit = cache.get(slug)
    if hit and time.time() - hit.get("t", 0) < CACHE_TTL:
        return slug, hit.get("v")
    rc, out, _ = sh(["gh", "repo", "view", slug, "--json", "visibility",
                     "-q", ".visibility"], cwd, timeout=10)
    vis = out if rc == 0 and out else None
    if vis:
        cache[slug] = {"v": vis, "t": time.time()}
        try:
            os.makedirs(os.path.dirname(CACHE), exist_ok=True)
            json.dump(cache, open(CACHE, "w"))
        except Exception:
            pass
    return slug, vis

def main():
    try:
        evt = json.load(sys.stdin)
    except Exception:
        return 0
    if evt.get("tool_name") != "Bash":
        return 0
    cmd = (evt.get("tool_input") or {}).get("command") or ""
    if "git" not in cmd:                      # fast path: ~every non-git call
        return 0

    m = DASH_C.search(cmd)
    cwd = m.group(1).strip("'\"") if m else (evt.get("cwd") or os.getcwd())
    if not os.path.isdir(cwd):
        return 0
    if sh(["git", "rev-parse", "--is-inside-work-tree"], cwd)[0] != 0:
        return 0

    # --- 1. blanket staging with untracked files present -------------------
    if BLANKET_ADD.search(cmd) or COMMIT_ALL.search(cmd):
        rc, out, _ = sh(["git", "status", "--porcelain"], cwd)
        untracked = [l[3:] for l in out.splitlines() if l.startswith("??")]
        if untracked:
            shown = "\n".join("  " + u for u in untracked[:12])
            more = f"\n  ... and {len(untracked)-12} more" if len(untracked) > 12 else ""
            deny(
                "BLOCKED by publish-guard: blanket staging with unreviewed untracked "
                f"files in {cwd}.\n\nUntracked:\n{shown}{more}\n\n"
                "Untracked files are not automatically the user's own work — this is how "
                "third-party or private material gets committed by accident.\n"
                "Stage explicit paths instead (git add -- <path> ...), or .gitignore what "
                "should not ship. See ~/.claude/rules/publishing-guard.md")

    # --- 2. pushing risky file types to a PUBLIC repo ----------------------
    if GIT_PUSH.search(cmd):
        rc, out, _ = sh(["git", "rev-parse", "--abbrev-ref", "@{u}"], cwd)
        rng = f"{out}..HEAD" if rc == 0 and out else "origin/HEAD..HEAD"
        rc, files, _ = sh(["git", "diff", "--name-only", rng], cwd)
        if rc != 0 or not files:
            return 0
        risky = [f for f in files.splitlines() if RISKY_EXT.search(f)]
        if not risky:
            return 0
        slug, vis = visibility(cwd)
        if vis != "PUBLIC":
            return 0
        shown = "\n".join("  " + r for r in risky[:12])
        more = f"\n  ... and {len(risky)-12} more" if len(risky) > 12 else ""
        deny(
            f"BLOCKED by publish-guard: pushing to PUBLIC repo {slug} with file types "
            f"that are commonly someone else's work or carry real data.\n\n"
            f"{shown}{more}\n\n"
            "Publishing is one-way: git history and GitHub caches retain these even "
            "after a later delete.\nConfirm you hold the rights and that they contain no "
            "personal data. To proceed deliberately, remove them from the commit or have "
            "the user approve explicitly.\nSee ~/.claude/rules/publishing-guard.md")
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)          # fail open, always
