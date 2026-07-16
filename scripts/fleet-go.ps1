#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:go runner. Turns a natural-language goal into a planned, guarded,
  full-auto run: plan DAG -> walk under budget + destructive guards -> ledgers +
  report under BATON_HOME/runs/<run-id>/.
.NOTES
  The Claude session is the live Conductor; this CLI is its deterministic engine.
#>
param(
    [string]$Goal,
    [string]$Text,
    [double]$Budget,
    [switch]$Json,
    [string]$GateArtifact,
    [string]$GateDiff,
    [string]$Project,
    [switch]$Execute,
    [string]$RepoPath,
    [switch]$Verify,
    [switch]$PlanGate,
    [switch]$NoPlanGate,
    [switch]$NoGate,
    [switch]$NoVerify,
    [Alias('StakesOverride')][ValidateSet('low','standard','high')][string]$Stakes,
    [string[]]$PlanReviewers,
    [bool]$PlanRevise = $true,
    [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$ToolsPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'tools.yaml' } else { Join-Path $HOME '.baton/tools.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'conductor-lib.ps1')
try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }
. (Join-Path $PSScriptRoot 'registry-lib.ps1')

$targetFolder = $null
if (-not [string]::IsNullOrWhiteSpace($Project)) {
    $resolved = Resolve-ProjectTarget -Slug $Project
    if ($resolved.status -eq 'resolved') {
        $targetFolder = $resolved.folder
    } elseif ($resolved.status -eq 'unknown') {
        [Console]::Error.WriteLine("No project matches --project '$Project'. Run /baton:project list to see registered projects.")
        exit 2
    }
}

$theGoal = @($Goal, $Text | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($theGoal)) { [Console]::Error.WriteLine('Provide a goal via -Goal "<text>" (or -Text).'); exit 2 }
if ($PlanGate -and $NoPlanGate) { [Console]::Error.WriteLine('Cannot combine -PlanGate with -NoPlanGate.'); exit 2 }
if ($Verify -and $NoVerify) { [Console]::Error.WriteLine('Cannot combine -Verify with -NoVerify.'); exit 2 }
if ($NoGate -and ($PSBoundParameters.ContainsKey('GateArtifact') -or $PSBoundParameters.ContainsKey('GateDiff'))) {
    [Console]::Error.WriteLine('Cannot combine -NoGate with -GateArtifact or -GateDiff.')
    exit 2
}

$planGateEnabled = $PlanGate -or ($Execute -and -not $NoPlanGate)
$gateEnabled = (-not $NoGate) -and (
    $Execute -or
    $PSBoundParameters.ContainsKey('GateArtifact') -or
    $PSBoundParameters.ContainsKey('GateDiff')
)
$verifyEnabled = $Verify -or ($Execute -and -not $NoVerify)

$runDir = Initialize-RunDir -RunId (New-RunId)

$go = @{ Goal = $theGoal; RunDir = $runDir; MaxCostTier = $MaxCostTier; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
if ($PSBoundParameters.ContainsKey('Budget')) { $go['BudgetCap'] = $Budget }
if ($PSBoundParameters.ContainsKey('Stakes')) { $go['StakesOverride'] = $Stakes }

# Test seams: a canned plan and/or forced-success spawner so the suite never calls a model.
if ($env:BATON_GO_TEST_PLAN) {
    $canned = $env:BATON_GO_TEST_PLAN
    $go['Planner'] = { param($g) $p = ConvertTo-PlanObject -RawStdout $canned; if ($p) { $p.goal = $g }; $p }.GetNewClosure()
}
if ($env:BATON_GO_TEST_SPAWN -eq '1') {
    $go['Spawner'] = { param($task) @{ ok = $true; spend = 0.0; chose = 'test-stub'; why = "ran $($task.id)"; alternatives = @() } }
}

if ($PSBoundParameters.ContainsKey('GateArtifact')) { $go['GateArtifact'] = $GateArtifact }
if ($PSBoundParameters.ContainsKey('GateDiff')) { $go['GateDiff'] = $GateDiff }
# Test seam: a canned gate verdict so the suite never calls real reviewers.
if ($env:BATON_GO_TEST_GATE) {
    $cannedVerdict = $env:BATON_GO_TEST_GATE
    $go['Gater'] = {
        param($art, $goal)
        $isDegraded = $cannedVerdict -eq 'degraded'
        @{
            verdict = if ($isDegraded) { 'accept' } else { $cannedVerdict }
            reason = 'test-stub verdict'
            counts = @{ critical = 0; important = 0; minor = 0 }
            polish_brief = 'test brief'
            findings = @()
            reviews = @()
            unparsed = @()
            degraded = $isDegraded
        }
    }.GetNewClosure()
    if (-not $go.ContainsKey('GateArtifact')) { $go['GateArtifact'] = 'test artifact' }
}

if ($gateEnabled) {
    $go['AcceptanceGate'] = $true
    if ($Execute) {
        $go['AcceptancePanel'] = $true
        $go['AcceptanceFailLoud'] = $true
    }
} elseif ($Execute) {
    # Bind false explicitly so Invoke-Conductor can distinguish --no-gate from
    # legacy direct callers whose DiffProvider/artifact historically auto-gates.
    $go['AcceptanceGate'] = $false
}

# Plan Gate (d080, Slice 2): opt-in peer once-over of the plan DAG BEFORE the walk.
# -PlanReviewers accepts either a native array (-PlanReviewers a,b) or a single
# comma-joined string (-PlanReviewers "a,b"); both normalize to a trimmed list.
# -PlanRevise defaults $true; pass -PlanRevise:$false to skip the one auto-revise pass.
if ($planGateEnabled) {
    $go['PlanGate'] = $true
    if ($Execute) { $go['PlanGateFailLoud'] = $true }
    $reviewers = @()
    foreach ($r in @($PlanReviewers)) { $reviewers += (([string]$r) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($reviewers.Count) { $go['PlanReviewers'] = $reviewers }
    $go['PlanRevise'] = $PlanRevise
    # Test seam: dot-source a file defining Invoke-TestPlanGateDispatch($name,$prompt),
    # then feed it as the gate's reviewer dispatcher (mirrors BATON_GO_TEST_EXEC_DISPATCHER).
    if ($env:BATON_GO_TEST_PLANGATE) {
        . $env:BATON_GO_TEST_PLANGATE
        $go['PlanGateDispatcher'] = { param($n, $p) Invoke-TestPlanGateDispatch $n $p }
    }
}

if ($env:BATON_GO_TEST_VERIFY) {
    # Dot-source a file defining Invoke-TestVerify($task, $worktree) -> a verification
    # result hashtable; New-VerifyingSpawner honors it instead of the real runner.
    $env:BATON_VERIFY_TEST_HOOK = $env:BATON_GO_TEST_VERIFY
}

# Execute mode (Slice 2, d078): agentic labor into a throwaway worktree. The
# spawner routes each task to an edit-eligible instrument running with cwd =
# the worktree; the DiffProvider feeds the produced diff to the acceptance
# gate. -Execute owns the spawner: it overrides the BATON_GO_TEST_SPAWN stub
# when both are set. The run branch is ALWAYS left for the human to merge.
$wt = $null
if ($Execute) {
    . (Join-Path $PSScriptRoot 'fleet-executor-lib.ps1')
    $repo = if ($PSBoundParameters.ContainsKey('RepoPath') -and $RepoPath) { $RepoPath }
            elseif ($targetFolder) { $targetFolder }
            else { (Get-Location).Path }
    try { $wt = New-RunWorktree -RepoPath $repo -RunId (Split-Path $runDir -Leaf) }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
    $spawnArgs = @{ Worktree = $wt.worktree; FleetPath = $FleetPath; ToolsPath = $ToolsPath; MaxCostTier = $MaxCostTier; RunDir = $runDir }
    if ($env:BATON_GO_TEST_EXEC_DISPATCHER) {
        # Hermetic seam: dot-source a file defining Invoke-TestExecDispatcher.
        . $env:BATON_GO_TEST_EXEC_DISPATCHER
        $spawnArgs.Dispatcher = { param($pick, $prompt) Invoke-TestExecDispatcher -Pick $pick -Prompt $prompt }
    }
    $go['Spawner'] = New-AgenticSpawner @spawnArgs
    $go['DiffProvider'] = { Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha }.GetNewClosure()
    $go['NormalizeMissingStakes'] = $true
    if ($verifyEnabled) {
        # Shared frozen-contracts map: the preflight closure populates+validates it from
        # the base revision; the verifying spawner reads it per task. Both close over the
        # same hashtable reference (built here so they share it).
        $frozen = @{}
        $go['Verify'] = $true
        $go['VerifyPreflight'] = {
            param($plan)
            foreach ($tk in @($plan.tasks)) {
                $prof = [string]$tk.verify_profile
                if (($tk.capability -in @('code-gen','code-transform')) -and [string]::IsNullOrWhiteSpace($prof)) {
                    return @{
                        ok = $false
                        reason = "task $($tk.id) ($($tk.capability)) needs a verify_profile; add one or re-run with --no-verify"
                    }
                }
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
}

if ($targetFolder) { Push-Location -LiteralPath $targetFolder }
try {
    $result = Invoke-Conductor @go
} finally {
    if ($targetFolder) { Pop-Location }
}

if ($Execute -and $wt) {
    if ($result.status -in @('plan-rejected','plan-gate-degraded')) {
        # The Plan Gate rejected BEFORE the walk. The worktree/branch were created up
        # front but are untouched by construction (the gate precedes any DAG walk /
        # labor), so discard both — a rejected run must leave nothing behind, and the
        # report must not advertise a dead branch. Best-effort + guarded: cleanup
        # failure never crashes the run. ONLY on pre-labor Plan Gate stops; every other
        # status keeps the branch for the human to merge. Remove the worktree first, THEN delete the
        # branch (git refuses to delete a branch still checked out in a worktree).
        try { Remove-RunWorktree -Worktree $wt.worktree -RepoPath $repo -Force } catch { }
        try { & git -C $repo branch -D $wt.branch 2>$null | Out-Null } catch { }
        $result.branch = $null
        $result.worktree = $null
        $result.files_changed = 0
    } else {
        $result.branch = $wt.branch
        $result.worktree = $wt.worktree
        $changed = @(& git -C $wt.worktree diff --name-only $wt.base_sha 2>$null)
        $result.files_changed = @($changed | Where-Object { $_ }).Count
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    Write-Host $result.report
    Write-Host ""
    Write-Host "Status: $($result.status)  ·  spend $('{0:0.00}' -f $result.spend)  ·  $($result.run_dir)"
    if ($Execute -and $wt) {
        Write-Host "$($result.files_changed) file(s) changed on branch $($result.branch) (worktree: $($result.worktree)) — review and merge when ready; Baton never merges for you."
    }
    if ($result.status -like 'interrupted-*') {
        Write-Host "Paused at $($result.pending_task_id). Review, then resume to continue past this guard."
    }
    if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter }
}

$executeFailure = $Execute -and $result.status -in @(
    'failed', 'plan-failed', 'plan-invalid', 'plan-gate-degraded', 'plan-rejected',
    'verification-failed', 'acceptance-degraded', 'needs-polish', 'rejected'
)
if ($executeFailure) { exit 1 }
