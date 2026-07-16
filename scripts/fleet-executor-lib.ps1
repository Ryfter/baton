#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fleet Labor Slice 2 (d078): agentic-executor primitives. A throwaway git worktree
  receives the fleet's edits; proof that labor happened is the worktree's diff
  growing (proof-by-diff — no model prose is ever parsed). The run branch is always
  left for the human to merge; nothing here merges or touches the user's checkout.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"     # Invoke-Fleet for the spawner dispatch
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability for the spawner routing
. "$PSScriptRoot/verification-lib.ps1"   # Invoke-VerificationContract etc. (d082 V2)

function New-RunWorktree {
    <# Throwaway worktree at <repo-parent>/.baton-worktrees/<run-id> on a new branch
       baton/run-<run-id> off the repo's current HEAD. Returns
       @{ worktree; branch; base_sha }. Throws with a clear message on any git
       failure — callers surface it and exit 2. #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RunId
    )
    & git -C $RepoPath rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "execute: '$RepoPath' is not a git repository" }
    $base = [string](& git -C $RepoPath rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($base)) {
        throw "execute: '$RepoPath' has no commits (HEAD does not resolve)"
    }
    $base = $base.Trim()
    $resolvedRepo = (Resolve-Path -LiteralPath $RepoPath).Path
    $wtRoot = Join-Path (Split-Path $resolvedRepo -Parent) '.baton-worktrees'
    New-Item -ItemType Directory -Force -Path $wtRoot | Out-Null
    $wt = Join-Path $wtRoot $RunId
    $branch = "baton/run-$RunId"
    $out = & git -C $RepoPath worktree add -b $branch $wt HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { throw "execute: git worktree add failed: $(@($out) -join ' ')" }
    return @{ worktree = $wt; branch = $branch; base_sha = $base }
}

function Get-RunDiff {
    <# Cumulative unified diff of the worktree vs BaseSha, INCLUDING new/untracked
       files: everything is staged first (`add -A`) so `git diff <sha>` sees them —
       the worktree is throwaway, so staging is harmless (spec §7 mandates new files
       appear in changes.diff). Empty string when nothing changed or on git failure
       (fail-open: an unreadable diff means "no provable work", never a crash). #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$BaseSha
    )
    & git -C $Worktree add -A 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return '' }
    $out = & git -C $Worktree diff $BaseSha 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (@($out) -join "`n")
}

function Get-WorktreeTreeSha {
    <# SHA of the worktree's current content tree (index tree after `add -A`, via
       `git write-tree` — plumbing only, no commit is created). Two equal shas =
       the tree did not change between calls; this is the spawner's "diff grew"
       primitive, robust even when an instrument makes its own commits. $null on
       git failure. #>
    param([Parameter(Mandatory)][string]$Worktree)
    & git -C $Worktree add -A 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    $sha = [string](& git -C $Worktree write-tree 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) { return $null }
    return $sha.Trim()
}

function Test-ProviderAgentic {
    <# Edit-eligibility (d078, concept-anchored per d025): the optional `agentic`
       field is authoritative when present; absent, eligibility is inferred from
       platform ∈ {claude, codex, gemini}. Chat/local/github providers are filtered
       out of edit tasks (their diff-apply path is Slice 3). Accepts either a fleet
       provider hashtable or a Select-Capability candidate object. #>
    param([Parameter(Mandatory)]$Provider)
    if ($null -ne $Provider.agentic) { return [bool]$Provider.agentic }
    return (([string]$Provider.platform) -in @('claude', 'codex', 'gemini'))
}

function Test-ProviderDepthTier {
    <# True only when Invoke-Fleet's CLI path can apply this named tier: the
       provider defines a safe, non-empty fragment and its template consumes it. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][ValidateSet('low','med','high')][string]$DepthTier
    )
    if ([string]$Provider.kind -ne 'cli') { return $false }
    if (-not ([string]$Provider.command_template).Contains('{{tier_args}}')) { return $false }
    if (-not $Provider.ContainsKey("tier_$DepthTier")) { return $false }
    return -not [string]::IsNullOrWhiteSpace((Get-FleetProviderTier -Provider $Provider -Tier $DepthTier))
}

function Remove-RunWorktree {
    <# Explicit discard of the worktree DIRECTORY only. The run branch is
       intentionally KEPT so the human can still inspect or merge the work.
       Throws on git failure. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$Force
    )
    $extra = @(); if ($Force) { $extra += '--force' }
    $out = & git -C $RepoPath worktree remove @extra $Worktree 2>&1
    if ($LASTEXITCODE -ne 0) { throw "execute: git worktree remove failed: $(@($out) -join ' ')" }
}

function Resolve-TaskDepthPolicy {
    <# Pure d086 PR-B policy: resolve planner/operator stakes into a generic
       provider depth, router objective, and effective per-task cost ceiling. #>
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][ValidateSet('local','free','paid')][string]$RunMaxCostTier,
        [ValidateSet('low','standard','high')][string]$StakesOverride
    )
    $hasOverride = $PSBoundParameters.ContainsKey('StakesOverride')
    $stakes = if ($hasOverride) { $StakesOverride }
              elseif ([string]::IsNullOrWhiteSpace([string]$Task.stakes)) { 'standard' }
              else { [string]$Task.stakes }
    $basis = if ($hasOverride) { "operator override: --stakes $StakesOverride" }
             elseif ([string]::IsNullOrWhiteSpace([string]$Task.stakes)) { 'legacy plan omitted stakes' }
             else { [string]$Task.stakes_basis }
    $estimate = if ([string]$Task.est_cost_tier -in @('local','free','paid')) {
        [string]$Task.est_cost_tier
    } else { $RunMaxCostTier }
    $tiers = @('local','free','paid')
    $minTier = {
        param([string[]]$Values)
        $rank = ($Values | ForEach-Object { [array]::IndexOf($tiers, $_) } | Measure-Object -Minimum).Minimum
        return $tiers[[int]$rank]
    }.GetNewClosure()

    switch ($stakes) {
        'low' {
            $depth = 'low'; $mode = 'economy'
            $cap = & $minTier @($RunMaxCostTier, 'free', $estimate)
        }
        'high' {
            $depth = 'high'; $mode = 'champion'; $cap = $RunMaxCostTier
        }
        default {
            $stakes = 'standard'; $depth = 'med'; $mode = 'economy'
            $cap = & $minTier @($RunMaxCostTier, $estimate)
        }
    }
    return [ordered]@{
        stakes = $stakes
        stakes_basis = $basis
        depth_tier = $depth
        selection_mode = $mode
        max_cost_tier = $cap
    }
}

function New-AgenticSpawner {
    <# Factory: returns a scriptblock matching Invoke-Conductor's -Spawner contract
       (param($task) -> @{ ok; spend; chose; why; alternatives }). Per task: route the
       capability, FILTER to edit-eligible providers, dispatch with cwd = the worktree
       (Push-Location/Pop-Location around the call), and prove labor by the worktree
       content tree changing (proof-by-diff, d078). Precedence: nonzero exit -> fail;
       tree changed -> ok; exit 0 + no change -> ok with why 'no changes'.
       -Dispatcher injects a fake instrument for hermetic tests. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$RunDir,
        [scriptblock]$Dispatcher,
        [ValidateSet('low','standard','high')][string]$StakesOverride
    )
    $hasStakesOverride = $PSBoundParameters.ContainsKey('StakesOverride')
    return {
        param($task)
        $cap = if ($task.capability) { $task.capability } else { 'reasoning' }
        $policyArgs = @{ Task = $task; RunMaxCostTier = $MaxCostTier }
        if ($hasStakesOverride) { $policyArgs.StakesOverride = $StakesOverride }
        $policy = Resolve-TaskDepthPolicy @policyArgs
        # Select-Capability returns via `,([object[]]$ranked)` (comma-operator array
        # preservation, correct for callers doing a direct `$x = Select-Capability ...`
        # assignment with 0/1 results). Piping that return straight into Where-Object
        # does NOT unroll it — PowerShell hands the whole candidate array to Where-Object
        # as a single $_. Capture to a plain variable first (direct assignment unwraps
        # correctly) and filter the variable, not the call, to get real per-candidate
        # enumeration.
        $raw = Select-Capability -Capability $cap -MaxCostTier $policy.max_cost_tier `
            -SelectionMode $policy.selection_mode -FleetPath $FleetPath -ToolsPath $ToolsPath
        # Edit dispatch is fleet-only (Invoke-Fleet resolves names against fleet.yaml);
        # tools.yaml candidates cannot take edit dispatch even if they infer agentic
        # via a platform field, so require source='fleet' before the agentic test.
        $cands = @($raw | Where-Object { ($null -ne $_) -and ([string]$_.source -eq 'fleet') -and (Test-ProviderAgentic -Provider $_) })
        if ($cands.Count -lt 1) {
            return @{
                ok = $false; spend = 0.0; chose = ''; why = "no edit-capable candidate for '$cap'"; alternatives = @()
                stakes = $policy.stakes; stakes_basis = $policy.stakes_basis; depth_tier = $policy.depth_tier
                selection_mode = $policy.selection_mode; tier_cap = $policy.max_cost_tier
                depth_applied = $false; selected_cost_tier = ''
            }
        }
        $pick = $cands[0]
        $alts = @($cands | Select-Object -Skip 1 | ForEach-Object { $_.name })
        $provider = Get-FleetProvider -Name ([string]$pick.name) -Path $FleetPath
        $depthApplied = ($null -ne $provider) -and (Test-ProviderDepthTier -Provider $provider -DepthTier $policy.depth_tier)
        $resultBase = @{
            stakes = $policy.stakes; stakes_basis = $policy.stakes_basis; depth_tier = $policy.depth_tier
            selection_mode = $policy.selection_mode; tier_cap = $policy.max_cost_tier
            depth_applied = [bool]$depthApplied; selected_cost_tier = [string]$pick.cost_tier
        }
        $prompt = "Task: $($task.desc)"
        $preTree = Get-WorktreeTreeSha -Worktree $Worktree
        Push-Location -LiteralPath $Worktree
        $dispatchErr = $null
        try {
            $res = if ($Dispatcher) { & $Dispatcher $pick $prompt $policy.depth_tier }
                   else { Invoke-Fleet -Name $pick.name -Prompt $prompt -Path $FleetPath -Tier $policy.depth_tier -NoJournal }
        } catch {
            $dispatchErr = $_
            $res = $null
        } finally { Pop-Location }
        if ($dispatchErr) {
            return $resultBase + @{ ok = $false; spend = 0.0; chose = $pick.name; why = "$($pick.name): dispatch error: $($dispatchErr.Exception.Message)"; alternatives = $alts }
        }
        $postTree = Get-WorktreeTreeSha -Worktree $Worktree
        $grew = ($null -ne $preTree) -and ($null -ne $postTree) -and ($preTree -ne $postTree)
        # Best-effort per-task incremental diff for the report; never fails the task.
        if ($RunDir -and $grew) {
            try {
                $tasksDir = Join-Path $RunDir 'tasks'
                New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
                $taskDiff = @(& git -C $Worktree diff $preTree $postTree 2>$null) -join "`n"
                Set-Content -LiteralPath (Join-Path $tasksDir "$($task.id).diff") -Value $taskDiff -Encoding utf8NoBOM
            } catch { }
        }
        if ([int]$res.exit_code -ne 0) {
            return $resultBase + @{ ok = $false; spend = 0.0; chose = $pick.name; why = "$($pick.name): exit $($res.exit_code)"; alternatives = $alts }
        }
        if ($grew) {
            return $resultBase + @{ ok = $true; spend = 0.0; chose = $pick.name; why = "routed $cap -> $($pick.name); worktree diff grew"; alternatives = $alts }
        }
        return $resultBase + @{ ok = $true; spend = 0.0; chose = $pick.name; why = "$($pick.name): no changes"; alternatives = $alts }
    }.GetNewClosure()
}

function Format-VerifyEvidencePrompt {
    <# The bounded retry brief (codex-ringer §7): original task + deterministic failure
       category + a capped raw-output excerpt + the fix-in-place instruction. No restart,
       no scope broadening. The WHOLE prompt is bounded to <=965 UTF-8 bytes ($MaxBytes)
       so the one retry survives inline-interpolation instruments (e.g. agy) that dispatch
       the prompt as a single shell arg under the project's hard 965-byte ceiling. The
       excerpt takes only the byte budget the fixed parts leave; a long task desc is
       tail-truncated before the prompt is ever allowed to exceed the ceiling. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskDesc,
        [Parameter(Mandatory)][hashtable]$Verification,
        [string]$OutputPath = '',
        [int]$MaxBytes = 900
    )
    $enc = [System.Text.Encoding]::UTF8
    # Budget the desc first: it must not itself consume the whole ceiling. Reserve room
    # for the boilerplate + failure line + a minimum excerpt floor.
    $boiler = @"
{0}

--- Your previous attempt did not pass verification. Fix the EXISTING work; do not
restart from scratch and do not broaden the change beyond the task's scope. ---
Failure: {1}
Check output:
{2}
"@
    $fail = [string]$Verification.failure_category
    # Bytes the template consumes with empty desc/excerpt — measure so the two variable
    # parts share exactly the remaining budget.
    $fixedBytes = $enc.GetByteCount(($boiler -f '', $fail, ''))
    $descCap = [Math]::Max(120, [int](($MaxBytes - $fixedBytes) * 0.55))
    $desc = $TaskDesc
    while ($enc.GetByteCount($desc) -gt $descCap -and $desc.Length -gt 0) {
        $desc = $desc.Substring(0, [Math]::Max(0, $desc.Length - 16))
    }
    $excerptCap = $MaxBytes - $fixedBytes - $enc.GetByteCount($desc)
    if ($excerptCap -lt 0) { $excerptCap = 0 }
    $excerpt = ''
    if ($OutputPath -and (Test-Path -LiteralPath $OutputPath) -and $excerptCap -gt 0) {
        $raw = Get-Content -LiteralPath $OutputPath -Raw
        if ($null -eq $raw) { $raw = '' }
        while ($enc.GetByteCount($raw) -gt $excerptCap -and $raw.Length -gt 0) {
            $raw = $raw.Substring(0, [Math]::Max(0, $raw.Length - 16))
        }
        $excerpt = $raw
    }
    $prompt = $boiler -f $desc, $fail, $excerpt
    # Final safety clamp: if multibyte rounding pushed us over, trim the tail to fit.
    while ($enc.GetByteCount($prompt) -gt $MaxBytes -and $prompt.Length -gt 0) {
        $prompt = $prompt.Substring(0, [Math]::Max(0, $prompt.Length - 8))
    }
    return $prompt
}

function Add-VerifyAttemptRow {
    <# Append one attempt row to <RunTaskDir>/attempts.jsonl (codex-ringer §10). One
       compact JSON object per line; utf8NoBOM append. #>
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

function New-VerifyingSpawner {
    <# Wrap an inner agentic spawner with the d082 verification sub-lifecycle. Per task:
       no verify_profile / no frozen contract -> delegate + mark unverified. Otherwise:
       freeze pre-hashes just before the attempt, run the inner attempt, compute the task
       diff, run the frozen contract, apply outcome precedence (codex-ringer §7 + A5
       non-empty diff), and on a check-fail/timeout/no-change do exactly ONE
       evidence-informed retry in the SAME worktree. Writes attempts.jsonl +
       verification.json under tasks/<id>/. Returns the augmented spawner result Task 1
       consumes. Never a third attempt; scope/oracle violation fails closed with no retry;
       a verification pass despite an inner nonzero exit stands (the warning rides
       inner.why into the augmented `why`). #>
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

        # A5 baseline (review I1): freeze the PRE-TASK state ONCE, before attempt 1, and
        # judge BOTH attempts against it — codex-ringer §7 / design A5 both specify the
        # pre-task baseline. Re-freezing per attempt judged attempt 2 against attempt 1's
        # end-state, which false-passed an add-then-revert retry (net-zero vs base — the
        # exact A5 loophole) and false-failed a legitimate no-further-edit repair.
        $protPre0   = Get-VerifyPathHashes -WorktreeRoot $Worktree -Paths @($contract.protected_paths)
        $expectPre0 = Get-VerifyPathHashes -WorktreeRoot $Worktree -Paths @($contract.expect_files)
        $taskStartTree = Get-WorktreeTreeSha -Worktree $Worktree

        $runAttempt = {
            param($atask, $attemptNo)
            $ir = & $InnerSpawner $atask
            $postTree = Get-WorktreeTreeSha -Worktree $Worktree
            # Cumulative vs the frozen task-start tree — never vs the previous attempt.
            $grew = ($null -ne $taskStartTree) -and ($null -ne $postTree) -and ($taskStartTree -ne $postTree)
            $diffFiles = @()
            if ($grew) { $diffFiles = @(& git -C $Worktree diff --name-only $taskStartTree $postTree 2>$null | Where-Object { $_ }) }
            # Test hook: a hermetic override of the real runner (BATON_VERIFY_TEST_HOOK
            # points at a file defining Invoke-TestVerify -Task -Attempt -Grew).
            if ($env:BATON_VERIFY_TEST_HOOK -and (Test-Path -LiteralPath $env:BATON_VERIFY_TEST_HOOK)) {
                . $env:BATON_VERIFY_TEST_HOOK
                $v = Invoke-TestVerify -Task $atask -Attempt $attemptNo -Grew $grew
            } else {
                $v = Invoke-VerificationContract -Contract $contract -WorktreeRoot $Worktree -RunTaskDir $taskDir `
                        -DiffFiles $diffFiles -AllowedPaths $allowed -ExpectPreHashes $expectPre0 -ProtectedPreHashes $protPre0
            }
            # A5 (adjudication): an edit task's PASS also requires a non-empty task diff
            # vs the pre-task baseline. A "passing" check over a tree unchanged since task
            # start is demoted to a retry-eligible no-change failure (closes the V1
            # zero-change loophole on BOTH attempts).
            if ([string]$v.verdict -eq 'pass' -and -not $grew) {
                $v.verdict = 'fail'; $v.ok = $false; $v.grade = 'invalid'; $v.failure_category = 'no-change'
            }
            return @{ v = $v; inner = $ir; grew = $grew }
        }
        # NOTE: no .GetNewClosure() here — a nested GetNewClosure does not re-capture the
        # enclosing spawner-closure's variables ($Worktree/$InnerSpawner/$taskStartTree),
        # so it would run them empty. $runAttempt is invoked in this same scope, so plain
        # dynamic scoping resolves the pre-task baseline + $contract/$taskDir/$allowed from
        # the live parent.

        $a1 = & $runAttempt $task 1
        Add-VerifyAttemptRow -RunTaskDir $taskDir -Attempt 1 -Row @{
            worker = [string]$a1.inner.chose; worker_ok = [bool]$a1.inner.ok; diff_grew = $a1.grew
            verdict = $a1.v.verdict; grade = $a1.v.grade; failure_category = $a1.v.failure_category; duration_ms = $a1.v.duration_ms
        }
        $final = $a1
        $retried = $false
        $firstFail = [string]$a1.v.failure_category
        # Spend accrues across ALL attempts (review M2) — a retry's labor must not drop
        # attempt 1's spend once realized cost lands via the Get-RunCost seam.
        $totalSpend = [double]$a1.inner.spend

        # Retry precedence: pass -> done. scope/oracle violation or spawn/infra failure ->
        # fail-closed, NO retry. check-failed / check-timeout / no-change / expected-file-*
        # -> exactly one evidence-informed retry in the SAME worktree.
        $retryable = @('check-failed', 'check-timeout', 'no-change', 'expected-file-missing', 'expected-file-empty', 'expected-file-unchanged')
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
            $totalSpend += [double]$a2.inner.spend
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
        $result = @{
            ok = $passed; spend = [double]$totalSpend; chose = [string]$final.inner.chose
            why = $why; alternatives = @($final.inner.alternatives)
            verification = $verObj; unverified = $false
        }
        foreach ($field in @('stakes','stakes_basis','depth_tier','depth_applied','selection_mode','tier_cap','selected_cost_tier')) {
            $hasField = if ($final.inner -is [System.Collections.IDictionary]) {
                $final.inner.Contains($field)
            } else {
                $null -ne $final.inner.PSObject.Properties[$field]
            }
            if ($hasField) { $result[$field] = $final.inner.$field }
        }
        return $result
    }.GetNewClosure()
}
