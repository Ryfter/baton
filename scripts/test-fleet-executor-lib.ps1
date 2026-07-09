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
    command_template: 'echo "{{prompt}}"'
'@
        $toolsPath = Join-Path $env:BATON_HOME 'tools.yaml'   # intentionally absent file
        $repo2 = New-TempRepo -Root (New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'sp')).FullName
        $wt2 = New-RunWorktree -RepoPath $repo2 -RunId 'go-sp1'
        $runDir2 = Join-Path $tmpRoot 'run-sp1'
        New-Item -ItemType Directory -Force -Path $runDir2 | Out-Null
        $task = [pscustomobject]@{ id = 't1'; desc = 'write the feature'; capability = 'code-gen' }

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

        # dispatcher that does NOTHING, exit 0
        $noopDisp = { param($pick, $prompt) @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 } }
        $sp2 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r2 = & $sp2 $task
        Check 'P9 no-op exit 0 is ok' ($r2.ok -eq $true)
        Check 'P10 no-op why says no changes' ($r2.why -match 'no changes')

        # dispatcher that FAILS (exit 1)
        $failDisp = { param($pick, $prompt) @{ stdout = ''; stderr = 'boom'; exit_code = 1; duration_s = 0 } }
        $sp3 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -Dispatcher $failDisp
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
    } finally {
        if ($null -eq $savedBatonHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue }
        else { $env:BATON_HOME = $savedBatonHome }
    }
} finally {
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL PASS'
