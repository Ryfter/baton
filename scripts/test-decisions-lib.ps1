#!/usr/bin/env pwsh
# Tests for scripts/decisions-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'decisions-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$tmpKb = Join-Path $env:TEMP "dec-kb-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmpKb | Out-Null

# --- Get-NextDecisionId: empty dir → d001 ---
$decDir = Join-Path $tmpKb 'projects/testproj/decisions'
New-Item -ItemType Directory -Force -Path $decDir | Out-Null
$id1 = Get-NextDecisionId -ProjectDecisionsDir $decDir
Assert "empty dir returns d001" ($id1 -eq 'd001')

# Seed an existing record and verify increment
Set-Content -Path (Join-Path $decDir 'd001-first.md') -Value '' -Encoding utf8NoBOM
Set-Content -Path (Join-Path $decDir 'd003-skipped.md') -Value '' -Encoding utf8NoBOM
$id2 = Get-NextDecisionId -ProjectDecisionsDir $decDir
Assert "next after d001+d003 is d004" ($id2 -eq 'd004')

# --- Add-DecisionRecord ---
$rec = Add-DecisionRecord `
    -Title "Use Start-Job for ensemble concurrency" `
    -Chosen "Process-isolated Start-Job per provider." `
    -Alternatives @("Claude-native subagents — heavier dispatch", "ForEach-Object -Parallel — runspace env collision") `
    -Rationale "Env isolation + crash isolation; lean dispatch." `
    -Confidence 'med' `
    -RevisitIf "Ensemble grows beyond 5 providers" `
    -Project 'testproj' `
    -Job 'j-test-123' `
    -Phase 'design' `
    -KbRoot $tmpKb

Assert "Add-DecisionRecord returns an id" ($rec.id -match '^d\d{3}$')
Assert "record file exists" (Test-Path $rec.path)
$content = Get-Content $rec.path -Raw
Assert "front-matter id matches" ($content -match "(?m)^id:\s+$($rec.id)")
Assert "front-matter has project" ($content -match "(?m)^project:\s+testproj")
Assert "front-matter has job" ($content -match "(?m)^job:\s+j-test-123")
Assert "front-matter has phase" ($content -match "(?m)^phase:\s+design")
Assert "front-matter has confidence" ($content -match "(?m)^confidence:\s+med")
Assert "front-matter has revisit-if" ($content -match 'revisit-if:\s+"Ensemble grows beyond 5 providers"')
Assert "body has title" ($content -match '(?m)^# Use Start-Job for ensemble concurrency')
Assert "body has Chosen" ($content -match '\*\*Chosen:\*\* Process-isolated Start-Job')
Assert "body has alternatives" ($content -match 'Claude-native subagents')
Assert "body has Rationale" ($content -match '\*\*Rationale:\*\* Env isolation')
Assert "body has empty Feedback section" ($content -match '## Feedback')

# --- Opt-out: global decisions-off file suppresses capture ---
$optOut = Join-Path $tmpKb 'decisions-off'
Set-Content -Path $optOut -Value '' -Encoding utf8NoBOM
$rec2 = Add-DecisionRecord `
    -Title "should be skipped" -Chosen "x" -Alternatives @("y") `
    -Rationale "z" -Confidence 'high' -RevisitIf "never" `
    -Project 'testproj' -KbRoot $tmpKb -OptOutPath $optOut
Assert "global opt-out suppresses capture" ($null -eq $rec2)
Remove-Item $optOut

# --- Opt-out: per-project decisions-off file suppresses capture ---
$projOptOut = Join-Path $tmpKb 'projects/testproj/decisions-off'
Set-Content -Path $projOptOut -Value '' -Encoding utf8NoBOM
$rec3 = Add-DecisionRecord `
    -Title "should also be skipped" -Chosen "x" -Alternatives @("y") `
    -Rationale "z" -Confidence 'high' -RevisitIf "never" `
    -Project 'testproj' -KbRoot $tmpKb
Assert "project opt-out suppresses capture" ($null -eq $rec3)
Remove-Item $projOptOut

Remove-Item $tmpKb -Recurse -Force
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
