#!/usr/bin/env python3
"""PreToolUse guard: stop accidental publication of third-party/private material.

Enforces the `publishing-guard` rule mechanically instead of hoping an agent
remembers it. Two blocks:

  1. `git add -A|--all|-u|.` / `git commit -a|--all` while unreviewed untracked
     files exist. Blanket staging is how someone else's files get committed by
     accident.
  2. `git push` whose pending commits carry risky file types into a PUBLIC repo.

Fast path first: anything without the literal word `git` exits immediately, so
the per-Bash-call cost is a substring check. The `git` command line is then
*tokenized* (shlex per segment, lossy fallback) rather than regex-matched, so
`git add -- .`, `git add -v --all`, `git commit --all`, quoted `-C <path>`, and
`echo git add -A` are all read correctly. Segment-split / wrapper-strip come
from _cmdscan.py, shared with rm-rf-guard.py.

Fails OPEN on any internal error -- a broken guard must never wedge the session.
"""
import json, os, re, shlex, subprocess, sys, time

import _cmdscan as cs

CACHE = os.path.expanduser("~/.baton/cache/repo-visibility.json")
CACHE_TTL = 86400

# Extensions that are usually somebody else's work or carry real data.
RISKY_EXT = re.compile(r"\.(docx|doc|pptx|pdf|eml|msg|mbox|epub|mp4|mov|mp3|m4a|wav)$", re.I)

# `git` global options that consume the following token as their value.
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}

# `git add` args that stage broadly (long forms + the `.` / `:/` pathspecs).
ADD_BLANKET_LONG = {"-A", "--all", "-u", "--update", "--no-ignore-removal", "--ignore-removal"}
ADD_BLANKET_PATHSPEC = {".", "./", "*", ":/", ":/.", ":/*"}


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


def _git_invocations(cmd):
    """Yield (subcommand, arg_tokens, cwd_override) for each real `git` call.

    A segment whose head token (past assignments + wrappers) is not `git` is
    skipped -- that kills the `echo git add -A` false positive.
    """
    for seg in cs.BOUNDARY.split(cmd):
        seg = seg.strip()
        if not seg:
            continue
        try:
            tokens = shlex.split(seg)
        except ValueError:
            tokens = cs.unquote(seg).split()
        i = cs.strip_prefix(tokens, 0, heads=("git",))
        if i >= len(tokens) or cs.basename(tokens[i]).lower() != "git":
            continue
        j = i + 1
        cwd_override = None
        while j < len(tokens) and tokens[j].startswith("-"):
            opt = tokens[j]
            if "=" in opt:
                if opt.startswith("-C"):
                    cwd_override = opt.split("=", 1)[1]
                j += 1
            elif opt in GIT_VALUE_OPTS:
                if opt == "-C" and j + 1 < len(tokens):
                    cwd_override = tokens[j + 1]
                j += 2
            else:
                j += 1                            # bare global flag (--no-pager, --bare, -p)
        if j < len(tokens):
            yield tokens[j].lower(), tokens[j + 1:], cwd_override


def _is_blanket_add(args):
    after_ddash = False
    for a in args:
        if a == "--":
            after_ddash = True
            continue
        if a in ADD_BLANKET_LONG:
            return True
        if a in ADD_BLANKET_PATHSPEC:
            return True
        if not after_ddash and a.startswith("-") and not a.startswith("--") \
                and ("A" in a[1:] or "u" in a[1:]):
            return True                           # clustered: -Av, -uv
    return False


def _is_commit_all(args):
    for a in args:
        if a == "--":
            break
        if a == "--all":
            return True
        if a.startswith("-") and not a.startswith("--") and "a" in a[1:]:
            return True                           # -a, -am, -va
    return False


def _blanket_deny(cwd):
    rc, out, _ = sh(["git", "status", "--porcelain"], cwd)
    untracked = [l[3:] for l in out.splitlines() if l.startswith("??")]
    if not untracked:
        return
    shown = "\n".join("  " + u for u in untracked[:12])
    more = f"\n  ... and {len(untracked)-12} more" if len(untracked) > 12 else ""
    deny(
        "BLOCKED by publish-guard: blanket staging with unreviewed untracked "
        f"files in {cwd}.\n\nUntracked:\n{shown}{more}\n\n"
        "Untracked files are not automatically the user's own work — this is how "
        "third-party or private material gets committed by accident.\n"
        "Stage explicit paths instead (git add -- <path> ...), or .gitignore what "
        "should not ship. See ~/.claude/rules/publishing-guard.md")


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


def _push_deny(cwd):
    rc, out, _ = sh(["git", "rev-parse", "--abbrev-ref", "@{u}"], cwd)
    rng = f"{out}..HEAD" if rc == 0 and out else "origin/HEAD..HEAD"
    rc, files, _ = sh(["git", "diff", "--name-only", rng], cwd)
    if rc != 0 or not files:
        return
    risky = [f for f in files.splitlines() if RISKY_EXT.search(f)]
    if not risky:
        return
    slug, vis = visibility(cwd)
    if vis != "PUBLIC":
        return
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
    default_cwd = evt.get("cwd") or os.getcwd()

    for sub, args, cwd_override in _git_invocations(cmd):
        if sub not in ("add", "stage", "commit", "push"):
            continue
        cwd = (cwd_override or "").strip("'\"") or default_cwd
        if not os.path.isdir(cwd):
            continue
        if sh(["git", "rev-parse", "--is-inside-work-tree"], cwd)[0] != 0:
            continue
        if sub in ("add", "stage") and _is_blanket_add(args):
            _blanket_deny(cwd)
        elif sub == "commit" and _is_commit_all(args):
            _blanket_deny(cwd)
        elif sub == "push":
            _push_deny(cwd)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)          # fail open, always
