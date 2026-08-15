#!/usr/bin/env pwsh
<# Hermetic tests for engine-owned rework (#128 slice 2 / engine-expressiveness §4).
   Fake-spawner / fixture pattern mirrors test-fleet-executor-lib.ps1 VS-series. #>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-executor-lib.ps1"
. "$PSScriptRoot/conductor-lib.ps1"

$script:fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" }
    else { Write-Host "FAIL: $n"; $script:fail++ }
}

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

function New-VerifyFixture {
    param([string]$Name, [hashtable]$VProfile, [string]$CheckBody = 'exit 0', [string]$Root)
    $r = New-TempRepo -Root (New-Item -ItemType Directory -Force -Path (Join-Path $Root $Name)).FullName
    Set-Content -LiteralPath (Join-Path $r 'check.ps1') -Value $CheckBody -Encoding utf8NoBOM
    $cfgD = Join-Path $r '.baton'; New-Item -ItemType Directory -Force -Path $cfgD | Out-Null
    $cfg = @{ schema = 1; profiles = @{ unit = $VProfile } }
    ConvertTo-Json -InputObject $cfg -Depth 8 | Set-Content -LiteralPath (Join-Path $cfgD 'verification.json') -Encoding utf8NoBOM
    & git -C $r add -A 2>$null | Out-Null
    & git -C $r commit -q -m 'add verify config' 2>$null | Out-Null
    $w = New-RunWorktree -RepoPath $r -RunId "$Name-wt"
    $rd = Join-Path $Root "$Name-run"; New-Item -ItemType Directory -Force -Path $rd | Out-Null
    $fc = Get-FrozenVerificationContract -RepoPath $r -BaseSha $w.base_sha -ProfileName 'unit' -WorktreeRoot $w.worktree -RunTaskDir (Join-Path $rd 'tasks/t1')
    return @{ repo = $r; wt = $w; runDir = $rd; frozen = @{ 't1' = @{ contract = $fc.contract; contract_path = $fc.contract_path } }; fcOk = $fc.ok }
}

function New-VerifyTask {
    param(
        [string[]]$Allowed = @('src/**'),
        [string]$Profile = 'unit',
        [string]$Stakes = 'high',
        [string]$StakesBasis = 'auth boundary',
        $MaxRework = $null
    )
    $o = [ordered]@{
        id = 't1'; desc = 'implement the feature'; command = ''; capability = 'code-gen'
        depends_on = @(); est_cost_tier = 'free'; reversible = $true
        verify_profile = $Profile; allowed_paths = $Allowed
        stakes = $Stakes; stakes_basis = $StakesBasis
    }
    if ($null -ne $MaxRework) { $o['max_rework'] = $MaxRework }
    return [pscustomobject]$o
}

function Get-Attempts { param($rd) @(Get-Content -LiteralPath (Join-Path $rd 'tasks/t1/attempts.jsonl') -ErrorAction SilentlyContinue) }

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "engine-rework-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$savedBatonHome = $env:BATON_HOME
$savedMaxRework = $env:BATON_MAX_REWORK
$savedObserve = $env:BATON_ROUTING_OBSERVE
try {
    $env:BATON_HOME = Join-Path $tmpRoot 'baton-home'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    Remove-Item env:BATON_MAX_REWORK -ErrorAction SilentlyContinue
    # #159: isolating — never write outcome ratings into the real knowledge store.
    $env:BATON_ROUTING_OBSERVE = 'off'

    $fleetPath = Join-Path $env:BATON_HOME 'fleet.yaml'
    Set-Content -LiteralPath $fleetPath -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-agentic
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    command_template: 'echo "{{prompt}}"'
'@
    $toolsPath = Join-Path $env:BATON_HOME 'tools.yaml'
    $passProfile = @{ argv = @('pwsh', '-NoProfile', '-File', 'check.ps1'); proves = 'the unit check passes' }

    $writeDisp = {
        param($pick, $prompt)
        Set-Content -LiteralPath (Join-Path (Get-Location).Path "w-$([guid]::NewGuid()).txt") -Value $prompt -Encoding utf8NoBOM
        @{ stdout = "## Task output`nresidue from worker"; stderr = ''; exit_code = 0; duration_s = 0 }
    }

    # ---- Pure helpers ----
    Check 'H1 DefaultMaxRework is 1' ($script:DefaultMaxRework -eq 1)
    Check 'H1b AbsoluteMaxRework is 3' ($script:AbsoluteMaxRework -eq 3)
    Check 'H2 Resolve-MaxRework default 1' ((Resolve-MaxRework) -eq 1)
    # task.max_rework may LOWER under the operator ceiling, never raise: no env => envOrDefault=1
    Check 'H3 Resolve-MaxRework task=2 no env -> 1 (operator default caps)' (
        (Resolve-MaxRework -Task ([pscustomobject]@{ max_rework = 2 })) -eq 1)
    $env:BATON_MAX_REWORK = '1'
    Check 'H3b task=50 + env=1 -> 1' ((Resolve-MaxRework -Task ([pscustomobject]@{ max_rework = 50 })) -eq 1)
    Remove-Item env:BATON_MAX_REWORK -ErrorAction SilentlyContinue
    Check 'H3c task=0 -> 0 (may lower)' ((Resolve-MaxRework -Task ([pscustomobject]@{ max_rework = 0 })) -eq 0)
    $env:BATON_MAX_REWORK = '2'
    Check 'H3d env=2 task=1 -> 1 (task lowers)' ((Resolve-MaxRework -Task ([pscustomobject]@{ max_rework = 1 })) -eq 1)
    Check 'H3e env=2 no task -> 2' ((Resolve-MaxRework) -eq 2)
    $env:BATON_MAX_REWORK = '5'
    Check 'H3f env=5 no task -> hardcap 3' ((Resolve-MaxRework) -eq 3)
    Remove-Item env:BATON_MAX_REWORK -ErrorAction SilentlyContinue
    Check 'H4 Resolve-MaxRework override 0 wins' ((Resolve-MaxRework -Task ([pscustomobject]@{ max_rework = 9 }) -Override 0) -eq 0)
    Check 'H4b Override 9 hard-clamped to AbsoluteMaxRework' ((Resolve-MaxRework -Override 9) -eq 3)
    Check 'H5 Normalize collapses whitespace' (
        (Normalize-ReworkEvidenceText -Text "a  b`r`n c ") -eq (Normalize-ReworkEvidenceText -Text "a b`nc"))
    $normA = Normalize-ReworkEvidenceText -Text "fail at 2026-07-24T12:34:56Z path=$($env:TEMP)\rework-aaa\out.txt done"
    $normB = Normalize-ReworkEvidenceText -Text "fail at 2026-07-24T99:00:00Z path=$($env:TEMP)\rework-bbb\out.txt done"
    Check 'H5b Normalize masks timestamp+temp path (identical after)' ($normA -eq $normB -and $normA -match '<TIMESTAMP>' -and $normA -match '<TEMP_PATH>')
    Check 'H6 Test-ReworkableFailure check-failed' (Test-ReworkableFailure -FailureCategory 'check-failed')
    Check 'H7 Test-ReworkableFailure scope-violation false' (-not (Test-ReworkableFailure -FailureCategory 'scope-violation'))
    Check 'H8 Test-ReworkableFailure protected-path false' (-not (Test-ReworkableFailure -FailureCategory 'protected-path-mutated'))

    # ---- (a) check-fail -> one rework synthesized with inheritance + evidence-bearing desc ----
    $hookFailPass = Join-Path $tmpRoot 'hook-fail-pass.ps1'
    Set-Content -LiteralPath $hookFailPass -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    if ($Attempt -ge 2) { return @{ verdict='pass'; ok=$true; grade='bounded'; failure_category=''; proves='hooked pass'; output_path=''; duration_ms=5 } }
    $out = Join-Path ([System.IO.Path]::GetTempPath()) "rework-check-$([guid]::NewGuid()).txt"
    Set-Content -LiteralPath $out -Value 'ASSERT failed: expected 2 got 1' -Encoding utf8NoBOM
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=$out; duration_ms=5 }
}
'@
    $seenPromptA = [ref]''
    $dispA = {
        param($pick, $prompt)
        $seenPromptA.Value = [string]$prompt
        Set-Content -LiteralPath (Join-Path (Get-Location).Path "a-$([guid]::NewGuid()).txt") -Value $prompt -Encoding utf8NoBOM
        @{ stdout = "## Task output`nworker residue A"; stderr = ''; exit_code = 0; duration_s = 0 }
    }.GetNewClosure()
    $fxA = New-VerifyFixture -Name 'a' -VProfile $passProfile -Root $tmpRoot
    $inA = New-AgenticSpawner -Worktree $fxA.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxA.runDir -Dispatcher $dispA
    $vsA = New-VerifyingSpawner -InnerSpawner $inA -Worktree $fxA.wt.worktree -BaseSha $fxA.wt.base_sha -RunDir $fxA.runDir -FrozenContracts $fxA.frozen
    $env:BATON_VERIFY_TEST_HOOK = $hookFailPass
    try {
        $taskA = New-VerifyTask -Allowed @('src/**', 'lib/**') -Stakes 'high' -StakesBasis 'auth boundary'
        $rvA = & $vsA $taskA
    } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }

    Check 'A1 rework cycle count is 1' ($rvA.verification.rework_cycles -eq 1)
    Check 'A2 retried compat true' ($rvA.verification.retried -eq $true)
    Check 'A3 final ok true' ($rvA.ok -eq $true)
    Check 'A4 two attempt rows' (@(Get-Attempts $fxA.runDir).Count -eq 2)
    $evidA = Join-Path $fxA.runDir 'tasks/t1/rework-evidence-1.md'
    Check 'A5 rework-evidence-1.md written' (Test-Path -LiteralPath $evidA)
    $evidBodyA = Get-Content -LiteralPath $evidA -Raw
    Check 'A6 evidence carries check output excerpt' ($evidBodyA -match 'ASSERT failed')
    Check 'A7 evidence carries Failure: check-failed' ($evidBodyA -match 'Failure: check-failed')
    Check 'A8 evidence carries bus residue section' ($evidBodyA -match '## Inputs from t1')
    Check 'A9 rework prompt inherits via Task: evidence (not inventing scope)' (
        ($seenPromptA.Value -match 'ASSERT failed') -or ($evidBodyA -match 'ASSERT failed'))
    # Inheritance is structural: rework task is a copy — frozen contract + allowed paths used for verify stay the original task's.
    Check 'A10 max_rework default 1 on verification' ($rvA.verification.max_rework -eq 1)
    Check 'A11 reworks[0].evidence_path names file' (
        [string]$rvA.verification.reworks[0].evidence_path -match 'rework-evidence-1\.md')
    Check 'A12 reworks[0].outcome passed' ([string]$rvA.verification.reworks[0].outcome -eq 'passed')

    # ---- (b) rework passes -> walk continues, journal shows started+passed ----
    $runB = Join-Path $tmpRoot 'run-b'; New-Item -ItemType Directory -Force -Path $runB | Out-Null
    $planB = {
        param($g)
        @{
            goal = $g; budget_cap = $null
            tasks = @([pscustomobject]@{
                id = 't1'; desc = 'edit'; command = ''; capability = 'code-gen'
                depends_on = @(); est_cost_tier = 'free'; reversible = $true
                verify_profile = 'unit'; allowed_paths = @('src/**')
                stakes = 'standard'; stakes_basis = 'ordinary'
            })
        }
    }
    $spB = {
        param($t)
        @{
            ok = $true; spend = 0.1; chose = 'fake-agentic'; why = 'ok'; alternatives = @()
            verification = @{
                verdict = 'pass'; grade = 'bounded'; failure_category = ''; proves = 'fixed'
                retried = $true; first_failure_category = 'check-failed'
                rework_cycles = 1; max_rework = 1; rework_halt_reason = ''
                reworks = @(@{
                    cycle = 1
                    evidence_path = (Join-Path $runB 'tasks/t1/rework-evidence-1.md')
                    outcome = 'passed'; failure_category = ''; attempt = 2
                })
            }
        }
    }.GetNewClosure()
    New-Item -ItemType Directory -Force -Path (Join-Path $runB 'tasks/t1') | Out-Null
    Set-Content -LiteralPath (Join-Path $runB 'tasks/t1/rework-evidence-1.md') -Value 'Failure: check-failed' -Encoding utf8NoBOM
    $resB = Invoke-Conductor -Goal 'g' -RunDir $runB -Planner $planB -Spawner $spB -Verify -VerifyPreflight { param($p) @{ ok = $true } }
    $evB = Get-Content -LiteralPath (Join-Path $runB 'events.jsonl') -Raw
    $decB = Get-Content -LiteralPath (Join-Path $runB 'decisions.jsonl') -Raw
    Check 'B1 walk status completed' ($resB.status -eq 'completed')
    Check 'B2 task-rework-started journaled' ($evB -match 'task-rework-started')
    Check 'B3 task-rework-passed journaled' ($evB -match 'task-rework-passed')
    Check 'B4 decisions.jsonl names evidence path' ($decB -match 'rework-evidence-1\.md')
    Check 'B5 decisions chose rework' ($decB -match '"chose":"rework"')

    # ---- (c) rework fails -> loud halt, both attempts' evidence retained, started+failed ----
    $hookFailFail = Join-Path $tmpRoot 'hook-fail-fail.ps1'
    Set-Content -LiteralPath $hookFailFail -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    $out = Join-Path ([System.IO.Path]::GetTempPath()) "rework-ff-$Attempt-$([guid]::NewGuid()).txt"
    Set-Content -LiteralPath $out -Value "fail attempt $Attempt detail" -Encoding utf8NoBOM
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=$out; duration_ms=5 }
}
'@
    $fxC = New-VerifyFixture -Name 'c' -VProfile $passProfile -Root $tmpRoot
    $inC = New-AgenticSpawner -Worktree $fxC.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxC.runDir -Dispatcher $writeDisp
    $vsC = New-VerifyingSpawner -InnerSpawner $inC -Worktree $fxC.wt.worktree -BaseSha $fxC.wt.base_sha -RunDir $fxC.runDir -FrozenContracts $fxC.frozen
    $env:BATON_VERIFY_TEST_HOOK = $hookFailFail
    try { $rvC = & $vsC (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
    Check 'C1 rework failed ok false' ($rvC.ok -eq $false)
    Check 'C2 two attempt rows retained' (@(Get-Attempts $fxC.runDir).Count -eq 2)
    Check 'C3 rework-evidence-1.md retained' (Test-Path -LiteralPath (Join-Path $fxC.runDir 'tasks/t1/rework-evidence-1.md'))
    Check 'C4 attempts.jsonl has attempt 1 and 2' (
        ((Get-Attempts $fxC.runDir) -join "`n") -match '"attempt":1' -and
        ((Get-Attempts $fxC.runDir) -join "`n") -match '"attempt":2')
    Check 'C5 reworks[0].outcome failed' ([string]$rvC.verification.reworks[0].outcome -eq 'failed')
    Check 'C6 halt reason max_rework' ([string]$rvC.verification.rework_halt_reason -eq 'max_rework')

    $runC2 = Join-Path $tmpRoot 'run-c2'; New-Item -ItemType Directory -Force -Path $runC2 | Out-Null
    $spC2 = {
        param($t)
        @{
            ok = $false; spend = 0.05; chose = 'fake-agentic'; why = 'fail'; alternatives = @()
            verification = @{
                verdict = 'fail'; grade = 'invalid'; failure_category = 'check-failed'; proves = 'x'
                retried = $true; first_failure_category = 'check-failed'
                rework_cycles = 1; max_rework = 1; rework_halt_reason = 'max_rework'
                reworks = @(@{
                    cycle = 1
                    evidence_path = (Join-Path $runC2 'tasks/t1/rework-evidence-1.md')
                    outcome = 'failed'; failure_category = 'check-failed'; attempt = 2
                })
            }
        }
    }.GetNewClosure()
    New-Item -ItemType Directory -Force -Path (Join-Path $runC2 'tasks/t1') | Out-Null
    Set-Content -LiteralPath (Join-Path $runC2 'tasks/t1/rework-evidence-1.md') -Value 'fail evidence' -Encoding utf8NoBOM
    $resC2 = Invoke-Conductor -Goal 'g' -RunDir $runC2 -Planner $planB -Spawner $spC2 -Verify -VerifyPreflight { param($p) @{ ok = $true } }
    $evC2 = Get-Content -LiteralPath (Join-Path $runC2 'events.jsonl') -Raw
    Check 'C7 conductor status verification-failed' ($resC2.status -eq 'verification-failed')
    Check 'C8 task-rework-started journaled' ($evC2 -match 'task-rework-started')
    Check 'C9 task-rework-failed journaled' ($evC2 -match 'task-rework-failed')

    # ---- (d) max_rework=1 enforced mechanically (no third cycle) ----
    $callCountD = [ref]0
    $hookAlwaysFail = Join-Path $tmpRoot 'hook-always-fail.ps1'
    Set-Content -LiteralPath $hookAlwaysFail -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=''; duration_ms=5 }
}
'@
    $dispD = {
        param($pick, $prompt)
        $callCountD.Value++
        Set-Content -LiteralPath (Join-Path (Get-Location).Path "d-$($callCountD.Value).txt") -Value $prompt -Encoding utf8NoBOM
        @{ stdout = "## Task output`ncycle $($callCountD.Value)"; stderr = ''; exit_code = 0; duration_s = 0 }
    }.GetNewClosure()
    $fxD = New-VerifyFixture -Name 'd' -VProfile $passProfile -Root $tmpRoot
    $inD = New-AgenticSpawner -Worktree $fxD.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxD.runDir -Dispatcher $dispD
    $vsD = New-VerifyingSpawner -InnerSpawner $inD -Worktree $fxD.wt.worktree -BaseSha $fxD.wt.base_sha -RunDir $fxD.runDir -FrozenContracts $fxD.frozen -MaxRework 1
    $env:BATON_VERIFY_TEST_HOOK = $hookAlwaysFail
    try { $rvD = & $vsD (New-VerifyTask -MaxRework 99) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
    # Override param wins over task field (Resolve-MaxRework), so MaxRework=1 on spawner.
    Check 'D1 exactly 2 labor dispatches (attempt+1 rework)' ($callCountD.Value -eq 2)
    Check 'D2 rework_cycles is 1' ($rvD.verification.rework_cycles -eq 1)
    Check 'D3 attempt rows exactly 2' (@(Get-Attempts $fxD.runDir).Count -eq 2)
    Check 'D4 no rework-evidence-2.md' (-not (Test-Path -LiteralPath (Join-Path $fxD.runDir 'tasks/t1/rework-evidence-2.md')))
    Check 'D5 max_rework recorded as 1' ($rvD.verification.max_rework -eq 1)

    # ---- (e) identical-evidence halt (max_rework=2 but same evidence stops loop) ----
    $fxE = New-VerifyFixture -Name 'e' -VProfile $passProfile -Root $tmpRoot
    # Same check output every time so evidence text is identical across cycles.
    $stableOut = Join-Path $tmpRoot 'stable-check-out.txt'
    Set-Content -LiteralPath $stableOut -Value 'SAME FAIL ALWAYS' -Encoding utf8NoBOM
    $hookIdent = Join-Path $tmpRoot 'hook-ident.ps1'
    # Write path via env so the hook file needs no Windows path quoting gymnastics.
    $env:BATON_REWORK_TEST_STABLE_OUT = $stableOut
    Set-Content -LiteralPath $hookIdent -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    return @{
        verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'
        proves='hooked'; output_path=$env:BATON_REWORK_TEST_STABLE_OUT; duration_ms=5
    }
}
'@
    # Identical stdout each attempt so bus residue does not diverge.
    $callCountE = [ref]0
    $dispE = {
        param($pick, $prompt)
        $callCountE.Value++
        Set-Content -LiteralPath (Join-Path (Get-Location).Path "e-$($callCountE.Value).txt") -Value 'x' -Encoding utf8NoBOM
        @{ stdout = "## Task output`nsame"; stderr = ''; exit_code = 0; duration_s = 0 }
    }.GetNewClosure()
    $inE = New-AgenticSpawner -Worktree $fxE.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxE.runDir -Dispatcher $dispE
    $vsE = New-VerifyingSpawner -InnerSpawner $inE -Worktree $fxE.wt.worktree -BaseSha $fxE.wt.base_sha -RunDir $fxE.runDir -FrozenContracts $fxE.frozen -MaxRework 2
    $env:BATON_VERIFY_TEST_HOOK = $hookIdent
    try { $rvE = & $vsE (New-VerifyTask) } finally {
        Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue
        Remove-Item env:BATON_REWORK_TEST_STABLE_OUT -ErrorAction SilentlyContinue
    }
    Check 'E1 identical-evidence halt reason' ([string]$rvE.verification.rework_halt_reason -eq 'identical-evidence')
    Check 'E2 only one rework cycle despite max_rework=2' ($rvE.verification.rework_cycles -eq 1)
    Check 'E3 only two labor dispatches' ($callCountE.Value -eq 2)
    Check 'E4 no third attempt row' (@(Get-Attempts $fxE.runDir).Count -eq 2)

    # ---- (e2) identical-evidence halt when evidences differ ONLY by volatile tokens ----
    $fxE2 = New-VerifyFixture -Name 'e2' -VProfile $passProfile -Root $tmpRoot
    $hookVol = Join-Path $tmpRoot 'hook-volatile.ps1'
    Set-Content -LiteralPath $hookVol -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    $ts = if ($Attempt -eq 1) { '2026-07-24T10:00:00Z' } else { '2026-07-24T11:22:33Z' }
    $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("rework-vol-$Attempt-" + [guid]::NewGuid().ToString() + ".txt")
    Set-Content -LiteralPath $tmpFile -Value "ASSERT failed: expected 2 got 1 at $ts file=$tmpFile" -Encoding utf8NoBOM
    return @{
        verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'
        proves='hooked'; output_path=$tmpFile; duration_ms=5
    }
}
'@
    $callCountE2 = [ref]0
    $dispE2 = {
        param($pick, $prompt)
        $callCountE2.Value++
        Set-Content -LiteralPath (Join-Path (Get-Location).Path "e2-$($callCountE2.Value).txt") -Value 'x' -Encoding utf8NoBOM
        @{ stdout = "## Task output`nsame residue"; stderr = ''; exit_code = 0; duration_s = 0 }
    }.GetNewClosure()
    $inE2 = New-AgenticSpawner -Worktree $fxE2.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxE2.runDir -Dispatcher $dispE2
    $vsE2 = New-VerifyingSpawner -InnerSpawner $inE2 -Worktree $fxE2.wt.worktree -BaseSha $fxE2.wt.base_sha -RunDir $fxE2.runDir -FrozenContracts $fxE2.frozen -MaxRework 2
    $env:BATON_VERIFY_TEST_HOOK = $hookVol
    try { $rvE2 = & $vsE2 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
    Check 'E2v1 volatile tokens still halt identical-evidence' ([string]$rvE2.verification.rework_halt_reason -eq 'identical-evidence')
    Check 'E2v2 only one rework cycle (second failure matched after normalize)' ($rvE2.verification.rework_cycles -eq 1)
    Check 'E2v3 only two labor dispatches' ($callCountE2.Value -eq 2)

    # ---- (f) scope-violation -> NO rework (fail-closed unchanged) ----
    $forbidDisp = {
        param($pick, $prompt)
        Set-Content -LiteralPath (Join-Path (Get-Location).Path 'forbidden.txt') -Value 'x' -Encoding utf8NoBOM
        @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
    }
    $fxF = New-VerifyFixture -Name 'f' -VProfile $passProfile -Root $tmpRoot
    $inF = New-AgenticSpawner -Worktree $fxF.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxF.runDir -Dispatcher $forbidDisp
    $vsF = New-VerifyingSpawner -InnerSpawner $inF -Worktree $fxF.wt.worktree -BaseSha $fxF.wt.base_sha -RunDir $fxF.runDir -FrozenContracts $fxF.frozen
    $rvF = & $vsF (New-VerifyTask -Allowed @('allowed.txt'))
    Check 'F1 scope-violation verdict' (
        [string]$rvF.verification.verdict -eq 'scope-violation' -or
        [string]$rvF.verification.failure_category -eq 'scope-violation' -or
        [string]$rvF.verification.verdict -match 'scope')
    Check 'F2 not ok' ($rvF.ok -eq $false)
    Check 'F3 rework_cycles 0' ($rvF.verification.rework_cycles -eq 0)
    Check 'F4 retried false' ($rvF.verification.retried -eq $false)
    Check 'F5 exactly one attempt row' (@(Get-Attempts $fxF.runDir).Count -eq 1)
    Check 'F6 no rework-evidence file' (-not (Test-Path -LiteralPath (Join-Path $fxF.runDir 'tasks/t1/rework-evidence-1.md')))
    Check 'F7 no max_rework halt on initial scope-violation' ([string]$rvF.verification.rework_halt_reason -eq '')

    # ---- (f2) rework produces scope-violation -> haltReason is category, not max_rework ----
    $hookFailThenScope = Join-Path $tmpRoot 'hook-fail-then-scope.ps1'
    # Attempt 1: check-failed (reworkable). Attempt 2+: we still report check-failed from the
    # hook, but the dispatcher writes an out-of-scope file so the real verify path would
    # scope-violate — force category via hook on attempt>=2 for hermetic control.
    Set-Content -LiteralPath $hookFailThenScope -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    if ($Attempt -ge 2) {
        return @{ verdict='scope-violation'; ok=$false; grade='invalid'; failure_category='scope-violation'; proves='hooked'; output_path=''; duration_ms=5 }
    }
    $out = Join-Path ([System.IO.Path]::GetTempPath()) "rework-fts-$([guid]::NewGuid()).txt"
    Set-Content -LiteralPath $out -Value 'ASSERT fail first' -Encoding utf8NoBOM
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=$out; duration_ms=5 }
}
'@
    $fxF2 = New-VerifyFixture -Name 'f2' -VProfile $passProfile -Root $tmpRoot
    $inF2 = New-AgenticSpawner -Worktree $fxF2.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxF2.runDir -Dispatcher $writeDisp
    $vsF2 = New-VerifyingSpawner -InnerSpawner $inF2 -Worktree $fxF2.wt.worktree -BaseSha $fxF2.wt.base_sha -RunDir $fxF2.runDir -FrozenContracts $fxF2.frozen
    $env:BATON_VERIFY_TEST_HOOK = $hookFailThenScope
    try { $rvF2 = & $vsF2 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
    Check 'F2-1 rework attempted once' ($rvF2.verification.rework_cycles -eq 1)
    Check 'F2-2 haltReason is scope-violation not max_rework' ([string]$rvF2.verification.rework_halt_reason -eq 'scope-violation')
    Check 'F2-3 not ok' ($rvF2.ok -eq $false)

    # ---- (g) old single-retry path absent: exactly max_rework cycles total; no double-retry ----
    # With max_rework=1, total attempts = 1 + 1 = 2. Grep spawner source has no second independent retry.
    $srcVs = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fleet-executor-lib.ps1') -Raw
    Check 'G1 New-VerifyingSpawner documents rework subsumption' ($srcVs -match 'SUBSUMES the old single evidence-informed')
    Check 'G2 rework loop uses Resolve-MaxRework' ($srcVs -match 'Resolve-MaxRework')
    # No separate "retry once then maybe again" — only the while loop over max_rework.
    Check 'G3 no separate retried=`$true one-shot block for Format-VerifyEvidencePrompt retry' (
        $srcVs -notmatch 'exactly one evidence-informed retry in the SAME worktree')
    Check 'G4 D-case proved max_rework cycles total' ($rvD.verification.rework_cycles -eq $rvD.verification.max_rework)

    # ---- (h) needs-polish acceptance rework (minimal seam) ----
    $runH = Join-Path $tmpRoot 'run-h'; New-Item -ItemType Directory -Force -Path $runH | Out-Null
    $gateCalls = [ref]0
    $spawnerCalls = [ref]0
    $gaterH = {
        param($art, $goal)
        $gateCalls.Value++
        if ($gateCalls.Value -eq 1) {
            return [ordered]@{
                verdict = 'polish'
                reason = '1 important finding'
                counts = @{ critical = 0; important = 1; minor = 0 }
                findings = @(@{ severity = 'important'; area = 'tests'; summary = 'missing coverage for edge case'; agreed = $true })
                polish_brief = 'POLISH BRIEF — fix missing coverage for edge case'
                degraded = $false
            }
        }
        return [ordered]@{
            verdict = 'accept'
            reason = 'no findings'
            counts = @{ critical = 0; important = 0; minor = 0 }
            findings = @()
            polish_brief = 'No polish needed — artifact accepted as-is.'
            degraded = $false
        }
    }.GetNewClosure()
    $spH = {
        param($t)
        $spawnerCalls.Value++
        @{
            ok = $true; spend = 0.02; chose = 'fake-agentic'; why = "rework $($t.id)"; alternatives = @()
        }
    }.GetNewClosure()
    $planH = {
        param($g)
        @{
            goal = $g; budget_cap = $null
            tasks = @([pscustomobject]@{
                id = 't1'; desc = 'implement'; command = ''; capability = 'code-gen'
                depends_on = @(); est_cost_tier = 'free'; reversible = $true
                verify_profile = 'unit'; allowed_paths = @('src/**')
                stakes = 'high'; stakes_basis = 'auth'
            })
        }
    }
    $resH = Invoke-Conductor -Goal 'g' -RunDir $runH -Planner $planH -Spawner $spH `
        -Gater $gaterH -GateArtifact 'diff body' -AcceptanceGate:$true -AcceptanceFailLoud
    $evH = Get-Content -LiteralPath (Join-Path $runH 'events.jsonl') -Raw
    Check 'H-acc1 status completed after polish rework' ($resH.status -eq 'completed')
    Check 'H-acc2 gater called twice (initial + re-panel)' ($gateCalls.Value -eq 2)
    Check 'H-acc3 spawner called for acceptance-rework-1' ($spawnerCalls.Value -ge 1)
    Check 'H-acc4 task-rework-started for acceptance' ($evH -match 'acceptance needs-polish rework')
    Check 'H-acc5 task-rework-passed for acceptance' ($evH -match 'task-rework-passed')
    Check 'H-acc6 evidence file written' (Test-Path -LiteralPath (Join-Path $runH 'acceptance-rework-evidence-1.md'))
    Check 'H-acc7 prior acceptance retained' (Test-Path -LiteralPath (Join-Path $runH 'acceptance-prior.json'))
    $priorH = Get-Content -LiteralPath (Join-Path $runH 'acceptance-prior.json') -Raw | ConvertFrom-Json
    Check 'H-acc8 prior verdict was polish' ([string]$priorH.verdict -eq 'polish')
    Check 'H-acc9 final acceptance is accept' ([string]$resH.acceptance.verdict -eq 'accept')

    # (h2) needs-polish rework that still polishes -> halt, both verdicts retained
    $runH2 = Join-Path $tmpRoot 'run-h2'; New-Item -ItemType Directory -Force -Path $runH2 | Out-Null
    $gateCalls2 = [ref]0
    $gaterH2 = {
        param($art, $goal)
        $gateCalls2.Value++
        return [ordered]@{
            verdict = 'polish'
            reason = 'still broken'
            counts = @{ critical = 0; important = 1; minor = 0 }
            findings = @(@{ severity = 'important'; area = 'x'; summary = 'still broken'; agreed = $true })
            polish_brief = 'POLISH BRIEF — still broken'
            degraded = $false
        }
    }.GetNewClosure()
    $spH2 = { param($t) @{ ok = $true; spend = 0.01; chose = 'w'; why = 'ok'; alternatives = @() } }
    $resH2 = Invoke-Conductor -Goal 'g' -RunDir $runH2 -Planner $planH -Spawner $spH2 `
        -Gater $gaterH2 -GateArtifact 'diff' -AcceptanceGate:$true -AcceptanceFailLoud
    Check 'H2-1 status needs-polish after failed rework' ($resH2.status -eq 'needs-polish')
    Check 'H2-2 both panels ran' ($gateCalls2.Value -eq 2)
    Check 'H2-3 prior retained on disk' (Test-Path -LiteralPath (Join-Path $runH2 'acceptance-prior.json'))
    Check 'H2-4 final gate has prior_acceptance' ($null -ne $resH2.acceptance.prior_acceptance)

    # ---- (h3) acceptance-rework IN-SCOPE file -> re-panel happens ----
    $repoAcc = New-TempRepo -Root (Join-Path $tmpRoot 'acc-in')
    $wtAccIn = New-RunWorktree -RepoPath $repoAcc -RunId 'acc-in-wt'
    $runH3 = Join-Path $tmpRoot 'run-h3'; New-Item -ItemType Directory -Force -Path $runH3 | Out-Null
    $gateCalls3 = [ref]0
    $gaterH3 = {
        param($art, $goal)
        $gateCalls3.Value++
        if ($gateCalls3.Value -eq 1) {
            return [ordered]@{
                verdict = 'polish'; reason = 'needs fix'; counts = @{ critical = 0; important = 1; minor = 0 }
                findings = @(@{ severity = 'important'; area = 'x'; summary = 'fix me'; agreed = $true })
                polish_brief = 'POLISH BRIEF — fix me'; degraded = $false
            }
        }
        return [ordered]@{
            verdict = 'accept'; reason = 'ok'; counts = @{ critical = 0; important = 0; minor = 0 }
            findings = @(); polish_brief = 'No polish needed — artifact accepted as-is.'; degraded = $false
        }
    }.GetNewClosure()
    $spH3 = {
        param($t)
        # Only the acceptance-rework attempt mutates the worktree (walk is a no-op)
        # so the scope check sees the rework attempt's real diff.
        if ([string]$t.id -eq 'acceptance-rework-1') {
            New-Item -ItemType Directory -Force -Path (Join-Path $wtAccIn.worktree 'src') | Out-Null
            Set-Content -LiteralPath (Join-Path $wtAccIn.worktree 'src/fixed.ps1') -Value 'fixed' -Encoding utf8NoBOM
        }
        @{ ok = $true; spend = 0.01; chose = 'fake-agentic'; why = 'in-scope rework'; alternatives = @() }
    }.GetNewClosure()
    $planH3 = {
        param($g)
        @{
            goal = $g; budget_cap = $null
            tasks = @([pscustomobject]@{
                id = 't1'; desc = 'implement'; command = ''; capability = 'code-gen'
                depends_on = @(); est_cost_tier = 'free'; reversible = $true
                verify_profile = 'unit'; allowed_paths = @('src/')
                stakes = 'high'; stakes_basis = 'auth'
            })
        }
    }
    $resH3 = Invoke-Conductor -Goal 'g' -RunDir $runH3 -Planner $planH3 -Spawner $spH3 `
        -Gater $gaterH3 -GateArtifact 'diff body' -AcceptanceGate:$true -AcceptanceFailLoud `
        -Worktree $wtAccIn.worktree
    $evH3 = Get-Content -LiteralPath (Join-Path $runH3 'events.jsonl') -Raw
    Check 'H3-acc1 in-scope rework re-panels' ($gateCalls3.Value -eq 2)
    Check 'H3-acc2 status completed' ($resH3.status -eq 'completed')
    Check 'H3-acc3 no scope-violation event' ($evH3 -notmatch 'acceptance-rework-scope-violation')

    # ---- (h4) acceptance-rework OUT-OF-SCOPE file -> halt event, no re-panel ----
    $repoAccOut = New-TempRepo -Root (Join-Path $tmpRoot 'acc-out')
    $wtAccOut = New-RunWorktree -RepoPath $repoAccOut -RunId 'acc-out-wt'
    $runH4 = Join-Path $tmpRoot 'run-h4'; New-Item -ItemType Directory -Force -Path $runH4 | Out-Null
    $gateCalls4 = [ref]0
    $gaterH4 = {
        param($art, $goal)
        $gateCalls4.Value++
        return [ordered]@{
            verdict = 'polish'; reason = 'needs fix'; counts = @{ critical = 0; important = 1; minor = 0 }
            findings = @(@{ severity = 'important'; area = 'x'; summary = 'fix me'; agreed = $true })
            polish_brief = 'POLISH BRIEF — fix me'; degraded = $false
        }
    }.GetNewClosure()
    $spH4 = {
        param($t)
        # Walk is a no-op; only acceptance-rework writes (out of union scope).
        if ([string]$t.id -eq 'acceptance-rework-1') {
            New-Item -ItemType Directory -Force -Path (Join-Path $wtAccOut.worktree 'secrets') | Out-Null
            Set-Content -LiteralPath (Join-Path $wtAccOut.worktree 'secrets/leak.txt') -Value 'nope' -Encoding utf8NoBOM
        }
        @{ ok = $true; spend = 0.01; chose = 'fake-agentic'; why = 'out-of-scope rework'; alternatives = @() }
    }.GetNewClosure()
    $planH4 = {
        param($g)
        @{
            goal = $g; budget_cap = $null
            tasks = @([pscustomobject]@{
                id = 't1'; desc = 'implement'; command = ''; capability = 'code-gen'
                depends_on = @(); est_cost_tier = 'free'; reversible = $true
                verify_profile = 'unit'; allowed_paths = @('src/')
                stakes = 'high'; stakes_basis = 'auth'
            })
        }
    }
    $resH4 = Invoke-Conductor -Goal 'g' -RunDir $runH4 -Planner $planH4 -Spawner $spH4 `
        -Gater $gaterH4 -GateArtifact 'diff body' -AcceptanceGate:$true -AcceptanceFailLoud `
        -Worktree $wtAccOut.worktree
    $evH4 = Get-Content -LiteralPath (Join-Path $runH4 'events.jsonl') -Raw
    Check 'H4-acc1 out-of-scope does NOT re-panel' ($gateCalls4.Value -eq 1)
    Check 'H4-acc2 status needs-polish' ($resH4.status -eq 'needs-polish')
    Check 'H4-acc3 acceptance-rework-scope-violation event' ($evH4 -match 'acceptance-rework-scope-violation')
    Check 'H4-acc4 scope diff retained' (Test-Path -LiteralPath (Join-Path $runH4 'acceptance-rework-scope-diff.txt'))
    Check 'H4-acc5 prior retained' (Test-Path -LiteralPath (Join-Path $runH4 'acceptance-prior.json'))

    # ---- (h5) acceptance-rework scope UNCHECKABLE (no pre-rework tree) -> fail-closed, no re-panel (#134) ----
    # Worktree path that does not exist: the pre-rework snapshot cannot be taken, so with a
    # non-empty allowed_paths union the rework diff is uncheckable — must halt, never silently
    # proceed to re-panel.
    $runH5 = Join-Path $tmpRoot 'run-h5'; New-Item -ItemType Directory -Force -Path $runH5 | Out-Null
    $gateCalls5 = [ref]0
    $gaterH5 = {
        param($art, $goal)
        $gateCalls5.Value++
        return [ordered]@{
            verdict = 'polish'; reason = 'needs fix'; counts = @{ critical = 0; important = 1; minor = 0 }
            findings = @(@{ severity = 'important'; area = 'x'; summary = 'fix me'; agreed = $true })
            polish_brief = 'POLISH BRIEF — fix me'; degraded = $false
        }
    }.GetNewClosure()
    $spH5 = { param($t) @{ ok = $true; spend = 0.01; chose = 'fake-agentic'; why = 'rework attempt'; alternatives = @() } }
    $planH5 = {
        param($g)
        @{
            goal = $g; budget_cap = $null
            tasks = @([pscustomobject]@{
                id = 't1'; desc = 'implement'; command = ''; capability = 'code-gen'
                depends_on = @(); est_cost_tier = 'free'; reversible = $true
                verify_profile = 'unit'; allowed_paths = @('src/')
                stakes = 'high'; stakes_basis = 'auth'
            })
        }
    }
    $resH5 = Invoke-Conductor -Goal 'g' -RunDir $runH5 -Planner $planH5 -Spawner $spH5 `
        -Gater $gaterH5 -GateArtifact 'diff body' -AcceptanceGate:$true -AcceptanceFailLoud `
        -Worktree (Join-Path $tmpRoot 'no-such-worktree')
    $evH5 = Get-Content -LiteralPath (Join-Path $runH5 'events.jsonl') -Raw
    Check 'H5-acc1 uncheckable does NOT re-panel' ($gateCalls5.Value -eq 1)
    Check 'H5-acc2 status needs-polish' ($resH5.status -eq 'needs-polish')
    Check 'H5-acc3 scope-violation vocabulary event' ($evH5 -match 'acceptance-rework-scope-violation')
    Check 'H5-acc4 uncheckable named in event' ($evH5 -match 'scope uncheckable')
    Check 'H5-acc5 prior retained' (Test-Path -LiteralPath (Join-Path $runH5 'acceptance-prior.json'))
    Check 'H5-acc6 rework reason scope-uncheckable' ([string]$resH5.acceptance.rework.reason -eq 'scope-uncheckable')

    # ---- (h5b) worktree EXISTS but is not a git repo -> pre-snapshot fails -> same fail-closed ----
    $plainDir = Join-Path $tmpRoot 'plain-not-a-repo'; New-Item -ItemType Directory -Force -Path $plainDir | Out-Null
    $runH5b = Join-Path $tmpRoot 'run-h5b'; New-Item -ItemType Directory -Force -Path $runH5b | Out-Null
    $gateCalls5b = [ref]0
    $gaterH5b = {
        param($art, $goal)
        $gateCalls5b.Value++
        return [ordered]@{
            verdict = 'polish'; reason = 'needs fix'; counts = @{ critical = 0; important = 1; minor = 0 }
            findings = @(@{ severity = 'important'; area = 'x'; summary = 'fix me'; agreed = $true })
            polish_brief = 'POLISH BRIEF — fix me'; degraded = $false
        }
    }.GetNewClosure()
    $resH5b = Invoke-Conductor -Goal 'g' -RunDir $runH5b -Planner $planH5 -Spawner $spH5 `
        -Gater $gaterH5b -GateArtifact 'diff body' -AcceptanceGate:$true -AcceptanceFailLoud `
        -Worktree $plainDir
    $evH5b = Get-Content -LiteralPath (Join-Path $runH5b 'events.jsonl') -Raw
    Check 'H5b-1 non-repo worktree does NOT re-panel' ($gateCalls5b.Value -eq 1)
    Check 'H5b-2 status needs-polish' ($resH5b.status -eq 'needs-polish')
    Check 'H5b-3 uncheckable named in event' ($evH5b -match 'scope uncheckable')
    Check 'H5b-4 rework reason scope-uncheckable' ([string]$resH5b.acceptance.rework.reason -eq 'scope-uncheckable')

    # ---- (h5c) POST-rework snapshot fails (spawner severs the worktree's .git link) -> fail-closed ----
    $repoAccPost = New-TempRepo -Root (Join-Path $tmpRoot 'acc-post')
    $wtAccPost = New-RunWorktree -RepoPath $repoAccPost -RunId 'acc-post-wt'
    $runH5c = Join-Path $tmpRoot 'run-h5c'; New-Item -ItemType Directory -Force -Path $runH5c | Out-Null
    $gateCalls5c = [ref]0
    $gaterH5c = {
        param($art, $goal)
        $gateCalls5c.Value++
        return [ordered]@{
            verdict = 'polish'; reason = 'needs fix'; counts = @{ critical = 0; important = 1; minor = 0 }
            findings = @(@{ severity = 'important'; area = 'x'; summary = 'fix me'; agreed = $true })
            polish_brief = 'POLISH BRIEF — fix me'; degraded = $false
        }
    }.GetNewClosure()
    $spH5c = {
        param($t)
        # Pre-snapshot succeeds (live worktree); the rework attempt then severs the
        # .git link so the POST snapshot cannot be taken.
        if ([string]$t.id -eq 'acceptance-rework-1') {
            Remove-Item -LiteralPath (Join-Path $wtAccPost.worktree '.git') -Recurse -Force -ErrorAction SilentlyContinue
        }
        @{ ok = $true; spend = 0.01; chose = 'fake-agentic'; why = 'rework attempt'; alternatives = @() }
    }.GetNewClosure()
    $resH5c = Invoke-Conductor -Goal 'g' -RunDir $runH5c -Planner $planH5 -Spawner $spH5c `
        -Gater $gaterH5c -GateArtifact 'diff body' -AcceptanceGate:$true -AcceptanceFailLoud `
        -Worktree $wtAccPost.worktree
    $evH5c = Get-Content -LiteralPath (Join-Path $runH5c 'events.jsonl') -Raw
    Check 'H5c-1 post-uncheckable does NOT re-panel' ($gateCalls5c.Value -eq 1)
    Check 'H5c-2 status needs-polish' ($resH5c.status -eq 'needs-polish')
    Check 'H5c-3 post-rework snapshot named in event' ($evH5c -match 'post-rework tree snapshot unavailable')
    Check 'H5c-4 rework reason scope-uncheckable' ([string]$resH5c.acceptance.rework.reason -eq 'scope-uncheckable')

} finally {
    if ($null -eq $savedBatonHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $savedBatonHome }
    if ($null -eq $savedMaxRework) { Remove-Item env:BATON_MAX_REWORK -ErrorAction SilentlyContinue }
    else { $env:BATON_MAX_REWORK = $savedMaxRework }
    if ($null -eq $savedObserve) { Remove-Item env:BATON_ROUTING_OBSERVE -ErrorAction SilentlyContinue }
    else { $env:BATON_ROUTING_OBSERVE = $savedObserve }
    Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL CHECKS PASS'; exit 0
