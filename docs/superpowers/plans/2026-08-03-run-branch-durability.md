# Run-branch Durability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every retained `baton/run-*` branch with real work a verified remote artifact, while failing loudly and preserving local recovery state when archival cannot be established.

**Architecture:** Add one structured Git archive transaction to `fleet-executor-lib.ps1`, beside the existing worktree lifecycle helpers. `fleet-go.ps1` invokes it only for post-labor retained statuses, attaches the result/report evidence, and maps archive failure onto the existing top-level `failed` contract without changing conductor, verification, acceptance, or proof-by-diff behavior.

**Tech Stack:** PowerShell 7, Git CLI, Baton's existing hashtable/JSON result contracts, temporary real Git repositories and bare remotes for tests.

## Global Constraints

- Pre-labor statuses `plan-rejected`, `plan-gate-degraded`, `plan-invalid`, and `plan-failed` retain their current local worktree/branch discard behavior and never publish.
- Only the checked-out expected `baton/run-*` branch may be pushed; remote is exactly `origin`; no force push, merge, or PR creation.
- No-work runs create no empty commit and perform no push.
- Archive failure leaves the worktree and local branch intact, writes `archive.json`, returns exit 1 through `status: failed`, and preserves the original result as `work_status`.
- Tests use local bare remotes only; they never contact GitHub or another live remote.
- Do not implement pruning, resume-from-task, archive-remote selection, push opt-out, `model_pick`, or usage-probe work.
- Preserve the current 965-byte shell-argument ceiling and use short fixed commit messages.

---

### Task 1: Real Git archive transaction

**Files:**
- Modify: `scripts/test-fleet-executor-lib.ps1` near the existing `R1`/`R2` worktree-lifecycle tests
- Modify: `scripts/fleet-executor-lib.ps1:387` after `Remove-RunWorktree`

**Interfaces:**
- Consumes: `Worktree`, `RepoPath`, expected `Branch`, `BaseSha`, and `RunDir`
- Produces: `Publish-RunBranch -Worktree <path> -RepoPath <path> -Branch <baton/run-*> -BaseSha <sha> -RunDir <path>` returning a schema-1 hashtable with fixed keys `schema,status,branch,base_sha,commit_sha,committed,pushed,remote,remote_ref,reason`
- Produces: `<RunDir>/archive.json` for every return path
- Produces: `Format-RunArchiveSection -Archive <hashtable> -Worktree <path>` for identical CLI/report wording

- [ ] **Step 1: Write the first failing behavior test**

Name the break: removing `Publish-RunBranch` or omitting its commit/push side effect must leave a run branch zero commits ahead or absent remotely.

Add a real-repository test fixture after `R2`:

```powershell
$archiveRoot = Join-Path $tmp 'archive-case'
$archiveRepo = Join-Path $archiveRoot 'repo'
$archiveRemote = Join-Path $archiveRoot 'origin.git'
$archiveRunDir = Join-Path $archiveRoot 'run'
New-Item -ItemType Directory -Force -Path $archiveRepo,$archiveRunDir | Out-Null
& git init --bare -q $archiveRemote
& git -C $archiveRepo init -q
& git -C $archiveRepo config user.email 'test@test.local'
& git -C $archiveRepo config user.name 'baton-test'
Set-Content -LiteralPath (Join-Path $archiveRepo 'base.txt') -Value 'base' -Encoding utf8NoBOM
& git -C $archiveRepo add -A
& git -C $archiveRepo commit -q -m 'base'
& git -C $archiveRepo remote add origin $archiveRemote
$archiveBase = [string](& git -C $archiveRepo rev-parse HEAD)
$archiveWt = New-RunWorktree -RepoPath $archiveRepo -RunId 'archive-success'
Set-Content -LiteralPath (Join-Path $archiveWt.worktree 'new.txt') -Value 'retained' -Encoding utf8NoBOM

$publishCmd = Get-Command Publish-RunBranch -ErrorAction SilentlyContinue
Check 'AR1 archive publisher exists' ($null -ne $publishCmd)
if ($publishCmd) {
    $archive = Publish-RunBranch -Worktree $archiveWt.worktree -RepoPath $archiveRepo `
        -Branch $archiveWt.branch -BaseSha $archiveBase -RunDir $archiveRunDir
    $localTip = [string](& git -C $archiveWt.worktree rev-parse HEAD)
    $remoteTip = [string](& git --git-dir $archiveRemote rev-parse "refs/heads/$($archiveWt.branch)")
    Check 'AR2 changed tree is committed' ($archive.committed -eq $true -and $localTip -ne $archiveBase)
    Check 'AR3 remote tip matches local tip' ($archive.pushed -eq $true -and $remoteTip -eq $localTip)
}
```

- [ ] **Step 2: Run the executor suite and verify RED**

Run:

```powershell
pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1
```

Expected: suite completes with `FAIL: AR1 archive publisher exists`; existing tests remain green.

- [ ] **Step 3: Implement the minimal archive helper**

Add a fixed-shape result builder and the public helper. Use native Git operations against the real worktree:

```powershell
function Publish-RunBranch {
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$RunDir
    )

    $archive = [ordered]@{
        schema = 1; status = 'failed'; branch = $Branch; base_sha = $BaseSha
        commit_sha = ''; committed = $false; pushed = $false
        remote = 'origin'; remote_ref = "refs/heads/$Branch"; reason = ''
    }

    # Validate exact current baton/run-* branch, add -A, commit staged changes,
    # skip only when HEAD is not ahead of BaseSha, push explicit HEAD:ref,
    # then compare ls-remote tip with local HEAD. Every failure returns the
    # fixed result after writing archive.json; it never deletes recovery state.
}
```

Use this exact short commit-message family:

```text
chore(baton-run): archive unreviewed run <run-id>
```

Derive `<run-id>` from the branch leaf after `baton/run-`; never accept it from model output.

- [ ] **Step 4: Run the executor suite and verify GREEN**

Run the same command. Expected: `AR1`–`AR3` and all existing checks pass.

- [ ] **Step 5: Add the remaining failing edge-case tests one behavior at a time**

Add real fixtures and run after each assertion group so each new check is seen failing before its production branch exists:

```powershell
# Existing instrument commit: publish without an unnecessary empty commit.
Check 'AR4 existing worker commit is pushed without archive commit' (
    $archiveExisting.status -eq 'pushed' -and
    $archiveExisting.committed -eq $false -and
    $afterCount -eq $beforeCount)

# No change and no commits ahead: no remote branch, no commit.
Check 'AR5 unchanged run skips without fake commit or push' (
    $archiveEmpty.status -eq 'skipped-no-changes' -and
    $archiveEmpty.committed -eq $false -and
    $archiveEmpty.pushed -eq $false -and
    $emptyAfter -eq $emptyBefore)

# Missing origin: structured failure, local file still present.
Check 'AR6 push failure is structured and preserves local recovery state' (
    $archiveBroken.status -eq 'failed' -and
    $archiveBroken.reason -match 'origin|push' -and
    (Test-Path (Join-Path $brokenWt.worktree 'recover-me.txt')))

# Wrong branch argument: refuse before pushing any ref.
Check 'AR7 wrong branch is refused before push' (
    $archiveWrong.status -eq 'failed' -and
    $archiveWrong.reason -match 'expected branch|baton/run-')

# Every path writes the stable artifact shape.
$artifact = Get-Content -Raw (Join-Path $brokenRunDir 'archive.json') | ConvertFrom-Json
Check 'AR8 archive artifact has stable schema and fields' (
    $artifact.schema -eq 1 -and $artifact.status -eq 'failed' -and
    $null -ne $artifact.committed -and $null -ne $artifact.pushed -and
    $artifact.remote -eq 'origin')
```

- [ ] **Step 6: Implement each minimal edge-case branch and report formatter**

Add only the branches demanded by `AR4`–`AR8`. Implement:

```powershell
function Format-RunArchiveSection {
    param([Parameter(Mandatory)]$Archive, [Parameter(Mandatory)][string]$Worktree)
    if ($Archive.status -eq 'pushed') {
        return "## Durability`n`nArchived unreviewed run branch ``$($Archive.branch)`` at ``$($Archive.commit_sha)`` to ``origin``. Baton did not merge it."
    }
    if ($Archive.status -eq 'skipped-no-changes') {
        return '## Durability' + "`n`nNo tree changes or commits differed from the base; no archive commit or push was needed."
    }
    return "## Durability`n`nARCHIVE FAILED: $($Archive.reason)`n`nLocal recovery remains at ``$Worktree`` on ``$($Archive.branch)``."
}
```

- [ ] **Step 7: Run executor tests and inspect the production diff**

```powershell
pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1
git diff --check
git diff -- scripts/fleet-executor-lib.ps1 scripts/test-fleet-executor-lib.ps1
```

Expected: executor suite `ALL PASS`; diff contains no force push, merge, PR, or deletion path.

- [ ] **Step 8: Commit Task 1**

```powershell
git add scripts/fleet-executor-lib.ps1 scripts/test-fleet-executor-lib.ps1
git commit -m "feat(executor): archive retained run branches"
```

---

### Task 2: Golden-path lifecycle wiring and fail-loud result mapping

**Files:**
- Modify: `scripts/test-fleet-go-execute.ps1:13-40` test target setup and `:100-125` happy-path assertions
- Modify: `scripts/fleet-go.ps1:280-322` terminal execute lifecycle

**Interfaces:**
- Consumes: `Publish-RunBranch` and `Format-RunArchiveSection` from Task 1
- Produces: result fields `archive`, and on failure `work_status` plus `failure_category: archive-failed`
- Updates: `<run-dir>/report.md` and in-memory `result.report` with exactly one durability section

- [ ] **Step 1: Give integration tests a real local origin**

Immediately after the initial target-repository commit, add:

```powershell
$origin = Join-Path $tmpRoot 'origin.git'
& git init --bare -q $origin
& git -C $repo remote add origin $origin
& git -C $repo push -q -u origin HEAD
```

- [ ] **Step 2: Write happy-path integration assertions and verify RED**

Add after `E9`:

```powershell
$localRunTip = [string](& git -C ([string]$res.worktree) rev-parse HEAD)
$remoteRunTip = [string](& git --git-dir $origin rev-parse "refs/heads/$($res.branch)")
$ahead = [int](& git -C $repo rev-list --count "$($res.archive.base_sha)..$($res.branch)")
Check 'E9o retained run is committed ahead of base' ($ahead -ge 1 -and $res.archive.committed -eq $true)
Check 'E9p retained run remote tip matches local tip' ($res.archive.status -eq 'pushed' -and $remoteRunTip -eq $localRunTip)
Check 'E9q archive artifact and report evidence exist' (
    (Test-Path (Join-Path $res.run_dir 'archive.json')) -and
    ((Get-Content -Raw (Join-Path $res.run_dir 'report.md')) -match '## Durability'))
```

Run `scripts/test-fleet-go-execute.ps1`. Expected: `E9o`–`E9q` fail because the result has no archive object and the run branch remains zero commits ahead.

- [ ] **Step 3: Wire publication into the retained-status branch**

In `fleet-go.ps1`, retain the existing pre-labor `if` unchanged. At the start of the `else` branch:

```powershell
$archive = Publish-RunBranch -Worktree $wt.worktree -RepoPath $repo `
    -Branch $wt.branch -BaseSha $wt.base_sha -RunDir $runDir
$result.archive = $archive
$durabilitySection = Format-RunArchiveSection -Archive $archive -Worktree $wt.worktree
$result.report = ([string]$result.report).TrimEnd() + "`n`n" + $durabilitySection
Set-Content -LiteralPath (Join-Path $runDir 'report.md') -Value $result.report -Encoding utf8NoBOM
if ($archive.status -eq 'failed') {
    $result.work_status = [string]$result.status
    $result.status = 'failed'
    $result.failure_category = 'archive-failed'
}
```

Then populate `branch`, `worktree`, and `files_changed` as today. Ensure the non-JSON message reports `archive.status` and does not say “review and merge” when archival failed.

- [ ] **Step 4: Run the execute suite and verify GREEN**

Run `pwsh -NoProfile -File scripts/test-fleet-go-execute.ps1`. Expected: existing checks plus `E9o`–`E9q` pass.

- [ ] **Step 5: Write the archive-failure integration test and verify RED**

Temporarily point `origin` at a missing local path, run a normal execute, then restore it:

```powershell
$goodOrigin = [string](& git -C $repo remote get-url origin)
$brokenOrigin = Join-Path $tmpRoot 'missing-origin.git'
& git -C $repo remote set-url origin $brokenOrigin
try {
    $rawArchiveFail = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" `
        -Goal 'g' -Execute -RepoPath $repo -Json | Out-String
    $archiveFailExit = $LASTEXITCODE
    $archiveFail = $rawArchiveFail | ConvertFrom-Json
} finally {
    & git -C $repo remote set-url origin $goodOrigin
}
Check 'E31 archive failure is exit-1 loud with original work status' (
    $archiveFailExit -eq 1 -and $archiveFail.status -eq 'failed' -and
    $archiveFail.failure_category -eq 'archive-failed' -and
    $archiveFail.work_status -eq 'completed')
Check 'E32 archive failure preserves recoverable local state' (
    $archiveFail.archive.status -eq 'failed' -and
    (Test-Path ([string]$archiveFail.worktree)) -and
    (& git -C $repo branch --list ([string]$archiveFail.branch)))
```

Expected RED before failure mapping: original status remains `completed` or the result omits the required failure fields.

- [ ] **Step 6: Implement minimal failure messaging and verify GREEN**

Ensure `$executeFailure` already treats mapped `status: failed` as exit 1. Add:

```powershell
if ($Execute -and $result.failure_category -eq 'archive-failed') {
    [Console]::Error.WriteLine("go: run work exists locally but archive failed: $($result.archive.reason)")
}
```

Run the execute suite. Expected: `E31`/`E32` and all previous checks pass.

- [ ] **Step 7: Re-run both affected suites and inspect lifecycle mutations**

```powershell
pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-go-execute.ps1
git diff --check
git diff -- scripts/fleet-go.ps1 scripts/test-fleet-go-execute.ps1
```

Mutation check: changing the remote ref, skipping the commit, accepting a wrong branch, suppressing push failure, or removing status mapping must fail at least one named test.

- [ ] **Step 8: Commit Task 2**

```powershell
git add scripts/fleet-go.ps1 scripts/test-fleet-go-execute.ps1
git commit -m "feat(go): fail loud unless retained work is durable"
```

---

### Task 3: Operator contract, decision record, and full verification

**Files:**
- Modify: `commands/go.md` in the execute behavior and Notes sections
- Modify: `docs/superpowers/specs/2026-08-03-run-branch-durability-design.md` status only
- Create outside app repo: `D:\Dev\Grimdex\projects\baton\decisions\d107-retained-run-branches-are-durable.md`

**Interfaces:**
- Documents the behavior shipped in Tasks 1–2
- Records the portable coding decision in Grimdex without duplicating its rationale into app instruction files

- [ ] **Step 1: Document the user-facing behavior**

Update `commands/go.md` with:

```markdown
After any post-labor terminal result, Baton commits unreviewed work to the
`baton/run-*` branch and pushes that exact branch to `origin`. Baton still never
merges. If commit or push fails, the run returns `status: failed` with
`failure_category: archive-failed`, preserves the original `work_status`, and
leaves the local worktree/branch in place for recovery. Pre-labor plan halts
continue to discard their untouched worktree and branch.
```

Do not update stale `docs/next-session.md` in this feature slice.

- [ ] **Step 2: Record decision d107 in Grimdex**

Before writing, verify Grimdex is clean and run `git pull --rebase`. Create:

```markdown
---
id: d107
timestamp: 2026-08-03
project: baton
status: accepted
confidence: high
revisit-if: Baton supports a configured archive remote or operators opt out of automatic run-branch backup
---

# Retained run branches are durable terminal artifacts

## Chosen

Every post-labor retained `baton/run-*` branch with real work is committed and
pushed to `origin` before Baton reports a successful terminal result. Archive
failure is exit-1 loud and preserves local recovery state plus the underlying
work status.

## Alternatives

- Leave staged work local and instruct the operator to commit later.
- Archive in a separate housekeeping command.
- Warn while retaining the original successful top-level status.

## Rationale

The existing branch-retention message promises reviewable and mergeable work,
but a staged-only branch is zero commits ahead and cannot be recovered from the
remote. Durability is therefore part of the terminal invariant, not optional
housekeeping.

## Feedback

- Positive: issue #157 documents multiple real halted runs with substantive
  staged work and zero commits ahead; manual commits/pushes were required.
- Negative: automatic pushes may be inappropriate for a future repo without an
  `origin`; that case currently fails loudly and is the `revisit-if` trigger.
```

Commit and push Grimdex separately according to `GRIMDEX.md`.

- [ ] **Step 3: Mark the spec implemented and run targeted verification**

Change the design status to `implemented` only after both affected suites pass. Then run:

```powershell
pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-go-execute.ps1
python -m pytest kb dashboard -q
```

Expected: both PowerShell suites `ALL PASS`; Python reports zero failures.

- [ ] **Step 4: Run the repository-required PowerShell test walk**

```powershell
$tests = Get-ChildItem scripts -Filter 'test-*.ps1' | Sort-Object Name
foreach ($test in $tests) {
    Write-Host "=== $($test.Name) ==="
    & pwsh -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Expected: every suite exits 0.

- [ ] **Step 5: Final source and branch audit**

```powershell
git diff --check
git status --short --branch
git diff master...HEAD --stat
git diff master...HEAD -- scripts/fleet-executor-lib.ps1 scripts/fleet-go.ps1 commands/go.md
```

Verify:

- No force push, merge, PR creation, remote deletion, or retained-worktree removal was added.
- Pre-labor cleanup still executes before publication.
- Every archive return writes stable JSON.
- Archive failure leaves local recovery state and exits 1.
- No-work runs create no fake commit.

- [ ] **Step 6: Commit Task 3**

```powershell
git add commands/go.md docs/superpowers/specs/2026-08-03-run-branch-durability-design.md docs/superpowers/plans/2026-08-03-run-branch-durability.md
git commit -m "docs: document durable run branch contract"
```

- [ ] **Step 7: Request adversarial code review before any PR or merge**

Use the `superpowers:requesting-code-review` skill against `master...HEAD`. Fix every verified blocker test-first, re-run affected and full verification, and keep merge as a separate explicit human gate.

