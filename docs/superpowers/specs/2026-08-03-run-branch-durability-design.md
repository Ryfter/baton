# Run-branch durability design

**Date:** 2026-08-03  
**Status:** approved direction; written-spec review pending  
**Issue:** [#157](https://github.com/Ryfter/baton/issues/157)

## Problem

`/baton:go --execute` stages the cumulative worktree so proof-by-diff includes
new files, but it never converts that staged tree into a commit. Baton then tells
the operator that the `baton/run-*` branch is retained for review and merge even
when the branch tip is identical to the base revision. The only copy of the work
may therefore live in one local worktree and disappear with that disk.

This is a broken durability promise on the golden path. It is already evidenced
by multiple halted runs whose branches were zero commits ahead while their
indexes held substantive changes.

## Chosen approach

Add a terminal archive operation beside the existing executor worktree
lifecycle, and invoke it from `fleet-go.ps1` only after the conductor has
returned a terminal result.

For every execute result except the existing pre-labor discard statuses
(`plan-rejected`, `plan-gate-degraded`, `plan-invalid`, and `plan-failed`):

1. Confirm the worktree is on the expected `baton/run-*` branch.
2. Stage the complete tree with `git add -A`.
3. If the index differs from `HEAD`, create one commit with an unmistakable
   machine/archive message naming the run and stating that the work is
   unreviewed and unmerged.
4. If the run branch is ahead of `base_sha` (whether because Baton just committed
   it or because an instrument committed earlier), push the exact branch to
   `origin`.
5. Verify that `origin` reports the same tip as the local branch.
6. Write the structured outcome to `<run-dir>/archive.json`, attach it to the
   CLI/JSON result as `archive`, and append a `## Durability` section to the
   returned report and `report.md`.

If no content or commits differ from the base, the archive operation succeeds as
`skipped-no-changes`; it creates no empty commit and performs no push.

## Failure contract

Commit, push, remote lookup, branch mismatch, or tree-verification failure must
never be presented as a successfully retained branch.

On archive failure:

- Leave the worktree and local run branch intact for recovery.
- Write `archive.json` with `status: failed` and the bounded Git error.
- Preserve the conductor's original terminal status as `work_status`.
- Set the public result to `status: failed` and
  `failure_category: archive-failed`, which uses the existing fail-loud exit-1
  contract rather than introducing a new top-level status enum.
- Add a `## Durability` failure section to the report naming the exact recovery
  location and reason.

The archive failure changes the overall run outcome because Baton's retained
branch promise includes off-disk durability. It does not rewrite the underlying
labor or acceptance verdict; those remain available in `work_status`, the task
evidence, and the report's existing sections.

## Archive result shape

`archive.json` and `result.archive` use schema 1:

```json
{
  "schema": 1,
  "status": "pushed",
  "branch": "baton/run-go-...",
  "base_sha": "...",
  "commit_sha": "...",
  "committed": true,
  "pushed": true,
  "remote": "origin",
  "remote_ref": "refs/heads/baton/run-go-...",
  "reason": "run branch archived to origin"
}
```

Allowed `status` values are `pushed`, `skipped-no-changes`, and `failed`.
Fields that do not apply remain empty/false rather than disappearing, keeping
the JSON shape stable for dashboard and automation consumers.

## Component boundaries

### `scripts/fleet-executor-lib.ps1`

Owns a focused `Publish-RunBranch` operation because it already owns
`New-RunWorktree`, `Get-RunDiff`, `Get-WorktreeTreeSha`, and
`Remove-RunWorktree`. The helper performs and verifies the Git transaction and
returns structured data; it does not decide the overall conductor status.

It also owns formatting the small durability report section from that structured
result, so CLI and `report.md` use identical wording.

### `scripts/fleet-go.ps1`

Owns lifecycle policy:

- Pre-labor statuses keep their current discard path and never call the archive
  helper.
- Every other execute terminal result calls the helper before JSON/text output.
- It attaches the archive result, updates `report.md`, and maps archive failure
  onto the existing top-level `failed` contract while retaining `work_status`.

The conductor, spawner, verification, acceptance, scope oracle, and
proof-by-diff implementations remain unchanged.

## Security and safety

- Only the exact current `baton/run-*` branch may be pushed.
- The push target is explicit: `origin` and the matching
  `refs/heads/baton/run-*`; never the default branch and never a force push.
- A missing `origin`, authentication refusal, non-fast-forward result, or remote
  mismatch fails loudly.
- Git output recorded in the result is bounded to a short reason; the complete
  work remains in the retained local worktree.
- Baton never merges, opens a PR, deletes a remote branch, or removes a retained
  worktree in this slice.

## Testing strategy

### Executor unit suite

Use temporary repositories and a temporary bare Git remote to prove:

1. Staged tracked/untracked changes become one archive commit.
2. The pushed remote branch tip equals the local tip.
3. An instrument-created commit is pushed without an unnecessary empty commit.
4. A truly unchanged run returns `skipped-no-changes` without a commit or push.
5. A missing/broken remote returns structured failure and leaves local work
   intact.
6. A wrong current branch is refused before any push.

### Execute integration suite

Give the existing target repository a temporary bare `origin`, then prove:

1. The normal execute result contains a successful `archive` object.
2. The run branch is at least one commit ahead of `base_sha`.
3. `origin/baton/run-*` equals the local tip.
4. `archive.json` and `report.md` carry the durability evidence.
5. Pre-labor discard cases still create neither local nor remote run branches.
6. Archive push failure exits 1, reports `failure_category: archive-failed`,
   preserves `work_status`, and leaves the worktree/local branch recoverable.

Tests use local bare remotes only. They never write to GitHub or another live
remote.

## Alternatives considered

### Commit inside `Get-RunDiff`

Rejected. Diff calculation runs throughout verification and acceptance; making
it mutate history would blur task snapshots, create multiple commits, and couple
proof generation to publication.

### Archive in an external post-run command

Rejected. A separate command leaves a crash window between Baton claiming the
branch is retained and the operator remembering to archive it. Durability is a
terminal invariant, not optional housekeeping.

### Keep the original status and only add an archive warning

Rejected. `status: completed` or an exit-0 budget pause with an unpushable branch
lets automation miss the broken durability promise. The existing `failed`
contract plus `work_status` is both loud and backward-compatible.

## Explicitly out of scope

- Automatic merge, PR creation, or acceptance changes
- Resume-from-task or mid-DAG restart
- Remote branch/worktree pruning commands
- Archive-remote selection or push opt-out policy
- `model_pick` routing (#177)
- Usage-probe/CodexBar work (#173/#178)
- The separate stale `docs/next-session.md` refresh

## Success criteria

The slice is complete when every retained run with real work has a verified
remote branch tip matching its local run branch; a no-work run creates no fake
commit; pre-labor discards remain empty; and any failure to establish durability
is machine-readable, exit-1 loud, and leaves the local recovery state intact.
