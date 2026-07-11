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
        $sp8 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -Dispatcher $throwDisp
        $cwdBeforeThrow = (Get-Location).Path
        $r8 = & $sp8 $task
        Check 'M4a dispatcher throw is caught, task returns not-ok' ($r8.ok -eq $false)
        Check 'M4a why records dispatch error' ($r8.why -match 'dispatch error')
        Check 'M4b caller cwd unchanged after a dispatch throw' ((Get-Location).Path -eq $cwdBeforeThrow)

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
        # the original task, and caps the raw-output excerpt.
        $vs7out = Join-Path $tmpRoot 'vs7-out.txt'
        Set-Content -LiteralPath $vs7out -Value ('E' * 5000) -Encoding utf8NoBOM
        $vs7prompt = Format-VerifyEvidencePrompt -TaskDesc 'Original task text' -Verification @{ failure_category = 'check-failed' } -OutputPath $vs7out -MaxExcerpt 100
        Check 'VS7 includes failure category' ($vs7prompt -match 'check-failed')
        Check 'VS7 includes fix-in-place instruction' ($vs7prompt -match 'Fix the EXISTING work')
        Check 'VS7 includes original task' ($vs7prompt -match 'Original task text')
        Check 'VS7 excerpt capped/truncated' ($vs7prompt -match 'truncated')
    } finally {
        if ($null -eq $savedBatonHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue }
        else { $env:BATON_HOME = $savedBatonHome }
    }
} finally {
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL PASS'
