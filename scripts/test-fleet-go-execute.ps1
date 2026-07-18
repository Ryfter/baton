#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "go-exec-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$saved = @{}
foreach ($k in 'BATON_HOME','BATON_GO_TEST_PLAN','BATON_GO_TEST_GATE','BATON_GO_TEST_SPAWN','BATON_GO_TEST_EXEC_DISPATCHER','BATON_GO_TEST_PLANGATE') {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
}
try {
    $env:BATON_HOME = Join-Path $tmpRoot 'baton-home'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    $env:BATON_GO_TEST_SPAWN = $null

    # target repo
    $repo = Join-Path $tmpRoot 'repo'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.email 'test@test.local'
    & git -C $repo config user.name 'baton-test'
    Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'hello' -Encoding utf8NoBOM
    $verifyDir = Join-Path $repo '.baton'
    New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
    @{ schema = 1; profiles = @{
        unit = @{ argv = @('git','status','--short'); proves = 'the worktree is readable' }
        failing = @{ argv = @('git','definitely-not-a-command'); proves = 'the forced failure is surfaced' }
    } } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $verifyDir 'verification.json') -Encoding utf8NoBOM
    & git -C $repo add -A 2>$null | Out-Null
    & git -C $repo commit -q -m 'init' 2>$null | Out-Null

    # temp fleet with one fake agentic provider
    Set-Content -LiteralPath (Join-Path $env:BATON_HOME 'fleet.yaml') -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-agentic
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    command_template: 'echo "{{prompt}}"'
  - name: plan-review-a
    kind: cli
    enabled: true
    cost_tier: free
    capabilities: [plan-review]
  - name: plan-review-b
    kind: cli
    enabled: true
    cost_tier: free
    capabilities: [plan-review]
'@

    # canned single-task plan + canned gate verdict
    # #101: default --execute hard-requires stakes; happy-path fixtures carry them.
    $profiledPlan = '{"run_id":"x","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"write feature","capability":"code-gen","depends_on":[],"est_cost_tier":"free","reversible":true,"verify_profile":"unit","stakes":"standard","stakes_basis":"ordinary bounded feature"}]}'
    $unprofiledPlan = '{"run_id":"x","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"write feature","capability":"code-gen","depends_on":[],"est_cost_tier":"free","reversible":true,"stakes":"standard","stakes_basis":"ordinary bounded feature"}]}'
    $missingStakesPlan = '{"run_id":"x","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"write feature","capability":"code-gen","depends_on":[],"est_cost_tier":"free","reversible":true,"verify_profile":"unit"}]}'
    $env:BATON_GO_TEST_PLAN = $profiledPlan
    $env:BATON_GO_TEST_GATE = 'accept'

    $pgAccept = Join-Path $tmpRoot 'pg-accept.ps1'
    Set-Content -LiteralPath $pgAccept -Encoding utf8NoBOM -Value @'
function Invoke-TestPlanGateDispatch($name, $prompt) {
    return @{ stdout = '[]'; stderr = ''; exit_code = 0 }
}
'@
    $env:BATON_GO_TEST_PLANGATE = $pgAccept

    # fake instrument: writes a file into its cwd (must be the worktree)
    $dispFile = Join-Path $tmpRoot 'disp.ps1'
    Set-Content -LiteralPath $dispFile -Encoding utf8NoBOM -Value @'
function Invoke-TestExecDispatcher {
    param($Pick, $Prompt)
    Set-Content -LiteralPath (Join-Path (Get-Location).Path 'feature.txt') -Value 'made by instrument' -Encoding utf8NoBOM
    return @{ stdout = 'done'; stderr = ''; exit_code = 0; duration_s = 0 }
}
'@
    $env:BATON_GO_TEST_EXEC_DISPATCHER = $dispFile

    # ---- happy path ----
    $raw = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -Json | Out-String
    $res = $raw | ConvertFrom-Json
    Check 'E1 run completed' ($res.status -eq 'completed')
    Check 'E2 result names a baton/run- branch' ($res.branch -like 'baton/run-*')
    Check 'E3 files_changed counted' ([int]$res.files_changed -ge 1)
    Check 'E4 changes.diff exists in run dir' (Test-Path (Join-Path $res.run_dir 'changes.diff'))
    Check 'E5 changes.diff carries the NEW file' ((Get-Content -Raw (Join-Path $res.run_dir 'changes.diff')) -match 'feature\.txt')
    Check 'E6 acceptance verdict landed' ($res.acceptance.verdict -eq 'accept')
    Check 'E7 user repo tree untouched' (-not (Test-Path (Join-Path $repo 'feature.txt')))
    Check 'E8 worktree has the instrument edit' (Test-Path (Join-Path ([string]$res.worktree) 'feature.txt'))
    $branches = [string](& git -C $repo branch --list 'baton/run-*')
    Check 'E9 run branch exists in the target repo' ($branches -match 'baton/run-')
    Check 'E9a plain execute defaulted Plan Gate on' (Test-Path (Join-Path $res.run_dir 'plan-review.json'))
    Check 'E9b plain execute defaulted verification on' (Test-Path (Join-Path $res.run_dir 'tasks/t1/verification.json'))
    # #101: plan with ALL stakes present → no missing-stakes policy event (happy path above).
    Check 'E9c-present plan with stakes present does not emit missing-stakes policy' (
        $res.status -eq 'completed' -and
        ((Get-Content -Raw (Join-Path $res.run_dir 'plan.json') | ConvertFrom-Json).tasks[0].stakes -eq 'standard') -and
        ((Get-Content -Raw (Join-Path $res.run_dir 'events.jsonl')) -notmatch 'missing stakes normalized to standard') -and
        ((Get-Content -Raw (Join-Path $res.run_dir 'events.jsonl')) -notmatch 'PLAN-INVALID .+ task\(s\) missing stakes'))

    # #101: default --execute + missing stakes → PLAN-INVALID loud halt (no normalize).
    $env:BATON_GO_TEST_PLAN = $missingStakesPlan
    $stderrMissing = Join-Path $tmpRoot 'missing-stakes.err'
    # plan-invalid is a provable pre-walk zero-labor stop, so its worktree/branch must be
    # discarded like plan-rejected — the halt must not linger a dead branch or advertise one.
    $wtDirMissing = Join-Path (Split-Path (Resolve-Path $repo).Path -Parent) '.baton-worktrees'
    $wtBeforeMissing = @(Get-ChildItem -Path $wtDirMissing -Directory -ErrorAction SilentlyContinue).Count
    $brBeforeMissing = @(& git -C $repo branch --list 'baton/run-*').Count
    $rawMissing = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -Json 2>$stderrMissing | Out-String
    $exitMissing = $LASTEXITCODE
    $resMissing = $rawMissing | ConvertFrom-Json
    $wtAfterMissing = @(Get-ChildItem -Path $wtDirMissing -Directory -ErrorAction SilentlyContinue).Count
    $brAfterMissing = @(& git -C $repo branch --list 'baton/run-*').Count
    $eventsMissing = Get-Content -Raw (Join-Path $resMissing.run_dir 'events.jsonl')
    $errMissing = if (Test-Path -LiteralPath $stderrMissing) { Get-Content -Raw -LiteralPath $stderrMissing } else { '' }
    Check 'E9c missing stakes HALTS loud (plan-invalid, named task, exit 1)' (
        $exitMissing -eq 1 -and $resMissing.status -eq 'plan-invalid' -and [double]$resMissing.spend -eq 0 -and
        $eventsMissing -match 'PLAN-INVALID .+ task\(s\) missing stakes: t1' -and
        $eventsMissing -match 'add stakes and stakes_basis' -and
        $eventsMissing -match '-NormalizeMissingStakes' -and
        $errMissing -match 'PLAN-INVALID .+ task\(s\) missing stakes: t1' -and
        $eventsMissing -notmatch 'missing stakes normalized to standard')
    Check 'E9c-clean plan-invalid nulls branch/worktree and leaves none behind' (
        [string]::IsNullOrEmpty([string]$resMissing.branch) -and
        [string]::IsNullOrEmpty([string]$resMissing.worktree) -and
        $brAfterMissing -eq $brBeforeMissing -and $wtAfterMissing -eq $wtBeforeMissing)
    $env:BATON_GO_TEST_PLAN = $profiledPlan

    # #101: opt-in normalize+warn retained (byte-for-byte policy message).
    $env:BATON_GO_TEST_PLAN = $missingStakesPlan
    $rawNorm = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -NormalizeMissingStakes -RepoPath $repo -Json | Out-String
    $resNorm = $rawNorm | ConvertFrom-Json
    Check 'E9c-norm -NormalizeMissingStakes proceeds with today''s warning' (
        $resNorm.status -eq 'completed' -and
        ((Get-Content -Raw (Join-Path $resNorm.run_dir 'plan.json') | ConvertFrom-Json).tasks[0].stakes -eq 'standard') -and
        ((Get-Content -Raw (Join-Path $resNorm.run_dir 'events.jsonl')) -match 'missing stakes normalized to standard.*applied policy: depth med, economy routing, capped by run and task cost tiers'))
    $env:BATON_GO_TEST_PLAN = $profiledPlan

    $stakesParam = (Get-Command "$PSScriptRoot/fleet-go.ps1").Parameters['Stakes']
    if ($null -ne $stakesParam) {
        # --stakes override on a plan that omits stakes still proceeds (override path).
        $env:BATON_GO_TEST_PLAN = $missingStakesPlan
        $rawStakes = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -Stakes high -NoPlanGate -NoGate -RepoPath $repo -Json | Out-String
        $resStakes = $rawStakes | ConvertFrom-Json
        $stakesTask = (Get-Content -Raw (Join-Path $resStakes.run_dir 'plan.json') | ConvertFrom-Json).tasks[0]
        $stakesDecision = (Get-Content -LiteralPath (Join-Path $resStakes.run_dir 'decisions.jsonl') | Select-Object -First 1) | ConvertFrom-Json
        Check 'E9h -Stakes overrides every task and records operator basis' (
            $resStakes.status -eq 'completed' -and $stakesTask.stakes -eq 'high' -and
            $stakesTask.stakes_basis -eq 'operator override: --stakes high' -and
            $stakesDecision.selection_mode -eq 'champion' -and $stakesDecision.depth_tier -eq 'high' -and
            $stakesDecision.stakes -eq 'high' -and
            $stakesDecision.stakes_basis -eq 'operator override: --stakes high' -and
            $stakesDecision.cost_tier -eq $stakesTask.est_cost_tier)
        Check 'E9i -StakesOverride is an alias for -Stakes' (@($stakesParam.Aliases) -contains 'StakesOverride')
        $env:BATON_GO_TEST_PLAN = $profiledPlan
    } else {
        Check 'E9h -Stakes overrides every task and records operator basis' $false
        Check 'E9i -StakesOverride is an alias for -Stakes' $false
    }

    # Reactive usage failover reaches the golden go path and its decisions/report.
    $savedFleetText = Get-Content -LiteralPath (Join-Path $env:BATON_HOME 'fleet.yaml') -Raw
    $savedDispatcherPath = $env:BATON_GO_TEST_EXEC_DISPATCHER
    $savedPlanText = $env:BATON_GO_TEST_PLAN
    try {
        Set-Content -LiteralPath (Join-Path $env:BATON_HOME 'fleet.yaml') -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_high: '--depth high'
  - name: worker-substitute
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_high: '--depth high'
'@
        $goFailoverDispatcher = Join-Path $tmpRoot 'disp-failover.ps1'
        Set-Content -LiteralPath $goFailoverDispatcher -Encoding utf8NoBOM -Value @'
$script:UsageFailoverCallCount = 0
function Invoke-TestExecDispatcher {
    param($Pick, $Prompt, $DepthTier)
    $script:UsageFailoverCallCount++
    if ($script:UsageFailoverCallCount -eq 1) {
        Set-Content -LiteralPath (Join-Path (Get-Location).Path 'partial-attempt.txt') -Value 'partial' -Encoding utf8NoBOM
        return @{ stdout=''; stderr="You've hit your usage limit. Try again at 2099-01-01T00:00:00Z."; exit_code=1; duration_s=0 }
    }
    $clean = -not (Test-Path -LiteralPath (Join-Path (Get-Location).Path 'partial-attempt.txt'))
    Set-Content -LiteralPath (Join-Path (Get-Location).Path 'failover-result.txt') -Value "worker=$($Pick.name);depth=$DepthTier;clean=$clean" -Encoding utf8NoBOM
    return @{ stdout='done'; stderr=''; exit_code=0; duration_s=0 }
}
'@
        $env:BATON_GO_TEST_EXEC_DISPATCHER = $goFailoverDispatcher
        $env:BATON_GO_TEST_PLAN = '{"run_id":"x","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"usage failover integration","capability":"code-gen","depends_on":[],"est_cost_tier":"free","reversible":true,"stakes":"high","stakes_basis":"security boundary"}]}'
        $rawFailover = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute `
            -NoPlanGate -NoGate -NoVerify -RepoPath $repo -Json | Out-String
        $resultFailover = $rawFailover | ConvertFrom-Json
        $decisionFailover = (Get-Content -LiteralPath (Join-Path $resultFailover.run_dir 'decisions.jsonl') | Select-Object -First 1) | ConvertFrom-Json
        $reportFailover = Get-Content -LiteralPath (Join-Path $resultFailover.run_dir 'report.md') -Raw
        $worktreeFailoverResult = Get-Content -LiteralPath (Join-Path ([string]$resultFailover.worktree) 'failover-result.txt') -Raw
        $usageFailoverRows = @(Get-Content -LiteralPath (Join-Path $env:BATON_HOME 'usage-journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        Check 'E9j go usage failover completes through substitute' ($resultFailover.status -eq 'completed' -and $decisionFailover.chose -eq 'worker-substitute')
        Check 'E9k go usage failover reports exactly one plain-language hop' (
            ([regex]::Matches($reportFailover, 'usage failover: worker-primary -> worker-substitute')).Count -eq 1 -and
            $decisionFailover.why -notmatch "`r|`n")
        Check 'E9l go substitute observes clean state' ($worktreeFailoverResult -match 'worker=worker-substitute;depth=high;clean=True')
        Check 'E9l go failed partial file stays absent' (-not (Test-Path -LiteralPath (Join-Path ([string]$resultFailover.worktree) 'partial-attempt.txt')))
        Check 'E9m go decision preserves high-stakes depth policy' ($decisionFailover.stakes -eq 'high' -and $decisionFailover.depth_tier -eq 'high' -and $decisionFailover.selection_mode -eq 'champion' -and $decisionFailover.tier_cap -eq 'paid' -and $decisionFailover.selected_cost_tier -eq 'free')
        Check 'E9n go usage journal records one structured hop' (@($usageFailoverRows | Where-Object { $_.event -eq 'failover' -and $_.original_worker -eq 'worker-primary' -and $_.substitute -eq 'worker-substitute' }).Count -eq 1)
    } finally {
        Set-Content -LiteralPath (Join-Path $env:BATON_HOME 'fleet.yaml') -Value $savedFleetText -Encoding utf8NoBOM
        $env:BATON_GO_TEST_EXEC_DISPATCHER = $savedDispatcherPath
        $env:BATON_GO_TEST_PLAN = $savedPlanText
    }

    # Each escape restores only its own legacy node.
    $rawNoPg = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -NoPlanGate -RepoPath $repo -Json | Out-String
    $resNoPg = $rawNoPg | ConvertFrom-Json
    Check 'E9d -NoPlanGate skips only Plan Gate' (
        $resNoPg.status -eq 'completed' -and -not (Test-Path (Join-Path $resNoPg.run_dir 'plan-review.json')) -and
        $resNoPg.acceptance.verdict -eq 'accept' -and (Test-Path (Join-Path $resNoPg.run_dir 'tasks/t1/verification.json')))

    $rawNoGate = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -NoGate -RepoPath $repo -Json | Out-String
    $resNoGate = $rawNoGate | ConvertFrom-Json
    Check 'E9e -NoGate skips only acceptance and preserves proof-by-diff' (
        $resNoGate.status -eq 'completed' -and $null -eq $resNoGate.acceptance -and
        (Test-Path (Join-Path $resNoGate.run_dir 'plan-review.json')) -and
        (Test-Path (Join-Path $resNoGate.run_dir 'tasks/t1/verification.json')) -and
        (Test-Path (Join-Path $resNoGate.run_dir 'changes.diff')))

    $env:BATON_GO_TEST_PLAN = $unprofiledPlan
    $rawNoVerify = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -NoVerify -RepoPath $repo -Json | Out-String
    $resNoVerify = $rawNoVerify | ConvertFrom-Json
    Check 'E9f -NoVerify restores legacy unprofiled labor only' (
        $resNoVerify.status -eq 'completed' -and (Test-Path (Join-Path $resNoVerify.run_dir 'plan-review.json')) -and
        $resNoVerify.acceptance.verdict -eq 'accept' -and -not (Test-Path (Join-Path $resNoVerify.run_dir 'tasks/t1/verification.json')))

    # This preflight rejection is a pre-walk plan-invalid stop, so its untouched worktree
    # is discarded (Finding 1): worktree/branch nulled, nothing left behind.
    $wtDirNP = Join-Path (Split-Path (Resolve-Path $repo).Path -Parent) '.baton-worktrees'
    $wtBeforeNP = @(Get-ChildItem -Path $wtDirNP -Directory -ErrorAction SilentlyContinue).Count
    $rawNeedsProfile = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -Json | Out-String
    $exitNeedsProfile = $LASTEXITCODE
    $resNeedsProfile = $rawNeedsProfile | ConvertFrom-Json
    $wtAfterNP = @(Get-ChildItem -Path $wtDirNP -Directory -ErrorAction SilentlyContinue).Count
    Check 'E9g default verify rejects an unprofiled edit before labor' (
        $exitNeedsProfile -eq 1 -and $resNeedsProfile.status -eq 'plan-invalid' -and [double]$resNeedsProfile.spend -eq 0 -and
        [string]::IsNullOrEmpty([string]$resNeedsProfile.worktree) -and
        [string]::IsNullOrEmpty([string]$resNeedsProfile.branch) -and
        $wtAfterNP -eq $wtBeforeNP)
    $env:BATON_GO_TEST_PLAN = $profiledPlan

    # ---- F3: plan-gate reject under -Execute leaves NO worktree/branch behind ----
    # The worktree/branch are created before the gate; a plan-rejected run must discard
    # both (nothing was walked). Force reject via the BATON_GO_TEST_PLANGATE seam.
    $pgReject = Join-Path $tmpRoot 'pg-reject.ps1'
    Set-Content -LiteralPath $pgReject -Encoding utf8NoBOM -Value @'
function Invoke-TestPlanGateDispatch($name, $prompt) {
    return @{ stdout = '[{"severity":"critical","area":"risk","summary":"will break prod"}]'; stderr = ''; exit_code = 0 }
}
'@
    $wtDir = Join-Path (Split-Path (Resolve-Path $repo).Path -Parent) '.baton-worktrees'
    $wtBefore = @(Get-ChildItem -Path $wtDir -Directory -ErrorAction SilentlyContinue).Count
    $brBefore = @(& git -C $repo branch --list 'baton/run-*').Count
    $env:BATON_GO_TEST_PLANGATE = $pgReject
    try {
        $rawR = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -PlanGate -PlanReviewers p1,p2 -Json | Out-String
        $exitR = $LASTEXITCODE
    } finally { $env:BATON_GO_TEST_PLANGATE = $pgAccept }
    $resR = $rawR | ConvertFrom-Json
    $wtAfter = @(Get-ChildItem -Path $wtDir -Directory -ErrorAction SilentlyContinue).Count
    $brAfter = @(& git -C $repo branch --list 'baton/run-*').Count
    Check 'E13 plan-rejected emits JSON then exits 1' ($exitR -eq 1 -and $resR.status -eq 'plan-rejected')
    Check 'E14 branch field nulled on reject' ([string]::IsNullOrEmpty([string]$resR.branch))
    Check 'E15 worktree field nulled on reject' ([string]::IsNullOrEmpty([string]$resR.worktree))
    Check 'E16 rejected run left no new worktree dir' ($wtAfter -eq $wtBefore)
    Check 'E17 rejected run left no new branch' ($brAfter -eq $brBefore)

    # Infrastructure-degraded Plan Gate uses the same untouched-worktree cleanup path.
    $wtBeforeD = @(Get-ChildItem -Path $wtDir -Directory -ErrorAction SilentlyContinue).Count
    $brBeforeD = @(& git -C $repo branch --list 'baton/run-*').Count
    $rawD = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -PlanReviewers one -Json | Out-String
    $exitD = $LASTEXITCODE
    $resD = $rawD | ConvertFrom-Json
    $wtAfterD = @(Get-ChildItem -Path $wtDir -Directory -ErrorAction SilentlyContinue).Count
    $brAfterD = @(& git -C $repo branch --list 'baton/run-*').Count
    Check 'E18 degraded Plan Gate exits 1' ($exitD -eq 1 -and $resD.status -eq 'plan-gate-degraded')
    Check 'E19 degraded Plan Gate cleanup nulls branch/worktree' (
        [string]::IsNullOrEmpty([string]$resD.branch) -and [string]::IsNullOrEmpty([string]$resD.worktree))
    Check 'E20 degraded Plan Gate left no new worktree or branch' ($wtAfterD -eq $wtBeforeD -and $brAfterD -eq $brBeforeD)

    # Contradictory policy flags are CLI misuse: stderr + exit 2 before a run starts.
    & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -PlanGate -NoPlanGate -RepoPath $repo -Json 2>$null | Out-Null
    Check 'E21 -PlanGate + -NoPlanGate exits 2' ($LASTEXITCODE -eq 2)
    & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -Verify -NoVerify -RepoPath $repo -Json 2>$null | Out-Null
    Check 'E22 -Verify + -NoVerify exits 2' ($LASTEXITCODE -eq 2)
    & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -GateArtifact 'x' -NoGate -RepoPath $repo -Json 2>$null | Out-Null
    Check 'E23 -GateArtifact + -NoGate exits 2' ($LASTEXITCODE -eq 2)
    & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -GateDiff 'HEAD~1..HEAD' -NoGate -RepoPath $repo -Json 2>$null | Out-Null
    Check 'E24 -GateDiff + -NoGate exits 2' ($LASTEXITCODE -eq 2)

    # Task 8 terminal semantics: every execute shipping stop emits parseable JSON
    # before returning exit 1. Pauses are covered in conductor tests and remain exit 0.
    foreach ($terminalVerdict in @('reject','polish','degraded')) {
        $env:BATON_GO_TEST_GATE = $terminalVerdict
        $rawTerminal = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -Json | Out-String
        $exitTerminal = $LASTEXITCODE
        $resTerminal = $rawTerminal | ConvertFrom-Json
        $expectedStatus = switch ($terminalVerdict) {
            'reject' { 'rejected' }
            'polish' { 'needs-polish' }
            'degraded' { 'acceptance-degraded' }
        }
        Check "E25 $expectedStatus emits JSON then exits 1" ($exitTerminal -eq 1 -and $resTerminal.status -eq $expectedStatus)
    }
    $env:BATON_GO_TEST_GATE = 'accept'

    $env:BATON_GO_TEST_PLAN = 'not-json'
    $rawPlanFailed = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -Json | Out-String
    $exitPlanFailed = $LASTEXITCODE
    $resPlanFailed = $rawPlanFailed | ConvertFrom-Json
    Check 'E26 plan-failed emits JSON then exits 1' ($exitPlanFailed -eq 1 -and $resPlanFailed.status -eq 'plan-failed')

    $failingPlan = '{"run_id":"x","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"write feature","capability":"code-gen","depends_on":[],"est_cost_tier":"free","reversible":true,"verify_profile":"failing","stakes":"standard","stakes_basis":"ordinary bounded feature"}]}'
    $env:BATON_GO_TEST_PLAN = $failingPlan
    $rawVerifyFailed = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -Json | Out-String
    $exitVerifyFailed = $LASTEXITCODE
    $resVerifyFailed = $rawVerifyFailed | ConvertFrom-Json
    Check 'E27 verification-failed emits JSON then exits 1' ($exitVerifyFailed -eq 1 -and $resVerifyFailed.status -eq 'verification-failed')

    $failDispFile = Join-Path $tmpRoot 'disp-fail.ps1'
    Set-Content -LiteralPath $failDispFile -Encoding utf8NoBOM -Value @'
function Invoke-TestExecDispatcher {
    param($Pick, $Prompt)
    return @{ stdout = ''; stderr = 'forced failure'; exit_code = 1; duration_s = 0 }
}
'@
    $env:BATON_GO_TEST_PLAN = $unprofiledPlan
    $env:BATON_GO_TEST_EXEC_DISPATCHER = $failDispFile
    $rawFailed = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -NoVerify -RepoPath $repo -Json | Out-String
    $exitFailed = $LASTEXITCODE
    $resFailed = $rawFailed | ConvertFrom-Json
    Check 'E28 failed emits JSON then exits 1' ($exitFailed -eq 1 -and $resFailed.status -eq 'failed')
    $env:BATON_GO_TEST_EXEC_DISPATCHER = $dispFile

    $budgetPlan = '{"run_id":"x","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"write feature","capability":"code-gen","depends_on":[],"est_cost_tier":"paid","reversible":true,"verify_profile":"unit","stakes":"standard","stakes_basis":"ordinary bounded feature"}]}'
    $env:BATON_GO_TEST_PLAN = $budgetPlan
    $rawBudget = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -Budget 0 -RepoPath $repo -Json | Out-String
    $exitBudget = $LASTEXITCODE
    $resBudget = $rawBudget | ConvertFrom-Json
    Check 'E29 budget pause remains exit 0' ($exitBudget -eq 0 -and $resBudget.status -eq 'interrupted-budget')

    $destructivePlan = '{"run_id":"x","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"publish feature","capability":"code-gen","depends_on":[],"est_cost_tier":"free","reversible":false,"verify_profile":"unit","stakes":"standard","stakes_basis":"ordinary bounded feature"}]}'
    $env:BATON_GO_TEST_PLAN = $destructivePlan
    $rawDestructive = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -Json | Out-String
    $exitDestructive = $LASTEXITCODE
    $resDestructive = $rawDestructive | ConvertFrom-Json
    Check 'E30 destructive pause remains exit 0' ($exitDestructive -eq 0 -and $resDestructive.status -eq 'interrupted-destructive')
    $env:BATON_GO_TEST_PLAN = $profiledPlan

    # ---- non-repo -> exit 2, no partial state ----
    $plain = Join-Path $tmpRoot 'plain'
    New-Item -ItemType Directory -Force -Path $plain | Out-Null
    & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $plain -Json 2>$null | Out-Null
    Check 'E10 non-repo exits 2' ($LASTEXITCODE -eq 2)

    # ---- without -Execute the run is unchanged (route-and-discard; no worktree) ----
    $env:BATON_GO_TEST_SPAWN = '1'
    $env:BATON_GO_TEST_GATE = $null
    $raw2 = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Json | Out-String
    $res2 = $raw2 | ConvertFrom-Json
    Check 'E11 non-execute run still completes' ($res2.status -eq 'completed')
    Check 'E12 non-execute result has no branch key' ($null -eq $res2.PSObject.Properties['branch'])
    Check 'E12a non-execute run did not gain default gates' (
        $null -eq $res2.acceptance -and -not (Test-Path (Join-Path $res2.run_dir 'plan-review.json')))
} finally {
    foreach ($k in $saved.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL PASS'
