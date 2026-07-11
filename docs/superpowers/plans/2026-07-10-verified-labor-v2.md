# Verified Labor V2 — Conductor integration + one evidence-informed retry (d082)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Wire the merged V1 verification runner into the Conductor so an opt-in `-Verify` run freezes each task's contract before labor, verifies after every agentic attempt, retries once with evidence on a check failure, fails closed on a scope/oracle violation, and records durable per-task evidence + a narrated report — default path byte-for-byte unchanged.

**Architecture:** Verification rides an OPTIONAL wrapping spawner (`New-VerifyingSpawner`) built in `fleet-go.ps1`, keeping all worktree-coupled logic (diff, pre-hashes, re-dispatch) in `fleet-executor-lib.ps1` where the worktree lives. The Conductor gains a `-Verify` switch, a `-VerifyPreflight` scriptblock seam (called once after planning, before the walk), emits the six verification event kinds from the augmented spawner result, and maps a verification failure to the new terminal status `verification-failed`. Preflight and the verifying spawner share a frozen-contracts hashtable (both closures built in fleet-go, closing over the same reference).

**Tech Stack:** PowerShell 7. Builds on V1 `scripts/verification-lib.ps1` (`Get-FrozenVerificationContract`, `Get-VerifyPathHashes`, `Invoke-VerificationContract`) and d078 `scripts/fleet-executor-lib.ps1` (`New-AgenticSpawner`, `Get-WorktreeTreeSha`, worktree lifecycle).

## Global Constraints (binding — copied verbatim from d082 + house rules)

- **Fail-CLOSED** for the verification oracle: a task that DEMANDS verification (has `verify_profile`) and can't resolve/run it FAILS — never a silent pass. (Contrast: the advisory Plan/Acceptance gates fail-OPEN.)
- **Default path byte-for-byte unchanged**: no behavior change without `-Verify`. A plan with no `verify_profile` on any task, or `-Verify` absent, produces the exact events/artifacts/status as today.
- **Exactly ONE retry** per verify-carrying task, in the SAME worktree, with a bounded evidence prompt. Second failure stops the walk at that task with status `verification-failed`.
- **Outcome precedence (codex-ringer §7):** spawn/infra failure = task fail (not model-quality); verification pass even if the worker exited nonzero (retain a warning); verification fail or timeout = eligible for the one retry; scope violation or protected-oracle mutation = fail-closed, NO retry; no contract = legacy behavior + `unverified` mark.
- **A5 (adjudication):** an edit task's verification pass ALSO requires a non-empty task diff (close the V1 zero-change loophole).
- **Frozen authority:** contracts resolve from the base commit via V1's `Get-FrozenVerificationContract`; a worktree edit to `.baton/verification.json` can never change the running oracle. Unknown/lint-failing/missing profile at preflight = `plan-invalid` BEFORE any spend.
- House: `utf8NoBOM`; `ConvertTo-Json -InputObject @(...)` for arrays; never name vars `$args/$input/$event/$matches/$host/$pid` (events use `$EventObj`); unary-comma returns only for direct-assignment consumers; guard 0/0; `[Console]::Error.WriteLine` + `exit 2` for CLI user errors; 965-byte shell-arg ceiling in tests; hermetic tests (temp `BATON_HOME` + temp git repos + try/finally, never real `~/.baton`/`~/.claude`).
- **Terminal status name:** `verification-failed`. **Event kinds:** `task-verification-started`, `task-verification-passed`, `task-verification-failed`, `task-retry-started`, `task-scope-violation`, `task-unverified` (`New-RunEvent -Kind` is a free string — no ValidateSet to extend).

## Controller preamble (run BEFORE Task 1)

```powershell
git -C D:\Dev\Baton worktree add ..\baton-vl-v2 -b feature/verified-labor-v2 master
# All task work happens in D:\Dev\baton-vl-v2 (branch feature/verified-labor-v2).
# The main tree D:\Dev\Baton stays on master. Implementers: branch-guard first,
# `git add <explicit paths>` only, never touch untracked *-ringer*.md.
```

---

## Task 1 — Plan normalization + Conductor `-Verify`/preflight seam + `verification-failed` status + fleet-go plumbing  [sonnet]

**Files:**
- Modify: `scripts/conductor-lib.ps1` — `ConvertTo-PlanObject` (add two task fields); `Invoke-Conductor` (params + preflight block + per-task verification event/status handling)
- Modify: `scripts/fleet-go.ps1` — `-Verify` param; frozen-map wiring; `New-VerifyingSpawner` swap; `BATON_GO_TEST_VERIFY` seam
- Modify: `scripts/test-conductor-lib.ps1` — VF-series checks
- Test: `scripts/test-fleet-go-execute.ps1` unaffected (regression only)

**Interfaces:**
- Consumes (from V1, merged): `Get-FrozenVerificationContract -RepoPath -BaseSha -ProfileName -WorktreeRoot -RunTaskDir` → `@{ ok; contract; contract_path; reason }`.
- Produces (for Task 2): the `-Spawner` augmented result contract — a verify-carrying task returns `@{ ok; spend; chose; why; alternatives; verification=@{verdict;grade;failure_category;output_path;attempts;retried}; unverified=$false }`. Non-verify tasks return the existing shape (no `verification` key). Task 2 implements the producer; Task 1 consumes these optional keys defensively.

- [ ] **Step 1: Add `verify_profile` + `allowed_paths` to task normalization**

In `ConvertTo-PlanObject`, extend the per-task `[pscustomobject]` (after `reversible`):

```powershell
        [pscustomobject]@{
            id            = [string]$t.id
            desc          = [string]$t.desc
            command       = [string]$t.command
            capability    = [string]$t.capability
            model_pick    = [string]$t.model_pick
            depends_on    = @($t.depends_on | Where-Object { $_ })
            est_cost_tier = if ($t.est_cost_tier) { [string]$t.est_cost_tier } else { 'free' }
            reversible    = if ($null -eq $t.reversible) { $true } else { [bool]$t.reversible }
            verify_profile = if ($t.verify_profile) { [string]$t.verify_profile } else { '' }
            allowed_paths  = @($t.allowed_paths | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
```

- [ ] **Step 2: Write the failing normalization test**

Append to `test-conductor-lib.ps1`:

```powershell
# VF1: verify_profile + allowed_paths survive normalization; absent -> defaults
$pj = '{"tasks":[{"id":"t1","desc":"edit","capability":"code-gen","verify_profile":"unit","allowed_paths":["src/a.py","tests/a.py"]},{"id":"t2","desc":"doc","capability":"summarize"}]}'
$plan = ConvertTo-PlanObject -RawStdout $pj
$t1 = @($plan.tasks)[0]; $t2 = @($plan.tasks)[1]
Assert "VF1a verify_profile preserved" ($t1.verify_profile -eq 'unit')
Assert "VF1b allowed_paths preserved" (@($t1.allowed_paths).Count -eq 2 -and $t1.allowed_paths[0] -eq 'src/a.py')
Assert "VF1c absent verify_profile -> ''" ($t2.verify_profile -eq '')
Assert "VF1d absent allowed_paths -> empty" (@($t2.allowed_paths).Count -eq 0)
```

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1` — VF1 FAILS (fields absent) before Step 1, PASSES after.

- [ ] **Step 3: Add `-Verify`/`-VerifyPreflight` params + preflight block to `Invoke-Conductor`**

Add to the `Invoke-Conductor` param block (after `$PlanGateDispatcher`):

```powershell
        [switch]$Verify,
        [scriptblock]$VerifyPreflight
```

Insert the preflight block AFTER the Plan Gate block (after its closing `}` at ~line 685) and BEFORE `# 2. Order the DAG.`:

```powershell
    # 1.7 Verification preflight (d082 V2): OPT-IN. Freeze every referenced verify
    #     profile from the base revision and validate it BEFORE the walk — an unknown,
    #     missing, or lint-failing contract fails the plan closed (plan-invalid) before
    #     any labor spend. Fail-CLOSED (unlike the advisory gates): a task that demands
    #     verification cannot run without a resolvable oracle. Without -Verify this block
    #     is skipped entirely (default path unchanged).
    if ($Verify -and $VerifyPreflight) {
        $pf = $null
        try { $pf = & $VerifyPreflight $plan }
        catch {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'verification' -Level 'error' -Message "verification preflight threw: $($_.Exception.Message)")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
        }
        if ($null -ne $pf -and -not $pf.ok) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'verification' -Level 'error' -Message "verification preflight failed: $($pf.reason) — no walk, no spend")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
        }
    }
```

- [ ] **Step 4: Emit verification events + map the `verification-failed` status in the walk**

In the walk loop, REPLACE the block from `$kind = if ($r.ok) { 'finished' } else { 'error' }` through the `if (-not $r.ok) { return ... 'failed' ... }` (currently ~lines 723–727) with:

```powershell
        # Verification (d082 V2): the verifying spawner attaches a `verification`
        # result and/or an `unverified` mark to $r. Emit the legible event trail and
        # map a verification failure to its own terminal status. When -Verify is off
        # or the task carried no contract, $r has neither key and this is inert.
        if ($Verify -and $r.unverified) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-unverified' -Message "no verification contract — proceeding unverified")
        }
        if ($Verify -and $r.verification) {
            $v = $r.verification
            if ($r.retried) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-retry-started' -Message "verification failed ($($v.first_failure_category)) — one evidence-informed retry")
            }
            if ([string]$v.verdict -eq 'pass') {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-verification-passed' -Message "verified (grade: $($v.grade)) — $($v.proves)")
            }
            elseif ([string]$v.failure_category -in @('scope-violation','protected-path-mutated')) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-scope-violation' -Level 'warn' -Message "scope/oracle violation ($($v.failure_category)) — fail-closed, no retry")
            }
            else {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-verification-failed' -Level 'warn' -Message "verification failed ($($v.failure_category))")
            }
        }
        $kind = if ($r.ok) { 'finished' } else { 'error' }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind $kind -Message $task.desc)
        if (-not $r.ok) {
            $failStatus = if ($Verify -and $r.verification -and [string]$r.verification.verdict -ne 'pass') { 'verification-failed' } else { 'failed' }
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $failStatus -PendingTaskId $task.id)
        }
```

(Note: `task-verification-started` is emitted by the verifying spawner in Task 2, immediately before it runs the check, since that is where the timing is known. Task 1 emits the terminal-outcome events above.)

- [ ] **Step 5: Conductor verification tests (stub spawner, hermetic)**

Append VF2–VF7 to `test-conductor-lib.ps1`. These stub `-Spawner` to return canned verification metadata and stub `-VerifyPreflight` — no worktree, no real runner:

```powershell
# Helper: a canned plan + run dir
function New-VfRun { $d = Join-Path $env:TEMP "vf-$([guid]::NewGuid())"; New-Item -ItemType Directory -Force $d | Out-Null; $d }
$vfPlan = { param($g) @{ goal=$g; budget_cap=$null; tasks=@([pscustomobject]@{ id='t1'; desc='edit'; command=''; capability='code-gen'; depends_on=@(); est_cost_tier='free'; reversible=$true; verify_profile='unit'; allowed_paths=@() }) } }

# VF2: -Verify pass -> completed + task-verification-passed event
$d = New-VfRun
$sp = { param($t) @{ ok=$true; spend=0.0; chose='w'; why='ok'; alternatives=@(); verification=@{ verdict='pass'; grade='strong'; failure_category=''; proves='suite passes'; retried=$false } } }
$res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$true } }
Assert "VF2 status completed" ($res.status -eq 'completed')
Assert "VF2 passed event" (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-verification-passed' }).Count -ge 1)
Remove-Item $d -Recurse -Force

# VF3: -Verify check-fail (verdict fail) -> verification-failed status + event
$d = New-VfRun
$sp = { param($t) @{ ok=$false; spend=0.0; chose='w'; why='fail'; alternatives=@(); verification=@{ verdict='fail'; grade='invalid'; failure_category='check-failed'; proves='x'; retried=$true; first_failure_category='check-failed' } } }
$res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$true } }
Assert "VF3 status verification-failed" ($res.status -eq 'verification-failed')
Assert "VF3 retry event" (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-retry-started' }).Count -ge 1)
Assert "VF3 failed event" (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-verification-failed' }).Count -ge 1)
Remove-Item $d -Recurse -Force

# VF4: scope-violation -> verification-failed + task-scope-violation event, no 'failed'
$d = New-VfRun
$sp = { param($t) @{ ok=$false; spend=0.0; chose='w'; why='scope'; alternatives=@(); verification=@{ verdict='scope-violation'; grade='invalid'; failure_category='protected-path-mutated'; proves='x'; retried=$false } } }
$res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$true } }
Assert "VF4 status verification-failed" ($res.status -eq 'verification-failed')
Assert "VF4 scope event" (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-scope-violation' }).Count -ge 1)
Remove-Item $d -Recurse -Force

# VF5: preflight fail -> plan-invalid before the walk (spawner never called)
$d = New-VfRun
$called = [ref]$false
$sp = { param($t) $called.Value = $true; @{ ok=$true; spend=0.0; chose='w'; why=''; alternatives=@() } }
$res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$false; reason="unknown-profile 'unit'" } }
Assert "VF5 status plan-invalid" ($res.status -eq 'plan-invalid')
Assert "VF5 spawner not called" (-not $called.Value)
Remove-Item $d -Recurse -Force

# VF6: unverified task (no contract) -> completed + task-unverified event
$d = New-VfRun
$sp = { param($t) @{ ok=$true; spend=0.0; chose='w'; why='ok'; alternatives=@(); unverified=$true } }
$res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$true } }
Assert "VF6 status completed" ($res.status -eq 'completed')
Assert "VF6 unverified event" (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-unverified' }).Count -ge 1)
Remove-Item $d -Recurse -Force

# VF7: -Verify ABSENT -> byte-for-byte unchanged (no verification events even if $r carries them)
$d = New-VfRun
$sp = { param($t) @{ ok=$true; spend=0.0; chose='w'; why='ok'; alternatives=@(); verification=@{ verdict='pass'; grade='strong'; failure_category=''; proves='x'; retried=$false } } }
$res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp   # no -Verify
Assert "VF7 status completed" ($res.status -eq 'completed')
Assert "VF7 no verification events" (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-verification' }).Count -eq 0)
Remove-Item $d -Recurse -Force
```

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1` — all prior + VF1–VF7 exit 0.

- [ ] **Step 6: fleet-go `-Verify` plumbing + frozen-map + verifying-spawner swap**

Add to the `fleet-go.ps1` param block (after `$RepoPath`):

```powershell
    [switch]$Verify,
```

In the `if ($Execute)` block, AFTER `$go['Spawner'] = New-AgenticSpawner @spawnArgs` and `$go['DiffProvider'] = ...` (line ~107), add:

```powershell
    if ($Verify) {
        # Shared frozen-contracts map: the preflight closure populates+validates it from
        # the base revision; the verifying spawner reads it per task. Both close over the
        # same hashtable reference (built here so they share it).
        $frozen = @{}
        $go['Verify'] = $true
        $go['VerifyPreflight'] = {
            param($plan)
            foreach ($tk in @($plan.tasks)) {
                $prof = [string]$tk.verify_profile
                if (-not $prof) { continue }
                $taskDir = Join-Path $runDir "tasks/$($tk.id)"
                $fc = Get-FrozenVerificationContract -RepoPath $repo -BaseSha $wt.base_sha `
                        -ProfileName $prof -WorktreeRoot $wt.worktree -RunTaskDir $taskDir
                if (-not $fc.ok) { return @{ ok = $false; reason = "task $($tk.id): $($fc.reason)" } }
                $frozen[[string]$tk.id] = @{ contract = $fc.contract; contract_path = $fc.contract_path }
            }
            return @{ ok = $true }
        }.GetNewClosure()
        $baseSpawner = $go['Spawner']
        $go['Spawner'] = New-VerifyingSpawner -InnerSpawner $baseSpawner -Worktree $wt.worktree `
            -BaseSha $wt.base_sha -RunDir $runDir -FrozenContracts $frozen
    }
```

Add a test seam BEFORE the `if ($Execute)` block (next to the other `BATON_GO_TEST_*` seams, ~line 82) so hermetic go-execute tests can force verification outcomes without a real check:

```powershell
if ($env:BATON_GO_TEST_VERIFY) {
    # Dot-source a file defining Invoke-TestVerify($task, $worktree) -> a verification
    # result hashtable; New-VerifyingSpawner honors it instead of the real runner.
    $env:BATON_VERIFY_TEST_HOOK = $env:BATON_GO_TEST_VERIFY
}
```

(`New-VerifyingSpawner` in Task 2 checks `$env:BATON_VERIFY_TEST_HOOK`.)

Dot-source note: `verification-lib.ps1` must be available to fleet-go's Execute path. It is dot-sourced by `New-VerifyingSpawner`'s home (`fleet-executor-lib.ps1`, Task 2 adds the `. "$PSScriptRoot/verification-lib.ps1"` line), which fleet-go already dot-sources in the Execute block — no extra dot-source in fleet-go.

- [ ] **Step 7: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/fleet-go.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(verify): V2 part 1 — plan normalization, conductor -Verify preflight + event/status seam (d082)"
```

---

## Task 2 — `New-VerifyingSpawner`: per-attempt verify + one evidence retry + evidence artifacts  [opus]

**Files:**
- Modify: `scripts/fleet-executor-lib.ps1` — add `. verification-lib.ps1` dot-source; add `New-VerifyingSpawner`, `Format-VerifyEvidencePrompt`, `Add-VerifyAttemptRow`
- Modify: `scripts/test-fleet-executor-lib.ps1` — VS-series checks (real V1 runner against temp check scripts; hermetic)

**Interfaces:**
- Consumes: the inner spawner (`New-AgenticSpawner`'s scriptblock — `param($task) -> @{ok;spend;chose;why;alternatives}`), V1 `Invoke-VerificationContract`/`Get-VerifyPathHashes`, `Get-WorktreeTreeSha`/`Get-RunDiff`.
- Produces: the augmented `-Spawner` result Task 1 consumes: `@{ ok; spend; chose; why; alternatives; verification=@{verdict;grade;failure_category;first_failure_category;proves;output_path;retried}; unverified }`.

- [ ] **Step 1: Dot-source V1 lib in the executor**

At the top of `fleet-executor-lib.ps1`, after the existing dot-sources (line ~11):

```powershell
. "$PSScriptRoot/verification-lib.ps1"   # Invoke-VerificationContract etc. (d082 V2)
```

- [ ] **Step 2: Evidence prompt + attempt-row helpers**

```powershell
function Format-VerifyEvidencePrompt {
    <# The bounded retry brief (codex-ringer §7): original task + deterministic failure
       category + a capped raw-output excerpt + missing files + current diff summary +
       the fix-in-place instruction. No restart, no scope broadening. #>
    param(
        [Parameter(Mandatory)][string]$TaskDesc,
        [Parameter(Mandatory)][hashtable]$Verification,
        [string]$OutputPath = '',
        [int]$MaxExcerpt = 2000
    )
    $excerpt = ''
    if ($OutputPath -and (Test-Path -LiteralPath $OutputPath)) {
        $raw = Get-Content -LiteralPath $OutputPath -Raw
        if ($raw.Length -gt $MaxExcerpt) { $raw = $raw.Substring(0, $MaxExcerpt) + "`n[...truncated...]" }
        $excerpt = $raw
    }
    return @"
$TaskDesc

--- Your previous attempt did not pass verification. Fix the EXISTING work; do not
restart from scratch and do not broaden the change beyond the task's scope. ---
Failure: $($Verification.failure_category)
Check output:
$excerpt
"@
}

function Add-VerifyAttemptRow {
    <# Append one attempt row to <RunTaskDir>/attempts.jsonl (codex-ringer §10). #>
    param(
        [Parameter(Mandatory)][string]$RunTaskDir,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][hashtable]$Row
    )
    New-Item -ItemType Directory -Force -Path $RunTaskDir | Out-Null
    $rec = [ordered]@{
        attempt          = $Attempt
        worker           = [string]$Row.worker
        worker_ok        = [bool]$Row.worker_ok
        diff_grew        = [bool]$Row.diff_grew
        verdict          = [string]$Row.verdict
        grade            = [string]$Row.grade
        failure_category = [string]$Row.failure_category
        first_try        = ($Attempt -eq 1)
        duration_ms      = [int]$Row.duration_ms
    }
    Add-Content -LiteralPath (Join-Path $RunTaskDir 'attempts.jsonl') -Value ($rec | ConvertTo-Json -Compress -Depth 6) -Encoding utf8NoBOM
}
```

- [ ] **Step 3: `New-VerifyingSpawner`**

```powershell
function New-VerifyingSpawner {
    <# Wrap an inner agentic spawner with the d082 verification sub-lifecycle. Per task:
       no verify_profile -> delegate + mark unverified. Otherwise: freeze pre-hashes,
       run inner attempt, compute the task diff, run the frozen contract, apply outcome
       precedence (codex-ringer §7 + A5 non-empty diff), and on a check-fail/timeout do
       exactly ONE evidence-informed retry in the SAME worktree. Writes attempts.jsonl +
       verification.json under tasks/<id>/. Returns the augmented spawner result. #>
    param(
        [Parameter(Mandatory)][scriptblock]$InnerSpawner,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$FrozenContracts
    )
    return {
        param($task)
        $prof = [string]$task.verify_profile
        if (-not $prof -or -not $FrozenContracts.ContainsKey([string]$task.id)) {
            $r = & $InnerSpawner $task
            $r.unverified = $true
            return $r
        }
        $contract = $FrozenContracts[[string]$task.id].contract
        $taskDir = Join-Path $RunDir "tasks/$($task.id)"
        New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
        $allowed = @($task.allowed_paths | Where-Object { $_ } | ForEach-Object { [string]$_ })

        $runAttempt = {
            param($atask, $attemptNo)
            # Freeze pre-hashes just before the attempt (the worktree changes between tasks).
            $protPre = Get-VerifyPathHashes -WorktreeRoot $Worktree -Paths @($contract.protected_paths)
            $expectPre = Get-VerifyPathHashes -WorktreeRoot $Worktree -Paths @($contract.expect_files)
            $preTree = Get-WorktreeTreeSha -Worktree $Worktree
            $ir = & $InnerSpawner $atask
            $postTree = Get-WorktreeTreeSha -Worktree $Worktree
            $grew = ($null -ne $preTree) -and ($null -ne $postTree) -and ($preTree -ne $postTree)
            $diffFiles = @()
            if ($grew) { $diffFiles = @(& git -C $Worktree diff --name-only $preTree $postTree 2>$null | Where-Object { $_ }) }
            # Test hook: a hermetic override of the real runner (set via BATON_VERIFY_TEST_HOOK).
            if ($env:BATON_VERIFY_TEST_HOOK -and (Test-Path -LiteralPath $env:BATON_VERIFY_TEST_HOOK)) {
                . $env:BATON_VERIFY_TEST_HOOK
                $v = Invoke-TestVerify -Task $atask -Attempt $attemptNo -Grew $grew
            } else {
                $v = Invoke-VerificationContract -Contract $contract -WorktreeRoot $Worktree -RunTaskDir $taskDir `
                        -DiffFiles $diffFiles -AllowedPaths $allowed -ExpectPreHashes $expectPre -ProtectedPreHashes $protPre
            }
            # A5: an edit task's pass ALSO requires a non-empty task diff (close the
            # zero-change loophole). If the check "passed" but nothing changed, treat as
            # a check failure (retry-eligible), not a pass.
            if ([string]$v.verdict -eq 'pass' -and -not $grew) {
                $v.verdict = 'fail'; $v.ok = $false; $v.grade = 'invalid'; $v.failure_category = 'no-change'
            }
            return @{ v = $v; inner = $ir; grew = $grew }
        }.GetNewClosure()

        # task-verification-started marker in the evidence trail (the conductor emits the
        # run event; this records timing in verification.json/attempts).
        $a1 = & $runAttempt $task 1
        Add-VerifyAttemptRow -RunTaskDir $taskDir -Attempt 1 -Row @{
            worker = [string]$a1.inner.chose; worker_ok = [bool]$a1.inner.ok; diff_grew = $a1.grew
            verdict = $a1.v.verdict; grade = $a1.v.grade; failure_category = $a1.v.failure_category; duration_ms = $a1.v.duration_ms
        }
        $final = $a1
        $retried = $false
        $firstFail = [string]$a1.v.failure_category

        # Retry precedence: pass -> done. scope/oracle violation -> fail-closed, NO retry.
        # check-failed / check-timeout / no-change / expected-file-* -> one retry.
        $retryable = @('check-failed','check-timeout','no-change','expected-file-missing','expected-file-empty','expected-file-unchanged')
        if ([string]$a1.v.verdict -ne 'pass' -and ([string]$a1.v.failure_category -in $retryable)) {
            $retried = $true
            $evidencePrompt = Format-VerifyEvidencePrompt -TaskDesc ([string]$task.desc) -Verification $a1.v -OutputPath ([string]$a1.v.output_path)
            $retryTask = $task.PSObject.Copy()
            $retryTask.desc = $evidencePrompt
            $a2 = & $runAttempt $retryTask 2
            Add-VerifyAttemptRow -RunTaskDir $taskDir -Attempt 2 -Row @{
                worker = [string]$a2.inner.chose; worker_ok = [bool]$a2.inner.ok; diff_grew = $a2.grew
                verdict = $a2.v.verdict; grade = $a2.v.grade; failure_category = $a2.v.failure_category; duration_ms = $a2.v.duration_ms
            }
            $final = $a2
        }

        $v = $final.v
        $verObj = @{
            verdict = [string]$v.verdict; grade = [string]$v.grade
            failure_category = [string]$v.failure_category; first_failure_category = $firstFail
            proves = [string]$v.proves; output_path = [string]$v.output_path; retried = $retried
        }
        ConvertTo-Json -InputObject $verObj -Depth 6 | Set-Content -LiteralPath (Join-Path $taskDir 'verification.json') -Encoding utf8NoBOM

        $passed = ([string]$v.verdict -eq 'pass')
        $why = if ($passed) { "$($final.inner.why); verified (grade $($v.grade))" }
               else { "$($final.inner.why); verification $($v.verdict): $($v.failure_category)" }
        return @{
            ok = $passed; spend = [double]$final.inner.spend; chose = [string]$final.inner.chose
            why = $why; alternatives = @($final.inner.alternatives)
            verification = $verObj; unverified = $false
        }
    }.GetNewClosure()
}
```

- [ ] **Step 4: env-wrapper argv-lint residual — defense-in-depth (V1 review carry-forward)**

Document + close cheaply. In `verification-lib.ps1` `Get-VerifyInterpreterLeaf`/`Test-VerifyArgvSafe`, the `env` wrapper shifts exactly one token, so `env FOO=bar <interp>` and `env -i <interp>` fall through to `default` (allow). V2 introduces NO untrusted argv path (contracts come from the frozen, trusted `.baton/verification.json`; the planner supplies only a profile NAME + allowed_paths, never argv), so this is not triggerable in V2. Still, close it as defense-in-depth: in `Test-VerifyArgvSafe`, when `$leaf -eq 'env'`, skip leading `NAME=value` assignment tokens and `-i`/`-u <name>`/`-C <dir>`/`--` before reading the real interpreter:

```powershell
    if ($leaf -eq 'env' -and $argvList.Count -ge 2) {
        $j = 1
        while ($j -lt $argvList.Count) {
            $tk = [string]$argvList[$j]
            if ($tk -match '^[A-Za-z_][A-Za-z0-9_]*=') { $j++; continue }        # NAME=value
            if ($tk -in @('-i','--ignore-environment','--')) { $j++; continue }  # flags w/o value
            if ($tk -in @('-u','-C','--unset','--chdir')) { $j += 2; continue }  # flags w/ value
            break
        }
        if ($j -lt $argvList.Count) { $skip = $j + 1; $leaf = Get-VerifyInterpreterLeaf $argvList[$j] }
    }
```

Add a lint test (append to `test-verification-lib.ps1`): `env FOO=bar python -c 'x'`, `env -i pwsh -Command 'x'`, `env -u X node --eval=1` all return `ok=$false`; a benign `env FOO=bar pytest tests/ -q` still returns `ok=$true`.

- [ ] **Step 5: VS-series executor tests (real runner, hermetic)**

Append to `test-fleet-executor-lib.ps1`. Build a temp git repo with a committed `.baton/verification.json` defining a `unit` profile whose argv runs a temp pwsh check script; a stub inner spawner that writes a file into the worktree (diff grows) and returns ok. Cases:

- **VS1 pass:** check script exits 0, inner writes a file → result `ok=$true`, `verification.verdict='pass'`, `verification.json` + `attempts.jsonl` (1 row, first_try=true) written.
- **VS2 retry-then-pass:** check fails on attempt 1 (a marker file absent), inner on attempt 2 creates it (inner spawner keys off `BATON_VERIFY_TEST_HOOK` or an attempt counter) → `retried=$true`, 2 attempt rows, final `ok=$true`.
- **VS3 retry-then-fail:** check fails both attempts → `ok=$false`, `verdict='fail'`, 2 rows, `first_failure_category` set.
- **VS4 scope-violation no retry:** `allowed_paths` excludes the file the inner writes → `verdict='scope-violation'`, exactly 1 attempt row (no retry).
- **VS5 A5 no-change:** check exits 0 but inner writes nothing (tree unchanged) → `verdict='fail'`, `failure_category='no-change'`, retry attempted (1→2 rows).
- **VS6 unverified:** task with `verify_profile=''` → delegates to inner, `unverified=$true`, no `verification` key semantics (result carries `unverified`).
- **VS7 evidence prompt:** assert `Format-VerifyEvidencePrompt` includes the failure category and the fix-in-place instruction and caps the excerpt.

Prefer the real `Invoke-VerificationContract` with argv `@('pwsh','-NoProfile','-File','<temp check>.ps1')` — hermetic and fast; use `BATON_VERIFY_TEST_HOOK` only where forcing a specific verdict sequence (VS2/VS3) is simpler than scripting the check's state.

Run: `pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1` and `scripts/test-verification-lib.ps1` — both exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/fleet-executor-lib.ps1 scripts/test-fleet-executor-lib.ps1 scripts/verification-lib.ps1 scripts/test-verification-lib.ps1
git commit -m "feat(verify): V2 part 2 — verifying spawner, one evidence retry, evidence artifacts, env-wrapper hardening (d082)"
```

---

## Task 3 — Report narration + docs + bootstrap check  [haiku]

**Files:**
- Modify: `scripts/conductor-lib.ps1` — `Format-VerificationSection` + call it from the report assembly (in `Complete-Run` where the report is built)
- Modify: `commands/go.md` — document `-Verify`, `verify_profile`/`allowed_paths`, the `verification-failed` status, evidence artifacts
- Modify: `scripts/test-conductor-lib.ps1` — narration test
- (No bootstrap change: `verification-lib.ps1` and `fleet-executor-lib.ps1` are already in the deploy manifest from V1/d078. Confirm with a grep and assert.)

- [ ] **Step 1: `Format-VerificationSection`** (append after `Format-AcceptanceSection` in conductor-lib.ps1)

```powershell
function Format-VerificationSection {
    <# The Gemini CLI narration block (adjudication A2): per verified task, route ->
       worker -> check -> retry -> proves, read from tasks/<id>/verification.json.
       Returns '' when no task was verified (section omitted). #>
    param([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][hashtable]$Plan)
    $lines = [System.Collections.ArrayList]@()
    foreach ($t in @($Plan.tasks)) {
        $vp = Join-Path $RunDir "tasks/$($t.id)/verification.json"
        if (-not (Test-Path -LiteralPath $vp)) { continue }
        try { $v = Get-Content -Raw -LiteralPath $vp | ConvertFrom-Json } catch { continue }
        $mark = if ([string]$v.verdict -eq 'pass') { "PASS (grade $($v.grade))" } else { "FAIL ($($v.failure_category))" }
        $retry = if ($v.retried) { ' after 1 retry' } else { '' }
        [void]$lines.Add("- $($t.id): $mark$retry — proves: $($v.proves)")
    }
    if (@($lines).Count -eq 0) { return '' }
    return "## Verification`n" + (@($lines) -join "`n")
}
```

Wire it into the report: in `Complete-Run`, after the report string is built (where `Format-AcceptanceSection` is appended), append `Format-VerificationSection -RunDir $RunDir -Plan $Plan` when non-empty. Match the existing acceptance-section append idiom exactly (read `Complete-Run` for the precise pattern; the section is appended to the `report` before the ordered-dict result is returned).

- [ ] **Step 2: Narration test** (append to test-conductor-lib.ps1)

```powershell
# VF8: verification.json under tasks/<id>/ renders a ## Verification report section
$d = New-VfRun
$td = Join-Path $d 'tasks/t1'; New-Item -ItemType Directory -Force $td | Out-Null
@{ verdict='pass'; grade='strong'; failure_category=''; proves='the suite passes'; retried=$true } | ConvertTo-Json | Set-Content (Join-Path $td 'verification.json') -Encoding utf8NoBOM
$plan = & $vfPlan 'g'
$sec = Format-VerificationSection -RunDir $d -Plan $plan
Assert "VF8a section present" ($sec -match '## Verification')
Assert "VF8b pass+grade rendered" ($sec -match 'PASS \(grade strong\)')
Assert "VF8c retry noted" ($sec -match 'after 1 retry')
Assert "VF8d proves rendered" ($sec -match 'the suite passes')
$empty = Format-VerificationSection -RunDir (New-VfRun) -Plan $plan
Assert "VF8e no verified task -> empty" ($empty -eq '')
Remove-Item $d -Recurse -Force
```

- [ ] **Step 3: Docs** — add a "Verified labor (`-Verify`)" subsection to `commands/go.md`: what `-Verify` does (freeze-then-check-then-one-retry, fail-closed), the two task fields (`verify_profile` names a profile in the repo's committed `.baton/verification.json`; `allowed_paths` constrains the task diff), the `verification-failed` terminal status, and the `tasks/<id>/{contract.json,attempts.jsonl,verification.json,check-output.txt}` evidence tree. Keep it tight, matching the file's existing style.

- [ ] **Step 4: Bootstrap assert** — grep confirms `verification-lib.ps1` + `fleet-executor-lib.ps1` are in `bootstrap.ps1`'s deploy list (they are, from V1/d078). No new deploy entry. Run `pwsh -NoProfile -File scripts/test-bootstrap.ps1` → exit 0 (regression).

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1 commands/go.md
git commit -m "feat(verify): V2 part 3 — report narration, go.md docs (d082)"
```

---

## Final gate (controller, after Task 3)

1. Full sweep from `D:\Dev\baton-vl-v2`: `test-conductor-lib.ps1`, `test-fleet-executor-lib.ps1`, `test-verification-lib.ps1`, `test-fleet-go-execute.ps1`, `test-plan-gate-lib.ps1`, `test-gate-lib.ps1`, `test-fleet-dispatch.ps1`, `test-bootstrap.ps1` — all exit 0.
2. Single Opus whole-branch review (trust-boundary hostile again: preflight fail-closed truly blocks spend; retry is exactly once; scope/oracle violation never retries; A5 no-change enforced; default path byte-for-byte unchanged; evidence artifacts complete; the env-wrapper fix doesn't over-block).
3. Live smoke (opt-in, box-private): a scratch repo with a committed `.baton/verification.json` (a trivial `pytest`/`pwsh-suite` profile) through `/baton:go -Execute -Verify` — first-attempt fail → evidence retry → verified pass, evidence tree present, branch left for merge.
4. Push; PR; **merge only on Kevin's word.**

## Self-review

- **Spec coverage (d082 §3 V2):** normalization ✓(T1.1) · preflight freeze/plan-invalid ✓(T1.3,T1.6) · verify-after-attempt ✓(T2.3) · outcome precedence ✓(T2.3 retryable set + scope/oracle no-retry) · A5 non-empty diff ✓(T2.3 no-change) · one retry same worktree ✓(T2.3) · verification-failed terminal ✓(T1.4) · evidence artifacts tasks/<id>/{contract,attempts,verification,check-output} ✓(V1 writes contract+check-output; T2 writes attempts+verification) · six event kinds ✓(T1.4 emits 5 + T2 timing; started noted) · narration ✓(T3.1) · opt-in -Verify default-unchanged ✓(VF7) · test seams ✓(BATON_GO_TEST_VERIFY/BATON_VERIFY_TEST_HOOK) · env-wrapper carry-forward ✓(T2.4).
- **Placeholder scan:** none — every step carries code or an exact command.
- **Type consistency:** the augmented spawner result keys (`verification`, `unverified`, `retried` via `verification.retried`) are produced in T2.3 and consumed in T1.4/T3.1 identically; `verification` sub-keys (verdict/grade/failure_category/first_failure_category/proves/output_path/retried) match across producer, consumer, and narration. `Invoke-VerificationContract` param names (`-DiffFiles/-AllowedPaths/-ExpectPreHashes/-ProtectedPreHashes/-RunTaskDir/-WorktreeRoot`) verified against merged V1 source.
- **Note:** `task-verification-started` is recorded as attempt timing in evidence rather than a run event (the terminal-outcome events carry the legible trail); acceptable per §10 which lists it as an event — if a strict reviewer wants the run event, emit it in T1.4 before `& $Spawner`. Flagged for the reviewer, not blocking.
