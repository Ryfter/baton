#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-executor-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

function New-TempRepo {
    param([string]$Root)
    $p = Join-Path $Root 'repo'
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    & git -C $p init -q
    & git -C $p config user.email 'test@test.local'
    & git -C $p config user.name 'baton-test'
    Set-Content -LiteralPath (Join-Path $p 'a.txt') -Value 'hello' -Encoding utf8NoBOM
    & git -C $p add -A 2>$null | Out-Null
    & git -C $p commit -q -m 'init' 2>$null | Out-Null
    return $p
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "exec-lib-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
try {
    $repo = New-TempRepo -Root $tmpRoot

    # ---- New-RunWorktree ----
    $wt = New-RunWorktree -RepoPath $repo -RunId 'go-t1'
    Check 'W1 worktree dir exists' (Test-Path $wt.worktree)
    Check 'W2 worktree lives under sibling .baton-worktrees' ($wt.worktree -like (Join-Path $tmpRoot '.baton-worktrees\*'))
    Check 'W3 branch named baton/run-<id>' ($wt.branch -eq 'baton/run-go-t1')
    Check 'W4 base_sha is repo HEAD' ($wt.base_sha -eq ([string](& git -C $repo rev-parse HEAD)).Trim())
    Check 'W5 worktree checked out on the run branch' ((([string](& git -C $wt.worktree branch --show-current)).Trim()) -eq 'baton/run-go-t1')

    $notRepo = Join-Path $tmpRoot 'plain'; New-Item -ItemType Directory -Force -Path $notRepo | Out-Null
    $threw = $false; try { New-RunWorktree -RepoPath $notRepo -RunId 'x' | Out-Null } catch { $threw = $true }
    Check 'W6 non-repo throws' $threw

    # ---- Get-RunDiff ----
    Check 'D1 fresh worktree diff is empty' ((Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha) -eq '')
    Set-Content -LiteralPath (Join-Path $wt.worktree 'a.txt') -Value 'changed' -Encoding utf8NoBOM
    $d1 = Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha
    Check 'D2 edited file appears in diff' ($d1 -match 'changed')
    Set-Content -LiteralPath (Join-Path $wt.worktree 'brand-new.txt') -Value 'i am new' -Encoding utf8NoBOM
    $d2 = Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha
    Check 'D3 NEW (untracked) file captured in diff' ($d2 -match 'brand-new\.txt')
    Check 'D4 diff grew with the new file' ($d2.Length -gt $d1.Length)
    Check 'D5 user repo tree untouched by worktree edits' (-not (Test-Path (Join-Path $repo 'brand-new.txt')))

    # ---- Get-WorktreeTreeSha ----
    $t1 = Get-WorktreeTreeSha -Worktree $wt.worktree
    $t2 = Get-WorktreeTreeSha -Worktree $wt.worktree
    Check 'S1 stable tree sha when nothing changes' (($null -ne $t1) -and ($t1 -eq $t2))
    Set-Content -LiteralPath (Join-Path $wt.worktree 'another.txt') -Value 'x' -Encoding utf8NoBOM
    $t3 = Get-WorktreeTreeSha -Worktree $wt.worktree
    Check 'S2 tree sha changes when a file lands' ($t3 -ne $t1)
    Check 'S3 non-repo path -> $null' ($null -eq (Get-WorktreeTreeSha -Worktree $notRepo))

    # ---- Test-ProviderAgentic ----
    Check 'A1 agentic:true is authoritative' (Test-ProviderAgentic -Provider @{ agentic = $true; platform = 'local' })
    Check 'A2 agentic:false is authoritative' (-not (Test-ProviderAgentic -Provider @{ agentic = $false; platform = 'codex' }))
    Check 'A3 platform codex inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'codex' })
    Check 'A4 platform claude inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'claude' })
    Check 'A5 platform gemini inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'gemini' })
    Check 'A6 platform local not agentic' (-not (Test-ProviderAgentic -Provider @{ platform = 'local' }))
    Check 'A7 platform github not agentic' (-not (Test-ProviderAgentic -Provider @{ platform = 'github' }))
    Check 'A8 no platform, no marker -> not agentic' (-not (Test-ProviderAgentic -Provider @{ name = 'mystery' }))
    Check 'A9 agentic:true cannot grant HTTP edit powers' (-not (Test-ProviderAgentic -Provider @{ kind = 'http'; agentic = $true; platform = 'codex' }))
    Check 'A10 agentic:true cannot grant stdio-json edit powers' (-not (Test-ProviderAgentic -Provider @{ kind = 'stdio-json'; agentic = $true; platform = 'codex' }))

    if (Get-Command Test-ProviderDepthTier -ErrorAction SilentlyContinue) {
        $tierProvider = @{ kind='cli'; command_template='tool {{tier_args}} "{{prompt}}"'; tier_med='--effort medium' }
        Check 'DT1 valid CLI named tier with consuming template is applied' (Test-ProviderDepthTier -Provider $tierProvider -DepthTier med)
        Check 'DT2 template that drops tier args is not applied' (-not (Test-ProviderDepthTier -Provider @{ kind='cli'; command_template='tool "{{prompt}}"'; tier_med='--effort medium' } -DepthTier med))
        Check 'DT3 HTTP provider cannot apply CLI named tier' (-not (Test-ProviderDepthTier -Provider @{ kind='http'; command_template='tool {{tier_args}}'; tier_med='--effort medium' } -DepthTier med))
        Check 'DT4 unsafe tier fragment is not applied' (-not (Test-ProviderDepthTier -Provider @{ kind='cli'; command_template='tool {{tier_args}}'; tier_med='$(unsafe)' } -DepthTier med))
        Check 'DT5 command resolution consumes the named tier fragment' ((Resolve-FleetCommand -Provider $tierProvider -Prompt 'p' -Tier med) -match '--effort medium')
    } else {
        Check 'DT1 Test-ProviderDepthTier exists' $false
    }

    # ---- Resolve-TaskDepthPolicy (d086 PR-B, pure table) ----
    if (Get-Command Resolve-TaskDepthPolicy -ErrorAction SilentlyContinue) {
        $depthCases = @(
            @{ name='low caps paid estimate at free'; stakes='low'; estimate='paid'; run='paid'; depth='low'; mode='economy'; cap='free' },
            @{ name='low honors local task estimate'; stakes='low'; estimate='local'; run='paid'; depth='low'; mode='economy'; cap='local' },
            @{ name='low honors local run ceiling'; stakes='low'; estimate='paid'; run='local'; depth='low'; mode='economy'; cap='local' },
            @{ name='standard honors free run ceiling'; stakes='standard'; estimate='paid'; run='free'; depth='med'; mode='economy'; cap='free' },
            @{ name='standard honors local estimate'; stakes='standard'; estimate='local'; run='paid'; depth='med'; mode='economy'; cap='local' },
            @{ name='high uses champion under run ceiling'; stakes='high'; estimate='local'; run='free'; depth='high'; mode='champion'; cap='free' },
            @{ name='high can use paid run ceiling'; stakes='high'; estimate='local'; run='paid'; depth='high'; mode='champion'; cap='paid' }
        )
        foreach ($depthCase in $depthCases) {
            $depthTask = [pscustomobject]@{ stakes=$depthCase.stakes; stakes_basis="basis $($depthCase.name)"; est_cost_tier=$depthCase.estimate }
            $depthPolicy = Resolve-TaskDepthPolicy -Task $depthTask -RunMaxCostTier $depthCase.run
            Check "DPOL $($depthCase.name)" (
                $depthPolicy.stakes -eq $depthCase.stakes -and $depthPolicy.depth_tier -eq $depthCase.depth -and
                $depthPolicy.selection_mode -eq $depthCase.mode -and $depthPolicy.max_cost_tier -eq $depthCase.cap)
        }
        $legacyPolicy = Resolve-TaskDepthPolicy -Task ([pscustomobject]@{ est_cost_tier='paid' }) -RunMaxCostTier paid
        Check 'DPOL missing stakes defaults to documented standard policy' (
            $legacyPolicy.stakes -eq 'standard' -and $legacyPolicy.stakes_basis -eq 'legacy plan omitted stakes' -and
            $legacyPolicy.depth_tier -eq 'med' -and $legacyPolicy.max_cost_tier -eq 'paid')
        $overridePolicy = Resolve-TaskDepthPolicy -Task ([pscustomobject]@{ stakes='low'; stakes_basis='planner'; est_cost_tier='local' }) -RunMaxCostTier paid -StakesOverride high
        Check 'DPOL operator override wins and records its basis' (
            $overridePolicy.stakes -eq 'high' -and $overridePolicy.stakes_basis -eq 'operator override: --stakes high' -and
            $overridePolicy.selection_mode -eq 'champion' -and $overridePolicy.max_cost_tier -eq 'paid')
    } else {
        Check 'DPOL Resolve-TaskDepthPolicy exists' $false
    }

    # ---- Remove-RunWorktree ----
    Remove-RunWorktree -Worktree $wt.worktree -RepoPath $repo -Force
    Check 'R1 worktree dir removed' (-not (Test-Path $wt.worktree))
    $branches = [string](& git -C $repo branch --list 'baton/run-go-t1')
    Check 'R2 run branch KEPT after removal' ($branches -match 'baton/run-go-t1')

    # ---- New-AgenticSpawner (hermetic: fake dispatcher, temp fleet.yaml, temp BATON_HOME) ----
    $savedBatonHome = $env:BATON_HOME
    $env:BATON_HOME = Join-Path $tmpRoot 'baton-home'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    try {
        $fleetPath = Join-Path $env:BATON_HOME 'fleet.yaml'
        Set-Content -LiteralPath $fleetPath -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-local
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    command_template: 'echo "{{prompt}}"'
  - name: fake-agentic
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.1
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_low: '--effort low'
    tier_med: '--effort medium'
    tier_high: '--effort high'
  - name: fake-champion
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 0.9
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_high: '--effort high'
'@
        $toolsPath = Join-Path $env:BATON_HOME 'tools.yaml'   # intentionally absent file
        $repo2 = New-TempRepo -Root (New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'sp')).FullName
        $wt2 = New-RunWorktree -RepoPath $repo2 -RunId 'go-sp1'
        $runDir2 = Join-Path $tmpRoot 'run-sp1'
        New-Item -ItemType Directory -Force -Path $runDir2 | Out-Null
        $task = [pscustomobject]@{ id = 't1'; desc = 'write the feature'; capability = 'code-gen'; est_cost_tier = 'paid'; stakes = 'standard'; stakes_basis = 'ordinary bounded feature' }

        # dispatcher that EDITS (writes into its cwd — must be the worktree)
        $editDisp = { param($pick, $prompt)
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'made-by-instrument.txt') -Value 'work' -Encoding utf8NoBOM
            return @{ stdout = 'done'; stderr = ''; exit_code = 0; duration_s = 0 }
        }
        $cwdBefore = (Get-Location).Path
        $sp = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -MaxCostTier 'paid' -RunDir $runDir2 -Dispatcher $editDisp
        $r = & $sp $task
        Check 'P1 edit task ok' ($r.ok -eq $true)
        Check 'P2 picked the agentic provider (local filtered out)' ($r.chose -eq 'fake-agentic')
        Check 'P3 why records diff grew' ($r.why -match 'diff grew')
        Check 'P4 edit landed IN the worktree' (Test-Path (Join-Path $wt2.worktree 'made-by-instrument.txt'))
        Check 'P5 user repo untouched' (-not (Test-Path (Join-Path $repo2 'made-by-instrument.txt')))
        Check 'P6 caller cwd untouched' ((Get-Location).Path -eq $cwdBefore)
        Check 'P7 per-task diff written' (Test-Path (Join-Path $runDir2 'tasks/t1.diff'))
        Check 'P8 per-task diff names the new file' ((Get-Content -Raw (Join-Path $runDir2 'tasks/t1.diff')) -match 'made-by-instrument\.txt')
        Check 'P8a standard stakes route economy at med depth' (
            $r.stakes -eq 'standard' -and $r.stakes_basis -eq 'ordinary bounded feature' -and
            $r.depth_tier -eq 'med' -and $r.selection_mode -eq 'economy' -and $r.tier_cap -eq 'paid')
        Check 'P8b selected provider actual tier and named depth are recorded' ($r.selected_cost_tier -eq 'free' -and $r.depth_applied -eq $true)

        $legacySpawnerOk = $true
        $legacyR = $null
        try {
            $legacySpawner = New-AgenticSpawner $wt2.worktree $fleetPath $toolsPath paid $runDir2 $editDisp
            $legacyR = & $legacySpawner $task
        } catch { $legacySpawnerOk = $false }
        Check 'P8b1 legacy positional spawner signature remains compatible' (
            $legacySpawnerOk -and $null -ne $legacySpawner -and $null -ne $legacyR -and
            $legacyR.ok -eq $true -and $legacyR.chose -eq $r.chose -and
            $legacyR.stakes -eq $r.stakes -and $legacyR.depth_tier -eq $r.depth_tier -and
            $legacyR.selection_mode -eq $r.selection_mode -and $legacyR.stakes_basis -eq $r.stakes_basis)

        $highSeen = @{ tier = ''; pick = '' }
        $highDisp = { param($pick, $prompt, $depthTier)
            $highSeen.tier = $depthTier; $highSeen.pick = [string]$pick.name
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $highTask = [pscustomobject]@{ id='t-high'; desc='security change'; capability='code-gen'; est_cost_tier='local'; stakes='high'; stakes_basis='authentication boundary' }
        $spHigh = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -MaxCostTier paid -Dispatcher $highDisp
        $rHigh = & $spHigh $highTask
        Check 'P8c high stakes uses champion selection and run cap' (
            $rHigh.chose -eq 'fake-champion' -and $rHigh.selection_mode -eq 'champion' -and
            $rHigh.depth_tier -eq 'high' -and $rHigh.tier_cap -eq 'paid')
        Check 'P8d dispatcher receives generic tier and selected actual tier is logged' (
            $highSeen.tier -eq 'high' -and $highSeen.pick -eq 'fake-champion' -and
            $rHigh.depth_applied -eq $true -and $rHigh.selected_cost_tier -eq 'paid')

        $spOverride = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
            -MaxCostTier paid -StakesOverride high -Dispatcher $highDisp
        $rOverride = & $spOverride $task
        Check 'P8e spawner-level operator override reaches routing policy' (
            $rOverride.stakes -eq 'high' -and $rOverride.stakes_basis -eq 'operator override: --stakes high' -and
            $rOverride.chose -eq 'fake-champion' -and $rOverride.depth_tier -eq 'high')

        # dispatcher that does NOTHING, exit 0
        $noopDisp = { param($pick, $prompt) @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 } }
        $sp2 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r2 = & $sp2 $task
        Check 'P9 no-op exit 0 is ok' ($r2.ok -eq $true)
        Check 'P10 no-op why says no changes' ($r2.why -match 'no changes')

        # dispatcher that FAILS (exit 1)
        $failDisp = { param($pick, $prompt) @{ stdout = ''; stderr = 'boom'; exit_code = 1; duration_s = 0 } }
        $sp3 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
            -UsagePath (Join-Path $env:BATON_HOME 'usage-p11.jsonl') -Dispatcher $failDisp
        $r3 = & $sp3 $task
        Check 'P11 nonzero exit is NOT ok' ($r3.ok -eq $false)
        Check 'P12 failure why names provider + exit' ($r3.why -match 'fake-agentic.*exit 1')

        # fleet with ONLY non-agentic providers -> no edit-capable candidate
        $fleetLocalOnly = Join-Path $env:BATON_HOME 'fleet-local-only.yaml'
        Set-Content -LiteralPath $fleetLocalOnly -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-local
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    command_template: 'echo "{{prompt}}"'
'@
        $sp4 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetLocalOnly -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r4 = & $sp4 $task
        Check 'P13 local-only fleet -> not ok' ($r4.ok -eq $false)
        Check 'P14 message names the capability' ($r4.why -match "no edit-capable candidate for 'code-gen'")

        # agentic: true override on a local entry -> eligible
        $fleetOverride = Join-Path $env:BATON_HOME 'fleet-override.yaml'
        Set-Content -LiteralPath $fleetOverride -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-local-agentic
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    agentic: true
    command_template: 'echo "{{prompt}}"'
'@
        $sp5 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetOverride -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r5 = & $sp5 $task
        Check 'P15 agentic:true override makes a local entry eligible' ($r5.chose -eq 'fake-local-agentic')
        Check 'P16 provider without named med tier remains eligible and records depth_applied false' (
            $r5.depth_tier -eq 'med' -and $r5.depth_applied -eq $false -and $r5.selected_cost_tier -eq 'local')

        # ---- I1: tools.yaml candidate with platform: codex must be filtered by source ----
        $toolsWithPlatform = Join-Path $env:BATON_HOME 'tools-platform.yaml'
        Set-Content -LiteralPath $toolsWithPlatform -Encoding utf8NoBOM -Value @'
tools:
  - name: fake-tool
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    capability: code-gen
'@
        # Local-only fleet + a tools.yaml entry that would otherwise infer agentic via
        # platform: codex — must still yield "no edit-capable candidate" (tool filtered
        # by source, local fleet entry filtered by platform).
        $sp6 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetLocalOnly -ToolsPath $toolsWithPlatform -Dispatcher $noopDisp
        $r6 = & $sp6 $task
        Check 'I1a tools.yaml platform:codex candidate does not make local-only fleet edit-capable' ($r6.ok -eq $false)
        Check 'I1a why says no edit-capable candidate' ($r6.why -match 'no edit-capable candidate')

        # Main fleet (has fake-agentic) + the same tools.yaml entry -> must still pick
        # the fleet candidate, never the tool.
        $sp7 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsWithPlatform -Dispatcher $noopDisp
        $r7 = & $sp7 $task
        Check 'I1b chose fleet candidate, not the tools.yaml entry' ($r7.chose -eq 'fake-agentic')
        Check 'I1b never chose fake-tool' ($r7.chose -ne 'fake-tool')

        # ---- M4: dispatcher throw is caught and returned as a failed task, not a crash ----
        $throwDisp = { param($pick, $prompt) throw 'boom' }
        $sp8 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
            -UsagePath (Join-Path $env:BATON_HOME 'usage-m4.jsonl') -Dispatcher $throwDisp
        $cwdBeforeThrow = (Get-Location).Path
        $r8 = & $sp8 $task
        Check 'M4a dispatcher throw is caught, task returns not-ok' ($r8.ok -eq $false)
        Check 'M4a why records dispatch error' ($r8.why -match 'dispatch error')
        Check 'M4b caller cwd unchanged after a dispatch throw' ((Get-Location).Path -eq $cwdBeforeThrow)

        # ================= Reactive usage failover (d083 slice 1) =================
        # Tree restoration is the clean-state gate used before a substitute runs.
        Set-Content -LiteralPath (Join-Path $wt2.worktree 'restore-kept.txt') -Value 'before' -Encoding utf8NoBOM
        $restoreTree = Get-WorktreeTreeSha -Worktree $wt2.worktree
        Set-Content -LiteralPath (Join-Path $wt2.worktree 'restore-kept.txt') -Value 'after' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $wt2.worktree 'restore-drop.txt') -Value 'drop' -Encoding utf8NoBOM
        $restoreOk = Restore-WorktreeTreeSnapshot -Worktree $wt2.worktree -TreeSha $restoreTree
        Check 'UF0 restore snapshot succeeds' $restoreOk
        Check 'UF0 restore snapshot restores tracked content' (((Get-Content -LiteralPath (Join-Path $wt2.worktree 'restore-kept.txt') -Raw).Trim()) -eq 'before')
        Check 'UF0 restore snapshot removes new untracked content' (-not (Test-Path -LiteralPath (Join-Path $wt2.worktree 'restore-drop.txt')))
        Check 'UF0 restore snapshot returns exact tree' ((Get-WorktreeTreeSha -Worktree $wt2.worktree) -eq $restoreTree)
        Check 'UF0 invalid snapshot fails closed' (-not (Restore-WorktreeTreeSnapshot -Worktree $wt2.worktree -TreeSha 'not-a-tree'))

        $failoverFleet = Join-Path $env:BATON_HOME 'fleet-failover.yaml'
        Set-Content -LiteralPath $failoverFleet -Encoding utf8NoBOM -Value @'
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
    tier_low: '--depth low'
    tier_med: '--depth medium'
    tier_high: '--depth high'
  - name: worker-substitute
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_low: '--depth low'
    tier_med: '--depth medium'
    tier_high: '--depth high'
  - name: worker-lower
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.8
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-paid
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 1.0
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
        $failoverUsage = Join-Path $env:BATON_HOME 'usage-failover.jsonl'
        $failoverSeen = @{ calls = 0; names = @(); depths = @(); locked_before_retry = $false; clean_before_retry = $false }
        $failoverDispatcher = {
            param($pick, $prompt, $depthTier)
            $failoverSeen.calls++
            $failoverSeen.names += [string]$pick.name
            $failoverSeen.depths += [string]$depthTier
            if ($failoverSeen.calls -eq 1) {
                Set-Content -LiteralPath (Join-Path (Get-Location).Path 'partial-attempt.txt') -Value 'partial' -Encoding utf8NoBOM
                return @{ stdout=''; stderr="You've hit your usage limit. Try again at 2099-01-01T00:00:00Z."; exit_code=1; duration_s=0 }
            }
            $failoverSeen.clean_before_retry = -not (Test-Path -LiteralPath (Join-Path (Get-Location).Path 'partial-attempt.txt'))
            if (Test-Path -LiteralPath $failoverUsage) {
                $beforeRetryRows = @(Get-Content -LiteralPath $failoverUsage | ForEach-Object { $_ | ConvertFrom-Json })
                $failoverSeen.locked_before_retry = @($beforeRetryRows | Where-Object { $_.worker -eq 'worker-primary' -and $_.event -eq 'lockout' }).Count -eq 1
            }
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'substitute-result.txt') -Value 'peer work' -Encoding utf8NoBOM
            return @{ stdout='done'; stderr=''; exit_code=0; duration_s=0 }
        }.GetNewClosure()
        $failoverTask = [pscustomobject]@{ id='uf1'; desc='usage failover fixture'; capability='code-gen'; est_cost_tier='paid'; stakes='standard'; stakes_basis='bounded fixture' }
        $failoverSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $failoverUsage -Dispatcher $failoverDispatcher
        $failoverResult = & $failoverSpawner $failoverTask
        Check 'UF1 substitute retry succeeds' ($failoverResult.ok -eq $true)
        Check 'UF1 exactly one substitute is attempted' ($failoverSeen.calls -eq 2)
        Check 'UF1 attempted workers are primary then substitute' (($failoverSeen.names -join ',') -eq 'worker-primary,worker-substitute')
        Check 'UF1 same depth policy reaches both attempts' (($failoverSeen.depths -join ',') -eq 'med,med')
        Check 'UF1 primary is locked before substitute dispatch' $failoverSeen.locked_before_retry
        Check 'UF1 substitute starts from clean state' $failoverSeen.clean_before_retry
        Check 'UF1 failed attempt partial file is absent' (-not (Test-Path -LiteralPath (Join-Path $wt2.worktree 'partial-attempt.txt')))
        Check 'UF1 substitute result remains' (Test-Path -LiteralPath (Join-Path $wt2.worktree 'substitute-result.txt'))
        Check 'UF1 result chooses substitute' ($failoverResult.chose -eq 'worker-substitute')
        Check 'UF1 one-line operator hop is legible' ($failoverResult.why -match '^usage failover: worker-primary -> worker-substitute \(quota_exhausted; reset ' -and $failoverResult.why -notmatch "`r|`n")
        Check 'UF1 v1.17 policy fields survive' ($failoverResult.stakes -eq 'standard' -and $failoverResult.depth_tier -eq 'med' -and $failoverResult.selection_mode -eq 'economy' -and $failoverResult.tier_cap -eq 'free')
        Check 'UF1 selected peer tier is within ceiling' ($failoverResult.selected_cost_tier -eq 'free')
        $failoverRows = @(Get-Content -LiteralPath $failoverUsage | ForEach-Object { $_ | ConvertFrom-Json })
        $hopRows = @($failoverRows | Where-Object { $_.event -eq 'failover' })
        Check 'UF1 usage journal has one hop row' ($hopRows.Count -eq 1)
        Check 'UF1 hop row carries required workers and reason' ($hopRows[0].original_worker -eq 'worker-primary' -and $hopRows[0].substitute -eq 'worker-substitute' -and $hopRows[0].reason -eq 'quota_exhausted')
        Check 'UF1 hop row records partial diff' ($hopRows[0].had_partial_diff -eq $true)
        # worker-paid is in the failover fleet above MaxCostTier=free; must never be attempted.
        Check 'UF1 paid peer above max_cost_tier is refused' ($failoverSeen.names -notcontains 'worker-paid')

        # A second hard failure ends after the one substitute; it never cascades.
        $cascadeUsage = Join-Path $env:BATON_HOME 'usage-no-cascade.jsonl'
        $cascadeSeen = @{ calls = 0 }
        $cascadeDispatcher = {
            param($pick, $prompt, $depthTier)
            $cascadeSeen.calls++
            return @{ stdout=''; stderr='HTTP 429 Too Many Requests. Retry-After: 120'; exit_code=1; duration_s=0 }
        }.GetNewClosure()
        $cascadeSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $cascadeUsage -Dispatcher $cascadeDispatcher
        $cascadeResult = & $cascadeSpawner $failoverTask
        Check 'UF2 second hard limit does not cascade' ($cascadeSeen.calls -eq 2 -and $cascadeResult.ok -eq $false)

        # Auth/config and ambiguous failures never enter the substitute loop.
        # auth+quota co-occurrence must stay auth_config (no failover).
        foreach ($negativeCase in @(
            @{ name='auth'; message='HTTP 401 invalid API key'; expected='auth_config' },
            @{ name='auth-quota'; message='HTTP 401 unauthorized; usage limit exceeded'; expected='auth_config' },
            @{ name='ambiguous'; message='remote command ended unexpectedly'; expected='ambiguous' },
            @{ name='retry-fix'; message='retry after fixing tests'; expected='ambiguous' },
            @{ name='limit-retries'; message='hit your limit of 3 retries'; expected='ambiguous' }
        )) {
            $negativeUsage = Join-Path $env:BATON_HOME "usage-$($negativeCase.name).jsonl"
            $negativeSeen = @{ calls = 0 }
            $negativeDispatcher = {
                param($pick, $prompt, $depthTier)
                $negativeSeen.calls++
                return @{ stdout=''; stderr=$negativeCase.message; exit_code=1; duration_s=0 }
            }.GetNewClosure()
            $negativeSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $negativeUsage -Dispatcher $negativeDispatcher
            $negativeResult = & $negativeSpawner $failoverTask
            Check "UF3 $($negativeCase.name) does not retry" ($negativeSeen.calls -eq 1 -and $negativeResult.ok -eq $false)
            Check "UF3 $($negativeCase.name) reason is visible" ($negativeResult.why -match $negativeCase.expected)
            if ($negativeCase.name -eq 'auth-quota') {
                Check 'UF3 auth-quota does not journal lockout' (
                    -not (Test-Path -LiteralPath $negativeUsage) -or
                    @((Get-Content -LiteralPath $negativeUsage | ForEach-Object { $_ | ConvertFrom-Json }) |
                        Where-Object { $_.event -eq 'lockout' }).Count -eq 0)
            }
        }

        # context_overflow (#104): one substitute allowed, no lockout, prefer larger max_prompt_bytes.
        # Name order matters for equal-quality economy ranking (name is the last key):
        # worker-primary must sort before worker-sub-* so it is the first pick.
        $overflowFleet = Join-Path $env:BATON_HOME 'fleet-context-overflow.yaml'
        Set-Content -LiteralPath $overflowFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    max_prompt_bytes: 20000
    command_template: 'echo "{{prompt}}"'
  - name: worker-sub-large
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    max_prompt_bytes: 100000
    command_template: 'echo "{{prompt}}"'
  - name: worker-sub-small
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    max_prompt_bytes: 30000
    command_template: 'echo "{{prompt}}"'
'@
        $overflowUsage = Join-Path $env:BATON_HOME 'usage-context-overflow.jsonl'
        $overflowSeen = @{ calls = 0; names = [System.Collections.Generic.List[string]]::new(); locked_before_retry = $false }
        $overflowDispatcher = {
            param($pick, $prompt, $depthTier)
            $overflowSeen.calls++
            $overflowSeen.names.Add([string]$pick.name)
            if ($overflowSeen.calls -eq 1) {
                return @{ stdout = ''; stderr = 'context length exceeded'; exit_code = 1; duration_s = 0 }
            }
            # Second call = substitute dispatch; primary classification is already journaled.
            if (Test-Path -LiteralPath $overflowUsage) {
                $beforeRows = @(Get-Content -LiteralPath $overflowUsage | ForEach-Object { $_ | ConvertFrom-Json })
                $overflowSeen.locked_before_retry = @($beforeRows | Where-Object {
                    $_.worker -eq 'worker-primary' -and $_.event -in @('lockout', 'cooldown')
                }).Count -gt 0
            }
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'overflow-peer.txt') -Value 'larger peer ok' -Encoding utf8NoBOM
            return @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $overflowTask = [pscustomobject]@{ id = 'uf-ov'; desc = 'context overflow fixture'; capability = 'code-gen'; est_cost_tier = 'paid'; stakes = 'standard'; stakes_basis = 'bounded fixture' }
        $overflowSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $overflowFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $overflowUsage -Dispatcher $overflowDispatcher
        $overflowResult = & $overflowSpawner $overflowTask
        $overflowNames = ($overflowSeen.names -join ',')
        Check 'UF-OV context_overflow substitute succeeds' ($overflowResult.ok -eq $true)
        Check 'UF-OV exactly one substitute' ($overflowSeen.calls -eq 2)
        Check 'UF-OV prefers larger max_prompt_bytes peer' (
            $overflowNames -eq 'worker-primary,worker-sub-large' -and $overflowResult.chose -eq 'worker-sub-large')
        Check 'UF-OV primary is NOT locked before retry' (-not $overflowSeen.locked_before_retry)
        Check 'UF-OV hop line names context_overflow' (
            $overflowResult.why -match '^context_overflow: worker-primary -> worker-sub-large \(prefer larger context\)')
        $overflowRows = @(Get-Content -LiteralPath $overflowUsage | ForEach-Object { $_ | ConvertFrom-Json })
        Check 'UF-OV journals context_overflow not lockout' (
            @($overflowRows | Where-Object { $_.worker -eq 'worker-primary' -and $_.event -eq 'context_overflow' }).Count -eq 1 -and
            @($overflowRows | Where-Object { $_.worker -eq 'worker-primary' -and $_.event -eq 'lockout' }).Count -eq 0)
        Check 'UF-OV hop reason is context_overflow' (
            @($overflowRows | Where-Object { $_.event -eq 'failover' -and $_.reason -eq 'context_overflow' }).Count -eq 1)

        # quality_first refuses the only lower-quality peer loudly.
        $qualityFleet = Join-Path $env:BATON_HOME 'fleet-quality-floor.yaml'
        Set-Content -LiteralPath $qualityFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-lower
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.8
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
        $qualitySeen = @{ calls = 0 }
        $qualityDispatcher = { param($pick, $prompt, $depthTier) $qualitySeen.calls++; @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 } }.GetNewClosure()
        $qualitySpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $qualityFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-quality.jsonl') -Dispatcher $qualityDispatcher
        $qualityResult = & $qualitySpawner $failoverTask
        Check 'UF4 quality_first refuses downgrade' ($qualitySeen.calls -eq 1 -and $qualityResult.ok -eq $false)
        Check 'UF4 no peer available is loud' ($qualityResult.why -match 'no peer available.*quality_first')

        # High stakes re-resolves champion/high policy on the substitute too.
        $highFailoverUsage = Join-Path $env:BATON_HOME 'usage-high-failover.jsonl'
        $highFailoverSeen = @{ calls = 0; depths = @() }
        $highFailoverDispatcher = {
            param($pick, $prompt, $depthTier)
            $highFailoverSeen.calls++
            $highFailoverSeen.depths += $depthTier
            if ($highFailoverSeen.calls -eq 1) { return @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 } }
            return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
        }.GetNewClosure()
        $highFailoverTask = [pscustomobject]@{ id='uf-high'; desc='high stakes fixture'; capability='code-gen'; est_cost_tier='free'; stakes='high'; stakes_basis='security boundary' }
        $highFailoverSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $highFailoverUsage -Dispatcher $highFailoverDispatcher
        $highFailoverResult = & $highFailoverSpawner $highFailoverTask
        Check 'UF5 high stakes substitute succeeds' ($highFailoverResult.ok -eq $true -and $highFailoverSeen.calls -eq 2)
        Check 'UF5 high stakes depth is preserved on retry' (($highFailoverSeen.depths -join ',') -eq 'high,high')
        Check 'UF5 champion and cost cap are preserved' ($highFailoverResult.selection_mode -eq 'champion' -and $highFailoverResult.tier_cap -eq 'free' -and $highFailoverResult.selected_cost_tier -eq 'free')

        # Failed worktree restore refuses the substitute hop (no second dispatch).
        $restoreFailUsage = Join-Path $env:BATON_HOME 'usage-restore-fail.jsonl'
        $restoreFailSeen = @{ calls = 0 }
        $restoreFailDispatcher = {
            param($pick, $prompt, $depthTier)
            $restoreFailSeen.calls++
            return @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 }
        }.GetNewClosure()
        $savedRestoreFn = (Get-Item -LiteralPath 'Function:Restore-WorktreeTreeSnapshot').ScriptBlock
        function Restore-WorktreeTreeSnapshot {
            param(
                [Parameter(Mandatory)][string]$Worktree,
                [Parameter(Mandatory)][string]$TreeSha
            )
            return $false
        }
        try {
            $restoreFailSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $restoreFailUsage -Dispatcher $restoreFailDispatcher
            $restoreFailResult = & $restoreFailSpawner $failoverTask
        } finally {
            Set-Item -Path 'Function:Restore-WorktreeTreeSnapshot' -Value $savedRestoreFn
        }
        Check 'UF6 restore failure does not dispatch substitute' ($restoreFailSeen.calls -eq 1)
        Check 'UF6 restore failure is loud' ($restoreFailResult.ok -eq $false -and $restoreFailResult.why -match 'clean worktree restore failed')

        # Substitute peer above max_cost_tier is REFUSED even when quality is higher.
        $paidOnlyFleet = Join-Path $env:BATON_HOME 'fleet-paid-only-peer.yaml'
        Set-Content -LiteralPath $paidOnlyFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-paid
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 1.0
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
        $paidPeerUsage = Join-Path $env:BATON_HOME 'usage-paid-peer.jsonl'
        $paidPeerSeen = @{ calls = 0; names = @() }
        $paidPeerDispatcher = {
            param($pick, $prompt, $depthTier)
            $paidPeerSeen.calls++
            $paidPeerSeen.names += [string]$pick.name
            return @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 }
        }.GetNewClosure()
        $paidPeerSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $paidOnlyFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $paidPeerUsage -Dispatcher $paidPeerDispatcher
        $paidPeerResult = & $paidPeerSpawner $failoverTask
        Check 'UF7 paid peer above max_cost_tier is refused' (
            $paidPeerSeen.calls -eq 1 -and
            $paidPeerSeen.names -notcontains 'worker-paid' -and
            $paidPeerResult.ok -eq $false)
        Check 'UF7 no peer available names quality_first' ($paidPeerResult.why -match 'no peer available.*quality_first')

        # ================= Proactive usage preflight (d090 Layer 2) =================
        $spawnerParams = (Get-Command New-AgenticSpawner).Parameters
        $hasPreflightContract = $spawnerParams.ContainsKey('ProbeTransport') -and
            $spawnerParams.ContainsKey('ProbeCachePath') -and
            $spawnerParams.ContainsKey('FleetJournalPath') -and
            $spawnerParams.ContainsKey('ProbeClock')
        Check 'PF0 spawner exposes hermetic usage preflight seams' $hasPreflightContract
        if ($hasPreflightContract) {
            $probeNow = [datetimeoffset]::Parse('2026-07-16T12:00:00-06:00')
            $legacyOrder = @(
                [pscustomobject]@{ name='worker-z'; score=[double]1; source='fleet' },
                [pscustomobject]@{ name='worker-a'; score=[double]1; source='fleet' }
            )
            $legacyRanked = Sort-UsageSurplusCandidates -Candidates $legacyOrder -FleetPath $failoverFleet `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-none.jsonl') -Now $probeNow
            Check 'PF0 no surplus preference preserves legacy candidate order exactly' (
                (@($legacyRanked.name) -join ',') -eq 'worker-z,worker-a')
            function New-ExecutorProbeResponse {
                param(
                    [double]$FiveHourUsed,
                    [double]$WeeklyUsed,
                    [datetimeoffset]$At,
                    [double]$WeeklyResetHours = 48
                )
                return [pscustomobject]@{
                    jsonrpc = '2.0'; id = 2
                    result = [pscustomobject]@{
                        rateLimits = [pscustomobject]@{
                            limitId = 'synthetic'; limitName = 'synthetic'
                            primary = [pscustomobject]@{
                                usedPercent = $FiveHourUsed; windowDurationMins = 300
                                resetsAt = $At.AddHours(2).ToUnixTimeSeconds()
                            }
                            secondary = [pscustomobject]@{
                                usedPercent = $WeeklyUsed; windowDurationMins = 10080
                                resetsAt = $At.AddHours($WeeklyResetHours).ToUnixTimeSeconds()
                            }
                            credits = $null; individualLimit = $null; planType = $null; rateLimitReachedType = $null
                        }
                        rateLimitResetCredits = [pscustomobject]@{ availableCount = 0; credits = @() }
                    }
                }
            }

            $preflightFleet = Join-Path $env:BATON_HOME 'fleet-preflight.yaml'
            Set-Content -LiteralPath $preflightFleet -Encoding utf8NoBOM -Value @'
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
    tier_low: '--depth low'
    tier_med: '--depth medium'
    tier_high: '--depth high'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
      monthly_allowance: 100
  - name: worker-substitute
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_low: '--depth low'
    tier_med: '--depth medium'
    tier_high: '--depth high'
  - name: worker-third
    kind: cli
    enabled: true
    cost_tier: free
    platform: gemini
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-lower
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.8
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-paid
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 1.0
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
            $preflightTask = [pscustomobject]@{
                id='pf1'; desc='synthetic preflight fixture'; capability='code-gen'
                est_cost_tier='free'; stakes='standard'; stakes_basis='bounded fixture'
            }
            $probeClock = { return $probeNow }.GetNewClosure()

            # Under caps: selected worker dispatches and the raw response is cached.
            $underUsage = Join-Path $env:BATON_HOME 'usage-pf-under.jsonl'
            $underCache = Join-Path $env:BATON_HOME 'cache-pf-under.jsonl'
            $underSeen = @{ calls = 0; names = @(); probes = 0 }
            $underProbe = {
                param($clientVersion, $timeoutSeconds)
                $underSeen.probes++
                return (New-ExecutorProbeResponse -FiveHourUsed 40 -WeeklyUsed 50 -At $probeNow)
            }.GetNewClosure()
            $underDispatcher = {
                param($pick, $prompt, $depthTier)
                $underSeen.calls++; $underSeen.names += [string]$pick.name
                Set-Content -LiteralPath (Join-Path (Get-Location).Path 'pf-under.txt') -Value 'done' -Encoding utf8NoBOM
                return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
            }.GetNewClosure()
            $underSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $underUsage -Dispatcher $underDispatcher -ProbeTransport $underProbe `
                -ProbeCachePath $underCache -FleetJournalPath (Join-Path $env:BATON_HOME 'journal-pf-under.md') -ProbeClock $probeClock
            $underResult = & $underSpawner $preflightTask
            Check 'PF1 under caps dispatches the selected provider' ($underResult.ok -and $underSeen.calls -eq 1 -and $underSeen.names[0] -eq 'worker-primary')
            Check 'PF1 under caps probes once and caches raw response' ($underSeen.probes -eq 1 -and (Test-Path -LiteralPath $underCache))
            $underRows = @(Get-Content -LiteralPath $underUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF1 under caps journals dispatched with evidence' (
                @($underRows | Where-Object {
                    $_.event -eq 'preflight' -and $_.outcome -eq 'dispatched' -and
                    $null -ne $_.used_pct -and $null -ne $_.cap -and $_.window
                }).Count -eq 1)
            Check 'PF1 under caps never journals limited' (@($underRows | Where-Object { $_.event -eq 'limited' }).Count -eq 0)

            # Five-hour and weekly crossings reroute before the capped provider runs.
            foreach ($capCase in @(
                @{ name='five-hour'; five=[double]80; weekly=[double]20; window='five_hour'; knob='soft_cap_5h' },
                @{ name='weekly'; five=[double]20; weekly=[double]90; window='weekly'; knob='soft_cap_weekly' }
            )) {
                $capUsage = Join-Path $env:BATON_HOME "usage-pf-$($capCase.name).jsonl"
                $capCache = Join-Path $env:BATON_HOME "cache-pf-$($capCase.name).jsonl"
                $capSeen = @{ calls = 0; names = @(); depths = @() }
                $capProbe = {
                    param($clientVersion, $timeoutSeconds)
                    return (New-ExecutorProbeResponse -FiveHourUsed $capCase.five -WeeklyUsed $capCase.weekly -At $probeNow)
                }.GetNewClosure()
                $capDispatcher = {
                    param($pick, $prompt, $depthTier)
                    $capSeen.calls++; $capSeen.names += [string]$pick.name; $capSeen.depths += [string]$depthTier
                    Set-Content -LiteralPath (Join-Path (Get-Location).Path "pf-$($capCase.name).txt") -Value 'peer' -Encoding utf8NoBOM
                    return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
                }.GetNewClosure()
                $capSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                    -MaxCostTier free -UsagePath $capUsage -Dispatcher $capDispatcher -ProbeTransport $capProbe `
                    -ProbeCachePath $capCache -FleetJournalPath (Join-Path $env:BATON_HOME "journal-pf-$($capCase.name).md") -ProbeClock $probeClock
                $capResult = & $capSpawner $preflightTask
                Check "PF2 $($capCase.name) cap reroutes before dispatch" (
                    $capResult.ok -and $capSeen.calls -eq 1 -and ($capSeen.names -join ',') -eq 'worker-substitute')
                Check "PF2 $($capCase.name) reroute preserves med depth and free ceiling" (
                    ($capSeen.depths -join ',') -eq 'med' -and $capResult.depth_tier -eq 'med' -and
                    $capResult.tier_cap -eq 'free' -and $capResult.selected_cost_tier -eq 'free')
                Check "PF2 $($capCase.name) loud line names all policy evidence" (
                    $capResult.why -match 'usage preflight: worker-primary' -and
                    $capResult.why -match $capCase.window -and $capResult.why -match $capCase.knob -and
                    $capResult.why -match '80%|90%' -and $capResult.why -match 'resets ' -and
                    $capResult.why -notmatch "`r|`n")
                $capRows = @(Get-Content -LiteralPath $capUsage | ForEach-Object { $_ | ConvertFrom-Json })
                Check "PF2 $($capCase.name) journals one limited observation" (
                    @($capRows | Where-Object { $_.event -eq 'limited' -and $_.window -eq $capCase.window }).Count -eq 1)
                Check "PF2 $($capCase.name) journals rerouted decision" (
                    @($capRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'rerouted' -and $_.substitute -eq 'worker-substitute' }).Count -eq 1)
                Check "PF2 $($capCase.name) lower-quality and paid workers are refused" (
                    $capSeen.names -notcontains 'worker-lower' -and $capSeen.names -notcontains 'worker-paid')
            }

            # No equal-quality peer: hold loudly and do not dispatch anyone.
            $holdFleet = Join-Path $env:BATON_HOME 'fleet-preflight-hold.yaml'
            Set-Content -LiteralPath $holdFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
  - name: worker-lower
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.8
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
            $holdUsage = Join-Path $env:BATON_HOME 'usage-pf-hold.jsonl'
            $holdSeen = @{ calls = 0 }
            $holdSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $holdFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $holdUsage -Dispatcher { param($pick,$prompt,$depthTier) $holdSeen.calls++; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-hold.jsonl') -ProbeClock $probeClock
            $holdResult = & $holdSpawner $preflightTask
            Check 'PF3 over cap with no peer holds without dispatch' (-not $holdResult.ok -and $holdSeen.calls -eq 0)
            Check 'PF3 hold is loud with exact no-peer context' ($holdResult.why -match 'no peer available \+ worker-primary over soft cap' -and $holdResult.why -notmatch "`r|`n")
            $holdRows = @(Get-Content -LiteralPath $holdUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF3 held outcome is journaled' (@($holdRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'held' }).Count -eq 1)

            # Transport failures are fail-open and dispatch the primary normally.
            foreach ($probeFailure in @(
                @{ name='timeout'; body={ param($clientVersion,$timeoutSeconds) throw 'synthetic timeout' } },
                @{ name='garbage'; body={ param($clientVersion,$timeoutSeconds) return 'synthetic garbage' } },
                @{ name='missing'; body={ param($clientVersion,$timeoutSeconds) throw 'synthetic missing binary' } }
            )) {
                $failureSeen = @{ calls = 0; name = '' }
                $failureDispatcher = {
                    param($pick,$prompt,$depthTier)
                    $failureSeen.calls++; $failureSeen.name = [string]$pick.name
                    return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
                }.GetNewClosure()
                $failureSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                    -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME "usage-pf-fail-$($probeFailure.name).jsonl") `
                    -Dispatcher $failureDispatcher -ProbeTransport $probeFailure.body `
                    -ProbeCachePath (Join-Path $env:BATON_HOME "cache-pf-fail-$($probeFailure.name).jsonl") -ProbeClock $probeClock
                $failureResult = & $failureSpawner $preflightTask
                Check "PF4 $($probeFailure.name) probe failure fails open" (
                    $failureResult.ok -and $failureSeen.calls -eq 1 -and $failureSeen.name -eq 'worker-primary')
            }

            # Stale cache must invoke the transport once; fresh cache behavior is covered in probe suite.
            $staleCache = Join-Path $env:BATON_HOME 'cache-pf-stale.jsonl'
            [void](Get-CodexUsageProbe -Worker 'worker-primary' -Transport {
                param($clientVersion,$timeoutSeconds)
                New-ExecutorProbeResponse -FiveHourUsed 30 -WeeklyUsed 40 -At $probeNow
            } -CachePath $staleCache -Now $probeNow -TtlSeconds 600)
            $staleSeen = @{ probes = 0; dispatches = 0 }
            $staleSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-pf-stale.jsonl') `
                -Dispatcher { param($pick,$prompt,$depthTier) $staleSeen.dispatches++; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) $staleSeen.probes++; New-ExecutorProbeResponse -FiveHourUsed 35 -WeeklyUsed 45 -At $probeNow.AddMinutes(11) }.GetNewClosure() `
                -ProbeCachePath $staleCache -ProbeClock { $probeNow.AddMinutes(11) }.GetNewClosure()
            $staleResult = & $staleSpawner $preflightTask
            Check 'PF5 stale cache re-probes exactly once then dispatches' ($staleResult.ok -and $staleSeen.probes -eq 1 -and $staleSeen.dispatches -eq 1)

            # A proactive reroute consumes the one-hop budget; peer quota failure cannot cascade.
            $oneHopSeen = @{ calls = 0; names = @() }
            $oneHopSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-pf-one-hop.jsonl') `
                -Dispatcher { param($pick,$prompt,$depthTier) $oneHopSeen.calls++; $oneHopSeen.names += [string]$pick.name; @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-one-hop.jsonl') -ProbeClock $probeClock
            $oneHopResult = & $oneHopSpawner $preflightTask
            Check 'PF6 proactive reroute consumes the one-hop budget' (-not $oneHopResult.ok -and $oneHopSeen.calls -eq 1 -and ($oneHopSeen.names -join ',') -eq 'worker-substitute')

            # High stakes remains champion/high when preflight selects a peer.
            $pfHighSeen = @{ calls = 0; depths = @() }
            $pfHighTask = [pscustomobject]@{ id='pf-high'; desc='synthetic high'; capability='code-gen'; est_cost_tier='free'; stakes='high'; stakes_basis='security boundary' }
            $pfHighSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-pf-high.jsonl') `
                -Dispatcher { param($pick,$prompt,$depthTier) $pfHighSeen.calls++; $pfHighSeen.depths += [string]$depthTier; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-high.jsonl') -ProbeClock $probeClock
            $pfHighResult = & $pfHighSpawner $pfHighTask
            Check 'PF7 high-stakes preflight peer keeps champion/high policy' (
                $pfHighResult.ok -and ($pfHighSeen.depths -join ',') -eq 'high' -and
                $pfHighResult.selection_mode -eq 'champion' -and $pfHighResult.tier_cap -eq 'free')

            # Token-fit and monthly pace append advisories but never auto-hold.
            $advisoryUsage = Join-Path $env:BATON_HOME 'usage-pf-advisory.jsonl'
            Add-UsageClassifyJournalRow -UsagePath $advisoryUsage -Row ([ordered]@{
                ts=$probeNow.ToString('o'); event='observation'; worker='worker-primary'; scope='paid_credit'
                source='billing_api'; consumed=[double]60; observed_at=$probeNow.ToString('o'); reset_at=$probeNow.AddDays(20).ToString('o')
            })
            $advisoryJournal = Join-Path $env:BATON_HOME 'journal-pf-advisory.md'
            Set-Content -LiteralPath $advisoryJournal -Encoding utf8NoBOM -Value @('# synthetic')
            foreach ($tokenValue in @(100,200,300,400,500)) {
                Add-Content -LiteralPath $advisoryJournal -Encoding utf8NoBOM -Value "2026-07-16T12:00:00-06:00 | fleet | worker-primary | 1s | exit:0 | `"synthetic`" | host:test | tok:$tokenValue(estimate)"
            }
            $advisorySeen = @{ calls = 0 }
            $advisoryFleet = Join-Path $env:BATON_HOME 'fleet-pf-advisory.yaml'
            (Get-Content -LiteralPath $preflightFleet -Raw).Replace('soft_cap_5h: 75', 'soft_cap_5h: 100') | Set-Content -LiteralPath $advisoryFleet -Encoding utf8NoBOM
            $advisorySpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $advisoryFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $advisoryUsage -FleetJournalPath $advisoryJournal `
                -Dispatcher { param($pick,$prompt,$depthTier) $advisorySeen.calls++; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 98 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-advisory.jsonl') -ProbeClock $probeClock
            $advisoryResult = & $advisorySpawner $preflightTask
            Check 'PF8 fit/monthly advisories never auto-hold' ($advisoryResult.ok -and $advisorySeen.calls -eq 1 -and $advisoryResult.chose -eq 'worker-primary')
            Check 'PF8 result appends token-fit advisory' ($advisoryResult.why -match 'typical dispatch burns ~300 tok')
            Check 'PF8 result appends monthly pace advisory' ($advisoryResult.why -match 'monthly usage pace')

            # Fresh cached surplus preference changes only same-tier candidate order.
            $surplusFleet = Join-Path $env:BATON_HOME 'fleet-pf-surplus.yaml'
            Set-Content -LiteralPath $surplusFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-alpha
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-probe
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
'@
            $surplusCache = Join-Path $env:BATON_HOME 'cache-pf-surplus.jsonl'
            [void](Get-CodexUsageProbe -Worker 'worker-probe' -Transport {
                param($clientVersion,$timeoutSeconds)
                New-ExecutorProbeResponse -FiveHourUsed 20 -WeeklyUsed 40 -At $probeNow -WeeklyResetHours 12
            } -CachePath $surplusCache -Now $probeNow -TtlSeconds 600)
            $surplusUsage = Join-Path $env:BATON_HOME 'usage-pf-surplus.jsonl'
            $surplusSeen = @{ calls=0; name=''; probes=0 }
            $surplusSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $surplusFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $surplusUsage `
                -Dispatcher { param($pick,$prompt,$depthTier) $surplusSeen.calls++; $surplusSeen.name=[string]$pick.name; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) $surplusSeen.probes++; throw 'fresh cache should be used' }.GetNewClosure() `
                -ProbeCachePath $surplusCache -ProbeClock { $probeNow.AddMinutes(5) }.GetNewClosure()
            $surplusResult = & $surplusSpawner $preflightTask
            Check 'PF9 surplus preference moves adapter-backed peer within the eligible tier' (
                $surplusResult.ok -and $surplusSeen.name -eq 'worker-probe' -and $surplusSeen.probes -eq 0)
            $surplusRows = @(Get-Content -LiteralPath $surplusUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF9 surplus reason lands in preflight journal' (
                @($surplusRows | Where-Object { $_.event -eq 'preflight' -and $_.reason -eq 'surplus_spend' }).Count -eq 1)

            # FIX 2: surplus on the weaker peer must not flip a real quality gap (0.90 vs 0.85).
            $qualitySurplusFleet = Join-Path $env:BATON_HOME 'fleet-pf-quality-surplus.yaml'
            Set-Content -LiteralPath $qualitySurplusFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-strong
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.90
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-weak
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.85
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
'@
            $qualitySurplusCache = Join-Path $env:BATON_HOME 'cache-pf-quality-surplus.jsonl'
            [void](Get-CodexUsageProbe -Worker 'worker-weak' -Transport {
                param($clientVersion,$timeoutSeconds)
                New-ExecutorProbeResponse -FiveHourUsed 20 -WeeklyUsed 40 -At $probeNow -WeeklyResetHours 12
            } -CachePath $qualitySurplusCache -Now $probeNow -TtlSeconds 600)
            # Economy score = tier_rank - quality*0.001 (both free => tier 0).
            $qualityCands = @(
                [pscustomobject]@{ name='worker-weak'; score=([double](0 - 0.85 * 0.001)); source='fleet'; quality=[double]0.85 },
                [pscustomobject]@{ name='worker-strong'; score=([double](0 - 0.90 * 0.001)); source='fleet'; quality=[double]0.90 }
            )
            $qualityRanked = Sort-UsageSurplusCandidates -Candidates $qualityCands -FleetPath $qualitySurplusFleet `
                -ProbeCachePath $qualitySurplusCache -Now $probeNow.AddMinutes(5)
            Check 'PF10 surplus on weaker peer does not flip a real quality gap' (
                @($qualityRanked)[0].name -eq 'worker-strong' -and
                [double](@($qualityRanked | Where-Object { $_.name -eq 'worker-weak' })[0].usage_preference) -gt 0)

            # FIX 3: two probe:true peers both over cap -> held, no dispatch, no hop chain.
            $bothOverFleet = Join-Path $env:BATON_HOME 'fleet-pf-both-over.yaml'
            Set-Content -LiteralPath $bothOverFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
  - name: worker-peer
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
'@
            $bothOverSeen = @{ calls = 0; probes = 0; workers = @() }
            $bothOverProbe = {
                param($clientVersion, $timeoutSeconds)
                $bothOverSeen.probes++
                return (New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow)
            }.GetNewClosure()
            $bothOverDispatcher = {
                param($pick, $prompt, $depthTier)
                $bothOverSeen.calls++
                $bothOverSeen.workers += [string]$pick.name
                return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
            }.GetNewClosure()
            $bothOverUsage = Join-Path $env:BATON_HOME 'usage-pf-both-over.jsonl'
            $bothOverSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $bothOverFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $bothOverUsage -Dispatcher $bothOverDispatcher -ProbeTransport $bothOverProbe `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-both-over.jsonl') -ProbeClock $probeClock
            $bothOverResult = & $bothOverSpawner $preflightTask
            Check 'PF11 both probe peers over cap holds without dispatch' (
                -not $bothOverResult.ok -and $bothOverSeen.calls -eq 0)
            Check 'PF11 both-over hold names both providers' (
                $bothOverResult.why -match 'worker-primary' -and $bothOverResult.why -match 'worker-peer' -and
                $bothOverResult.why -match 'also over soft cap' -and $bothOverResult.why -notmatch "`r|`n")
            Check 'PF11 both-over probes primary and substitute exactly once each' ($bothOverSeen.probes -eq 2)
            $bothOverRows = @(Get-Content -LiteralPath $bothOverUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF11 both-over journals held not rerouted' (
                @($bothOverRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'held' }).Count -eq 1 -and
                @($bothOverRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'rerouted' }).Count -eq 0)

            # FIX 4: multi-window over-cap loud line names every crossed window.
            $multiWinUsage = Join-Path $env:BATON_HOME 'usage-pf-multi-window.jsonl'
            $multiWinSeen = @{ calls = 0; names = @() }
            $multiWinSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $multiWinUsage `
                -Dispatcher {
                    param($pick,$prompt,$depthTier)
                    $multiWinSeen.calls++; $multiWinSeen.names += [string]$pick.name
                    Set-Content -LiteralPath (Join-Path (Get-Location).Path 'pf-multi.txt') -Value 'peer' -Encoding utf8NoBOM
                    return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
                }.GetNewClosure() `
                -ProbeTransport {
                    param($clientVersion,$timeoutSeconds)
                    New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 90 -At $probeNow
                }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-multi-window.jsonl') -ProbeClock $probeClock
            $multiWinResult = & $multiWinSpawner $preflightTask
            Check 'PF12 multi-window over-cap loud line names all crossings' (
                $multiWinResult.ok -and $multiWinResult.why -match 'five_hour' -and
                $multiWinResult.why -match 'weekly' -and $multiWinResult.why -match 'soft_cap_5h' -and
                $multiWinResult.why -match 'soft_cap_weekly')
            $multiWinRows = @(Get-Content -LiteralPath $multiWinUsage | ForEach-Object { $_ | ConvertFrom-Json })
            $multiWinPreflight = @($multiWinRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'rerouted' }) | Select-Object -First 1
            Check 'PF12 multi-window preflight journal names all crossings' (
                $null -ne $multiWinPreflight -and
                [string]$multiWinPreflight.window -match 'five_hour' -and
                [string]$multiWinPreflight.window -match 'weekly')
        }

        # ================= New-VerifyingSpawner (VS-series, d082 V2) =================
        # Hermetic: a temp repo with a committed .baton/verification.json (a `unit` profile
        # whose argv runs a committed pwsh check), a REAL frozen contract, and an inner
        # dispatcher that edits the worktree. Real V1 runner throughout except VS2/VS3,
        # where BATON_VERIFY_TEST_HOOK forces the verdict sequence.
        function New-VerifyFixture {
            param([string]$Name, [hashtable]$VProfile, [string]$CheckBody = 'exit 0')
            $r = New-TempRepo -Root (New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot $Name)).FullName
            Set-Content -LiteralPath (Join-Path $r 'check.ps1') -Value $CheckBody -Encoding utf8NoBOM
            $cfgD = Join-Path $r '.baton'; New-Item -ItemType Directory -Force -Path $cfgD | Out-Null
            $cfg = @{ schema = 1; profiles = @{ unit = $VProfile } }
            ConvertTo-Json -InputObject $cfg -Depth 8 | Set-Content -LiteralPath (Join-Path $cfgD 'verification.json') -Encoding utf8NoBOM
            & git -C $r add -A 2>$null | Out-Null
            & git -C $r commit -q -m 'add verify config' 2>$null | Out-Null
            $w = New-RunWorktree -RepoPath $r -RunId "$Name-wt"
            $rd = Join-Path $tmpRoot "$Name-run"; New-Item -ItemType Directory -Force -Path $rd | Out-Null
            $fc = Get-FrozenVerificationContract -RepoPath $r -BaseSha $w.base_sha -ProfileName 'unit' -WorktreeRoot $w.worktree -RunTaskDir (Join-Path $rd 'tasks/t1')
            return @{ repo = $r; wt = $w; runDir = $rd; frozen = @{ 't1' = @{ contract = $fc.contract; contract_path = $fc.contract_path } }; fcOk = $fc.ok }
        }
        function New-VerifyTask { param([string[]]$Allowed = @(), [string]$Profile = 'unit')
            [pscustomobject]@{ id = 't1'; desc = 'implement the feature'; command = ''; capability = 'code-gen'
                depends_on = @(); est_cost_tier = 'free'; reversible = $true; verify_profile = $Profile; allowed_paths = $Allowed }
        }
        $writeDisp = { param($pick, $prompt)
            Set-Content -LiteralPath (Join-Path (Get-Location).Path "w-$([guid]::NewGuid()).txt") -Value $prompt -Encoding utf8NoBOM
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }
        $noopDisp2 = { param($pick, $prompt) @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 } }
        $forbidDisp = { param($pick, $prompt)
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'forbidden.txt') -Value 'x' -Encoding utf8NoBOM
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }
        $passProfile = @{ argv = @('pwsh', '-NoProfile', '-File', 'check.ps1'); proves = 'the unit check passes' }
        function Get-Attempts { param($rd) @(Get-Content -LiteralPath (Join-Path $rd 'tasks/t1/attempts.jsonl')) }

        # VS1 pass: check exits 0, inner writes a file -> ok, verdict pass, 1 attempt row.
        $fx1 = New-VerifyFixture -Name 'vs1' -VProfile $passProfile
        Check 'VS0 fixture frozen contract resolved' ($fx1.fcOk -eq $true)
        $in1 = New-AgenticSpawner -Worktree $fx1.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx1.runDir -Dispatcher $writeDisp
        $vs1 = New-VerifyingSpawner -InnerSpawner $in1 -Worktree $fx1.wt.worktree -BaseSha $fx1.wt.base_sha -RunDir $fx1.runDir -FrozenContracts $fx1.frozen
        $rv1 = & $vs1 (New-VerifyTask)
        Check 'VS1 ok true' ($rv1.ok -eq $true)
        Check 'VS1 verdict pass' ($rv1.verification.verdict -eq 'pass')
        Check 'VS1 not retried' ($rv1.verification.retried -eq $false)
        Check 'VS1 verification.json written' (Test-Path (Join-Path $fx1.runDir 'tasks/t1/verification.json'))
        $a1rows = @(Get-Attempts $fx1.runDir)
        Check 'VS1 one attempt row' ($a1rows.Count -eq 1)
        Check 'VS1 attempt first_try true' ((@($a1rows)[0] | ConvertFrom-Json).first_try -eq $true)

        # VS2 retry-then-pass (forced verdict via hook; inner writes each attempt -> grew).
        $hook2 = Join-Path $tmpRoot 'hook2.ps1'
        Set-Content -LiteralPath $hook2 -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    if ($Attempt -ge 2) { return @{ verdict='pass'; ok=$true; grade='bounded'; failure_category=''; proves='hooked pass'; output_path=''; duration_ms=5 } }
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=''; duration_ms=5 }
}
'@
        $fx2 = New-VerifyFixture -Name 'vs2' -VProfile $passProfile
        $in2 = New-AgenticSpawner -Worktree $fx2.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx2.runDir -Dispatcher $writeDisp
        $vs2 = New-VerifyingSpawner -InnerSpawner $in2 -Worktree $fx2.wt.worktree -BaseSha $fx2.wt.base_sha -RunDir $fx2.runDir -FrozenContracts $fx2.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hook2
        try { $rv2 = & $vs2 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS2 retried true' ($rv2.verification.retried -eq $true)
        Check 'VS2 final ok true' ($rv2.ok -eq $true)
        Check 'VS2 two attempt rows' (@(Get-Attempts $fx2.runDir).Count -eq 2)
        Check 'VS2 first_failure_category check-failed' ($rv2.verification.first_failure_category -eq 'check-failed')
        Check 'VS2 final retry preserves resolved depth policy metadata' (
            $rv2.stakes -eq 'standard' -and $rv2.stakes_basis -eq 'legacy plan omitted stakes' -and
            $rv2.depth_tier -eq 'med' -and $rv2.selection_mode -eq 'economy' -and
            $rv2.tier_cap -eq 'free' -and $rv2.depth_applied -eq $true -and
            $rv2.selected_cost_tier -eq 'free')

        # VS3 retry-then-fail (hook fails both attempts).
        $hook3 = Join-Path $tmpRoot 'hook3.ps1'
        Set-Content -LiteralPath $hook3 -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=''; duration_ms=5 }
}
'@
        $fx3 = New-VerifyFixture -Name 'vs3' -VProfile $passProfile
        $in3 = New-AgenticSpawner -Worktree $fx3.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx3.runDir -Dispatcher $writeDisp
        $vs3 = New-VerifyingSpawner -InnerSpawner $in3 -Worktree $fx3.wt.worktree -BaseSha $fx3.wt.base_sha -RunDir $fx3.runDir -FrozenContracts $fx3.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hook3
        try { $rv3 = & $vs3 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS3 not ok' ($rv3.ok -eq $false)
        Check 'VS3 verdict fail' ($rv3.verification.verdict -eq 'fail')
        Check 'VS3 retried true' ($rv3.verification.retried -eq $true)
        Check 'VS3 two attempt rows' (@(Get-Attempts $fx3.runDir).Count -eq 2)

        # VS4 scope-violation -> fail closed, NO retry (inner writes an out-of-scope file).
        $fx4 = New-VerifyFixture -Name 'vs4' -VProfile $passProfile
        $in4 = New-AgenticSpawner -Worktree $fx4.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx4.runDir -Dispatcher $forbidDisp
        $vs4 = New-VerifyingSpawner -InnerSpawner $in4 -Worktree $fx4.wt.worktree -BaseSha $fx4.wt.base_sha -RunDir $fx4.runDir -FrozenContracts $fx4.frozen
        $rv4 = & $vs4 (New-VerifyTask -Allowed @('allowed.txt'))
        Check 'VS4 verdict scope-violation' ($rv4.verification.verdict -eq 'scope-violation')
        Check 'VS4 not ok' ($rv4.ok -eq $false)
        Check 'VS4 not retried' ($rv4.verification.retried -eq $false)
        Check 'VS4 exactly one attempt row (no retry)' (@(Get-Attempts $fx4.runDir).Count -eq 1)

        # VS5 A5 no-change: check exits 0 but inner writes nothing -> demoted to no-change,
        # retry-eligible (2 rows), still fails.
        $fx5 = New-VerifyFixture -Name 'vs5' -VProfile $passProfile
        $in5 = New-AgenticSpawner -Worktree $fx5.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx5.runDir -Dispatcher $noopDisp2
        $vs5 = New-VerifyingSpawner -InnerSpawner $in5 -Worktree $fx5.wt.worktree -BaseSha $fx5.wt.base_sha -RunDir $fx5.runDir -FrozenContracts $fx5.frozen
        $rv5 = & $vs5 (New-VerifyTask)
        Check 'VS5 verdict fail' ($rv5.verification.verdict -eq 'fail')
        Check 'VS5 failure_category no-change' ($rv5.verification.failure_category -eq 'no-change')
        Check 'VS5 first_failure no-change' ($rv5.verification.first_failure_category -eq 'no-change')
        Check 'VS5 retried (two rows)' (@(Get-Attempts $fx5.runDir).Count -eq 2)

        # VS6 unverified: task with verify_profile='' delegates to inner, unverified=true,
        # no verification key.
        $fx6 = New-VerifyFixture -Name 'vs6' -VProfile $passProfile
        $in6 = New-AgenticSpawner -Worktree $fx6.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx6.runDir -Dispatcher $writeDisp
        $vs6 = New-VerifyingSpawner -InnerSpawner $in6 -Worktree $fx6.wt.worktree -BaseSha $fx6.wt.base_sha -RunDir $fx6.runDir -FrozenContracts @{}
        $rv6 = & $vs6 (New-VerifyTask -Profile '')
        Check 'VS6 unverified true' ($rv6.unverified -eq $true)
        Check 'VS6 no verification key' (-not $rv6.ContainsKey('verification'))
        Check 'VS6 delegated inner ok' ($rv6.ok -eq $true)

        # VS7 evidence prompt: carries the failure category, the fix-in-place instruction,
        # the original task, and the WHOLE prompt stays <=965 UTF-8 bytes even with a
        # flooding excerpt or an oversized desc (review I2 — survives inline instruments).
        $utf8 = [System.Text.Encoding]::UTF8
        $vs7out = Join-Path $tmpRoot 'vs7-out.txt'
        Set-Content -LiteralPath $vs7out -Value ('E' * 5000) -Encoding utf8NoBOM
        $vs7prompt = Format-VerifyEvidencePrompt -TaskDesc 'Original task text' -Verification @{ failure_category = 'check-failed' } -OutputPath $vs7out
        Check 'VS7 includes failure category' ($vs7prompt -match 'check-failed')
        Check 'VS7 includes fix-in-place instruction' ($vs7prompt -match 'Fix the EXISTING work')
        Check 'VS7 includes original task' ($vs7prompt -match 'Original task text')
        Check 'VS7 whole prompt <=965 UTF-8 bytes (flooding excerpt)' ($utf8.GetByteCount($vs7prompt) -le 965)
        $vs7big = Format-VerifyEvidencePrompt -TaskDesc ('D' * 4000) -Verification @{ failure_category = 'check-failed' } -OutputPath $vs7out
        Check 'VS7 whole prompt <=965 UTF-8 bytes (oversized desc)' ($utf8.GetByteCount($vs7big) -le 965)
        # An empty desc must NOT crash the retry (mandatory [string] rejects '' — the house
        # trap the V2 live smoke surfaced; a desc-less task must degrade, not kill the run).
        $vs7empty = $null
        $vs7ok = $true
        try { $vs7empty = Format-VerifyEvidencePrompt -TaskDesc '' -Verification @{ failure_category = 'check-failed' } -OutputPath $vs7out } catch { $vs7ok = $false }
        Check 'VS7 empty desc does not throw' ($vs7ok -and $null -ne $vs7empty)

        # VS8 (review I1/edge#4): add-then-revert nets to ZERO vs the pre-task baseline —
        # must NOT pass. Attempt 1 adds a file (hook forces check-failed -> retry); attempt 2
        # deletes it back to the task-start tree (hook forces pass). A5 must demote the
        # attempt-2 pass to no-change because the diff vs TASK START (not vs attempt 1) is empty.
        $hookPF = Join-Path $tmpRoot 'hookPF.ps1'
        Set-Content -LiteralPath $hookPF -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    if ($Attempt -ge 2) { return @{ verdict='pass'; ok=$true; grade='bounded'; failure_category=''; proves='hooked pass'; output_path=''; duration_ms=5 } }
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=''; duration_ms=5 }
}
'@
        $ctr8 = Join-Path $tmpRoot 'ctr8.txt'; Set-Content -LiteralPath $ctr8 -Value '0' -Encoding utf8NoBOM
        $disp8 = {
            param($pick, $prompt)
            $n = [int]((Get-Content -LiteralPath $ctr8 -Raw).Trim()) + 1
            Set-Content -LiteralPath $ctr8 -Value "$n" -Encoding utf8NoBOM
            $target = Join-Path (Get-Location).Path 'x8.txt'
            if ($n -eq 1) { Set-Content -LiteralPath $target -Value 'v1' -Encoding utf8NoBOM }
            else { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $fx8 = New-VerifyFixture -Name 'vs8' -VProfile $passProfile
        $in8 = New-AgenticSpawner -Worktree $fx8.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx8.runDir -Dispatcher $disp8
        $vs8 = New-VerifyingSpawner -InnerSpawner $in8 -Worktree $fx8.wt.worktree -BaseSha $fx8.wt.base_sha -RunDir $fx8.runDir -FrozenContracts $fx8.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hookPF
        try { $rv8 = & $vs8 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS8 add-then-revert does NOT pass (net-zero vs task start)' ($rv8.ok -eq $false)
        Check 'VS8 verdict fail' ($rv8.verification.verdict -eq 'fail')
        Check 'VS8 demoted to no-change' ($rv8.verification.failure_category -eq 'no-change')

        # VS9 (review I1/edge#4): a legitimate repair whose attempt 2 makes NO further edit
        # must PASS. Attempt 1 makes the real change (hook forces check-failed -> retry);
        # attempt 2 edits nothing and the check passes. The diff vs TASK START is non-empty,
        # so A5 must NOT demote it (the old per-attempt baseline false-failed this).
        $ctr9 = Join-Path $tmpRoot 'ctr9.txt'; Set-Content -LiteralPath $ctr9 -Value '0' -Encoding utf8NoBOM
        $disp9 = {
            param($pick, $prompt)
            $n = [int]((Get-Content -LiteralPath $ctr9 -Raw).Trim()) + 1
            Set-Content -LiteralPath $ctr9 -Value "$n" -Encoding utf8NoBOM
            if ($n -eq 1) { Set-Content -LiteralPath (Join-Path (Get-Location).Path 'x9.txt') -Value 'real change' -Encoding utf8NoBOM }
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $fx9 = New-VerifyFixture -Name 'vs9' -VProfile $passProfile
        $in9 = New-AgenticSpawner -Worktree $fx9.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx9.runDir -Dispatcher $disp9
        $vs9 = New-VerifyingSpawner -InnerSpawner $in9 -Worktree $fx9.wt.worktree -BaseSha $fx9.wt.base_sha -RunDir $fx9.runDir -FrozenContracts $fx9.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hookPF
        try { $rv9 = & $vs9 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS9 legit no-further-edit repair PASSES (non-empty vs task start)' ($rv9.ok -eq $true)
        Check 'VS9 verdict pass' ($rv9.verification.verdict -eq 'pass')
        Check 'VS9 retried true' ($rv9.verification.retried -eq $true)

        # VS10 (review M2): spend accrues across BOTH attempts. Hook forces retry-then-pass;
        # a dispatcher stamps a distinct spend per attempt; the returned spend is their sum.
        $ctrS = Join-Path $tmpRoot 'ctrS.txt'; Set-Content -LiteralPath $ctrS -Value '0' -Encoding utf8NoBOM
        $dispS = {
            param($pick, $prompt)
            $n = [int]((Get-Content -LiteralPath $ctrS -Raw).Trim()) + 1
            Set-Content -LiteralPath $ctrS -Value "$n" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path (Get-Location).Path "s-$n.txt") -Value "$n" -Encoding utf8NoBOM
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $fxS = New-VerifyFixture -Name 'vsS' -VProfile $passProfile
        # New-AgenticSpawner sets spend from the cost estimate; both attempts share the same
        # tier, so summed spend == 2x a single attempt. Assert attempt-2 spend was not dropped.
        $inS = New-AgenticSpawner -Worktree $fxS.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxS.runDir -Dispatcher $dispS
        $vsS = New-VerifyingSpawner -InnerSpawner $inS -Worktree $fxS.wt.worktree -BaseSha $fxS.wt.base_sha -RunDir $fxS.runDir -FrozenContracts $fxS.frozen
        $inS1 = & $inS (New-VerifyTask)   # measure a single inner attempt's spend in isolation
        $singleSpend = [double]$inS1.spend
        Set-Content -LiteralPath $ctrS -Value '0' -Encoding utf8NoBOM
        $fxS2 = New-VerifyFixture -Name 'vsS2' -VProfile $passProfile
        $inS2 = New-AgenticSpawner -Worktree $fxS2.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxS2.runDir -Dispatcher $dispS
        $vsS2 = New-VerifyingSpawner -InnerSpawner $inS2 -Worktree $fxS2.wt.worktree -BaseSha $fxS2.wt.base_sha -RunDir $fxS2.runDir -FrozenContracts $fxS2.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hook2
        try { $rvS = & $vsS2 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS10 retried true' ($rvS.verification.retried -eq $true)
        Check 'VS10 spend summed across both attempts' ([Math]::Abs([double]$rvS.spend - (2 * $singleSpend)) -lt 0.0001)
    } finally {
        if ($null -eq $savedBatonHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue }
        else { $env:BATON_HOME = $savedBatonHome }
    }
} finally {
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL PASS'
