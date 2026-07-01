#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Tests for GEPA-inspired optimize-prompt-lib.ps1 (house Check/PASS-FAIL
  style — Pester failures don't propagate exit codes reliably here; this
  suite is exit-code gated).
.DESCRIPTION
  Hermetic: temp BATON_HOME, temp runs dirs, temp prompt files; never reads
  or writes the real ~/.claude or ~/.baton.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'optimize-prompt-lib.ps1')

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

function New-TempDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("opt-lib-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

$prevBatonHome = $env:BATON_HOME
try {
    # ---- Get-HistoricalRuns: nonexistent root -> empty ----
    $emptyRunsRoot = Join-Path (New-TempDir) 'nonexistent'
    $runsEmpty = Get-HistoricalRuns -Root $emptyRunsRoot
    Check 'O1 nonexistent root -> empty array (Count 0)' (@($runsEmpty).Count -eq 0)

    # ---- Get-HistoricalRuns: root EXISTS but has no qualifying runs ----
    # Guards the unary-comma empty-wrapper trap: `,([array]$x)` on an empty
    # array wraps it as a 1-element array containing an empty array.
    $noQualifyRoot = New-TempDir
    $runNoQ = Join-Path $noQualifyRoot 'go-clean'
    New-Item -ItemType Directory -Force -Path $runNoQ | Out-Null
    @{ goal = 'G'; tasks = @() } | ConvertTo-Json | Set-Content (Join-Path $runNoQ 'plan.json')
    @{ verdict = 'accept' } | ConvertTo-Json | Set-Content (Join-Path $runNoQ 'acceptance.json')
    $runsNoQ = Get-HistoricalRuns -Root $noQualifyRoot
    Check 'O2 root exists, no qualifying runs -> Count is 0, not 1' (@($runsNoQ).Count -eq 0)

    # ---- Get-HistoricalRuns: populated ----
    $popRoot = New-TempDir
    $run1 = Join-Path $popRoot 'go-1'
    New-Item -ItemType Directory -Force -Path $run1 | Out-Null
    @{ goal = 'G1'; tasks = @() } | ConvertTo-Json | Set-Content (Join-Path $run1 'plan.json')
    @{ verdict = 'reject'; reason = 'R1'; counts = @{ critical = 1 }; polish_brief = 'P1' } | ConvertTo-Json | Set-Content (Join-Path $run1 'acceptance.json')
    $run2 = Join-Path $popRoot 'go-2'
    New-Item -ItemType Directory -Force -Path $run2 | Out-Null
    @{ goal = 'G2'; tasks = @() } | ConvertTo-Json | Set-Content (Join-Path $run2 'plan.json')
    @{ verdict = 'accept' } | ConvertTo-Json | Set-Content (Join-Path $run2 'acceptance.json')
    $runsPop = Get-HistoricalRuns -Root $popRoot
    Check 'O3 populated root returns only reject/polish runs' (@($runsPop).Count -eq 1)
    Check 'O4 returned run has the right id' ($runsPop[0].run_id -eq 'go-1')
    Check 'O5 returned run carries the verdict' ($runsPop[0].verdict -eq 'reject')

    # ---- Build-ReflectionPrompt ----
    $runsForPrompt = @(
        @{ run_id = 'go-1'; goal = 'G'; plan_tasks = '[]'; verdict = 'reject'; reason = 'R'; findings = '{}'; polish_brief = 'P' }
    )
    $rp = Build-ReflectionPrompt -HistoricalRuns $runsForPrompt -CurrentPrompt 'ORIGINAL_PROMPT_TEMPLATE'
    Check 'O6 reflection prompt contains the current prompt' ($rp -match 'ORIGINAL_PROMPT_TEMPLATE')
    Check 'O7 reflection prompt contains the run history' ($rp -match '--- RUN: go-1 ---')
    Check 'O8 reflection prompt instructs a <new_prompt> block' ($rp -match '<new_prompt>')

    # ---- Invoke-PromptOptimizer: stubbed dispatcher, hermetic prompt + runs ----
    $liveDir = New-TempDir
    $livePromptPath = Join-Path $liveDir 'conductor-planner.txt'
    $liveOriginal = "TEMPLATE {{schema}} {{evi}} {{Goal}}"
    Set-Content -LiteralPath $livePromptPath -Value $liveOriginal -Encoding utf8NoBOM

    # Point BATON_HOME at a fake root with one polish-verdict run, so
    # Get-HistoricalRuns (called internally with its default Root) finds work.
    $fakeBatonHome = New-TempDir
    $fakeRunsRoot = Join-Path $fakeBatonHome 'runs'
    New-Item -ItemType Directory -Force -Path $fakeRunsRoot | Out-Null
    $fakeRun1 = Join-Path $fakeRunsRoot 'go-1'
    New-Item -ItemType Directory -Force -Path $fakeRun1 | Out-Null
    @{ goal = 'G1'; tasks = @() } | ConvertTo-Json | Set-Content (Join-Path $fakeRun1 'plan.json')
    @{ verdict = 'polish'; reason = 'R1'; counts = @{ important = 1 }; polish_brief = 'P1' } | ConvertTo-Json | Set-Content (Join-Path $fakeRun1 'acceptance.json')
    $env:BATON_HOME = $fakeBatonHome

    # Case 1: valid mutation with placeholders, no -Apply -> candidate written, live untouched.
    $validMutation = "<new_prompt>MUTATED {{schema}} {{evi}} {{Goal}}</new_prompt>"
    $dispValid = { param($p) @{ stdout = $validMutation; exit_code = 0 } }
    $r1 = Invoke-PromptOptimizer -PromptPath $livePromptPath -Dispatcher $dispValid
    Check 'O9 valid mutation -> success true' ($r1.success -eq $true)
    Check 'O10 valid mutation, no -Apply -> applied false' ($r1.applied -eq $false)
    $expectedCandidate = Join-Path $liveDir 'conductor-planner.candidate.txt'
    Check 'O11 candidate path reported' ($r1.candidate_path -eq $expectedCandidate)
    Check 'O12 candidate file written' (Test-Path $expectedCandidate)
    Check 'O13 candidate content is the mutation' ((Get-Content -Raw $expectedCandidate).Trim() -eq 'MUTATED {{schema}} {{evi}} {{Goal}}')
    Check 'O14 live prompt untouched by the default run' ((Get-Content -Raw $livePromptPath).Trim() -eq $liveOriginal)
    Remove-Item -Force $expectedCandidate -ErrorAction SilentlyContinue

    # Case 2: -Apply -> backup created + live overwritten.
    $r2 = Invoke-PromptOptimizer -PromptPath $livePromptPath -Dispatcher $dispValid -Apply
    Check 'O15 -Apply -> success true' ($r2.success -eq $true)
    Check 'O16 -Apply -> applied true' ($r2.applied -eq $true)
    $backups = @(Get-ChildItem -Path $liveDir -Filter 'conductor-planner.txt.bak-*')
    Check 'O17 -Apply creates a timestamped backup' (@($backups).Count -ge 1)
    Check 'O18 backup holds the pre-apply content' ((Get-Content -Raw $backups[0].FullName).Trim() -eq $liveOriginal)
    Check 'O19 live prompt overwritten with the mutation' ((Get-Content -Raw $livePromptPath).Trim() -eq 'MUTATED {{schema}} {{evi}} {{Goal}}')

    # Reset the live prompt for the remaining cases.
    Set-Content -LiteralPath $livePromptPath -Value $liveOriginal -Encoding utf8NoBOM

    # Case 3: mutation missing {{Goal}} -> nothing written, success=false.
    $missingGoalMutation = "<new_prompt>MUTATED {{schema}} {{evi}} NO GOAL PLACEHOLDER</new_prompt>"
    $dispMissing = { param($p) @{ stdout = $missingGoalMutation; exit_code = 0 } }
    $r3 = Invoke-PromptOptimizer -PromptPath $livePromptPath -Dispatcher $dispMissing
    Check 'O20 mutation missing {{Goal}} -> success false' ($r3.success -eq $false)
    Check 'O21 mutation missing {{Goal}} -> nothing written (no candidate)' (-not (Test-Path (Join-Path $liveDir 'conductor-planner.candidate.txt')))
    Check 'O22 mutation missing {{Goal}} -> live untouched' ((Get-Content -Raw $livePromptPath).Trim() -eq $liveOriginal)

    # Case 4: -Apply with a mutation missing {{Goal}} -> also refuses to touch the live prompt.
    $r4 = Invoke-PromptOptimizer -PromptPath $livePromptPath -Dispatcher $dispMissing -Apply
    Check 'O23 -Apply + missing placeholder -> success false' ($r4.success -eq $false)
    Check 'O24 -Apply + missing placeholder -> applied false' ($r4.applied -eq $false)
    Check 'O25 -Apply + missing placeholder -> live untouched' ((Get-Content -Raw $livePromptPath).Trim() -eq $liveOriginal)

    # Case 5: no <new_prompt> tags -> success=false, nothing written.
    $dispNoTags = { param($p) @{ stdout = 'no tags here at all'; exit_code = 0 } }
    $r5 = Invoke-PromptOptimizer -PromptPath $livePromptPath -Dispatcher $dispNoTags
    Check 'O26 no <new_prompt> tags -> success false' ($r5.success -eq $false)
    Check 'O27 no <new_prompt> tags -> nothing written' (-not (Test-Path (Join-Path $liveDir 'conductor-planner.candidate.txt')))

    # Case 6: dispatcher reports a nonzero exit -> success=false.
    $dispFail = { param($p) @{ stdout = ''; exit_code = 1 } }
    $r6 = Invoke-PromptOptimizer -PromptPath $livePromptPath -Dispatcher $dispFail
    Check 'O28 dispatcher failure -> success false' ($r6.success -eq $false)

    # Case 7: no historical runs -> success=false, reason mentions it.
    $env:BATON_HOME = (New-TempDir)   # runs/ subdir absent
    $r7 = Invoke-PromptOptimizer -PromptPath $livePromptPath -Dispatcher $dispValid
    Check 'O29 no historical runs -> success false' ($r7.success -eq $false)
    Check 'O30 no historical runs -> reason explains why' ($r7.reason -match 'no historical runs')

    if ($null -eq $prevBatonHome) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prevBatonHome }

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail CHECK(S) FAILED"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
} catch {
    if ($null -eq $prevBatonHome) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prevBatonHome }
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
