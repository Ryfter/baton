# Concurrent-session git safety — design

**Date:** 2026-08-29
**Issues:** #210, #211 (related: #203)
**Status:** design only — nothing here is implemented

## Summary

Two agent sessions working the same repo damaged in-progress git state twice in
one day. A third symptom — a merge that git did not record as a merge — is
probably a *consequence* of the same collision rather than an independent bug.

This spec records the evidence, the likely single root cause, and the proposed
work in priority order. No code was written for it.

## Problem 1 — merge-titled commits with one parent (#210)

`b4e6b28 merge(docs/research-instruments-design): publish-guard and research
instruments` has **one parent** (`db2e6c7`). The content landed; the ancestry
did not.

```
$ git log -1 --format='%h %P' b4e6b28
b4e6b28 db2e6c7de2035028155c0c3448f4d7f95eb9bd91      # one parent
$ git log --oneline master..docs/research-instruments-design | wc -l
12
```

Consequences: git still saw all 12 branch commits as outstanding,
`git branch --merged master` omitted the branch, and any later merge would
re-fight three already-settled conflicts.

Resolved in `4a0e367` with `git merge -s ours` — zero content change — after
`git merge-tree --write-tree` proved master already subsumed every branch
change. The would-be merge diff was 10 lines of conflict markers and 0
deletions; all three conflicts were cases where master was the better side.

**Why it matters:** an agent asked to "merge branch X" that checks only for a
merge-shaped commit reports success on a repo where the merge did not happen.
The subject line lies; `%P` tells the truth.

**Known so far:** no `--squash` appears anywhere in `scripts/`. The only two
merge sites are `scripts/run-backlog.ps1` and `scripts/fleet-orchestrate.ps1`.
The commit is authored as `Kevin Rank <25063575+Ryfter@users.noreply.github.com>`,
the identity an interactive agent session commits under. Whether either script
can emit this shape is **not yet traced** — that is an open task, not a finding.

## Problem 2 — concurrent sessions corrupt in-progress state (#211)

**(a) A reset destroyed a merge in flight.** One session held a
`git merge --no-commit` with hand-resolved conflicts staged. Another session ran
a `reset`, wiping `MERGE_HEAD` and every staged resolution.

```
db2e6c7 HEAD@{0}: merge worktree/brave-cloud-a808
7f5c0a3 HEAD@{1}: reset: moving to HEAD          <- destroyed the in-flight merge
7f5c0a3 HEAD@{2}: commit: fix(hooks): restore pwsh-guard...
```

The committed work survived; the merge did not, and the resolutions had to be
re-derived from notes.

**(b) A squash landed mid-wait.** While session A waited for the repo to go
idle, session B committed the same merge's content as the single-parent commit
in Problem 1. Both sessions were solving the same problem, unaware of each other.

**The mitigation in use did not prevent either.** An idle-watch poller (wait for
HEAD stable + tree clean for 10 minutes) helped but is advisory, one-directional,
and races. Session B could not see that session A was mid-merge; session A could
only observe B after the damage.

## Root cause hypothesis

**These are likely one problem, not two.** A session that runs
`git merge --no-commit`, loses `MERGE_HEAD` to a concurrent reset, then commits
the staged tree produces exactly a merge-titled single-parent commit — which is
the failure in Problem 1 and the damage in Problem 2(a).

So **#211 is probably the cause and #210 the symptom.** Fixing #211 may close
both. Keep #210's assertion anyway as a cheap backstop.

## Proposed work, ordered by value

1. **Refuse destructive git ops when another session holds in-progress state.**
   `reset`, `checkout -f`, `merge --abort`, `stash` hard-fail if
   `.git/MERGE_HEAD`, `.git/rebase-merge`, or `.git/rebase-apply` exists and was
   not created by the current session. Small PreToolUse guard; highest payoff.
2. **Repo lock carrying owner session id**, so a session sees *who* holds the
   repo instead of polling for quiet. Must expire, so a dead session cannot
   wedge the repo.
3. **Push mutating agents into worktrees.** Baton already has the machinery;
   separate worktrees make most of this collision class structurally impossible.
   #203 (parallel workers colliding on `:3000`) is the same "parallel agents
   share an unowned resource" family — two instances now, which argues for the
   structural fix over per-resource patches.
4. **Assert merge subjects imply merge shape:** a commit whose subject starts
   `merge(` / `merge:` must have >1 parent. Pre-push or CI.
5. **After an intentional squash, run `git merge -s ours`** so ancestry is
   recorded and the branch stops re-conflicting.
6. **Open question to decide:** is running concurrent sessions against one repo
   supported at all? Today it is neither supported nor prevented — that
   ambiguity is itself the hazard.

## Technique worth keeping

`git merge-tree --write-tree <a> <b>` answers "is any work actually missing?"
entirely in memory — no files touched, no index, nothing to abort. It is the
safe way to audit a suspect merge, and the only reason this was caught.
