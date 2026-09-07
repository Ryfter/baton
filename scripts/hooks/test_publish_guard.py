#!/usr/bin/env python3
"""Probe table for publish-guard.py's blanket-staging detector (Grok review #12).

The regex version matched `git add`/`git commit` positionally and missed
`git add -- .`, `git add -v --all`, `git commit --all`, quoted `-C` paths, and
false-positived on `echo git add -A`. This checks the tokenized replacement as a
pure function -- the end-to-end deny also needs untracked files present, which is
environmental. Run: python3 scripts/hooks/test_publish_guard.py  (0 = all pass).
"""
import importlib.util
import pathlib
import sys

GUARD = pathlib.Path(__file__).with_name("publish-guard.py")
_spec = importlib.util.spec_from_file_location("publish_guard", GUARD)
pg = importlib.util.module_from_spec(_spec)
sys.path.insert(0, str(GUARD.parent))
_spec.loader.exec_module(pg)


def _blanket(cmd):
    for sub, args, _cwd in pg._git_invocations(cmd):
        if sub in ("add", "stage") and pg._is_blanket_add(args):
            return True
        if sub == "commit" and pg._is_commit_all(args):
            return True
    return False


BLANKET = [
    "git add -A",
    "git add .",
    "git add --all",
    "git add -u",
    "git add -- .",                       # -- before the pathspec
    "git add -v --all",                   # flag before the blanket flag
    "git add -Av",                        # clustered short flags
    "git stage -A",                       # stage is an add alias
    "git commit -a -m x",
    "git commit -am x",
    "git commit -va -m x",
    "git commit --all -m x",              # long form
    "git -C '/path with space' add -A",   # quoted global -C arg
    "sudo git add -A",                    # behind a wrapper
    "foo && git add -A",                  # second segment of a compound
    "git add -A -- src/",                 # blanket flag before the -- pathspec sep
]

NOT_BLANKET = [
    "git add -- src/foo.py",             # explicit path after --
    "git add -- -A",                     # a file literally named -A, after --
    "git add --ignore-removal foo.txt",  # --ignore-removal is --no-all, not blanket
    "git add src/",
    "git add -p",
    "git commit -m 'amend the docs'",    # 'a' inside the message, not a flag
    "git commit -m x",
    "git commit -p",
    "echo git add -A",                   # printed, not run -- the FP that bit us
    "printf 'git commit -a'",
    "git status",
    "git push origin main",
    "git diff --stat",
]


def main():
    bad = []
    for c in BLANKET:
        if not _blanket(c):
            bad.append(("should FLAG, passed", c))
    for c in NOT_BLANKET:
        if _blanket(c):
            bad.append(("should PASS, flagged", c))
    # H3 (Opus): the tokenizer is case-insensitive, so `GIT add -A` must still
    # be seen as blanket -- main()'s fast-path guard must lower-case too.
    if not _blanket("GIT add -A"):
        bad.append(("case-folded git not recognised", "GIT add -A"))
    src = GUARD.read_text()
    if 'if "git" not in cmd.lower()' not in src and 'if "git" not in cmd:' in src:
        bad.append(("main() fast path is case-sensitive", 'if "git" not in cmd'))
    for kind, c in bad:
        print(f"FAIL  {kind}: {c!r}")
    total = len(BLANKET) + len(NOT_BLANKET)
    print(f"\n{total - len(bad)}/{total} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
