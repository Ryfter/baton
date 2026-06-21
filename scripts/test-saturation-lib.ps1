#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
# Dot-source routing-lib so Get-EffectiveTierRank can resolve Get-CostTierRank,
# and Task 2's Select-Capability integration checks are in scope.
. "$PSScriptRoot/routing-lib.ps1"
. "$PSScriptRoot/saturation-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

function New-Tick([string]$worker,[string]$ts){ [pscustomobject]@{ ts=$ts; event='tick'; worker=$worker; count=1; unit='requests' } }

try {
    # ---- Get-CandidateUtilization ----
    $rows = @(New-Tick 'gh' '2026-06-21T01:00:00Z'; New-Tick 'gh' '2026-06-21T02:00:00Z'; New-Tick 'other' '2026-06-21T03:00:00Z')
    $u = Get-CandidateUtilization -Rows $rows -Worker 'gh' -Budget 50
    Check 'S1 consumed counts only this worker' ($u.consumed -eq 2)
    Check 'S2 utilization = consumed/budget*100' ($u.utilization -eq 4.0)
    $u0 = Get-CandidateUtilization -Rows $rows -Worker 'gh' -Budget 0
    Check 'S3 budget 0 -> null utilization' ($null -eq $u0.utilization)
    $uEmpty = Get-CandidateUtilization -Rows @() -Worker 'gh' -Budget 50
    Check 'S4 empty rows -> 0 consumed' ($uEmpty.consumed -eq 0 -and $uEmpty.utilization -eq 0.0)
    # consumed counts only ticks since the latest lockout|clear boundary
    $rowsB = @(
        New-Tick 'gh' '2026-06-21T01:00:00Z'
        [pscustomobject]@{ ts='2026-06-21T01:30:00Z'; event='clear'; worker='gh' }
        New-Tick 'gh' '2026-06-21T02:00:00Z'
    )
    $uB = Get-CandidateUtilization -Rows $rowsB -Worker 'gh' -Budget 50 -Now ([datetime]::Parse('2026-06-21T05:00:00Z'))
    Check 'S5 consumed resets at clear boundary' ($uB.consumed -eq 1)

    # ---- Get-SaturationDecision ----
    $dOn = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 5 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S6 below target + opted-in -> apply' ($dOn.apply -and $dOn.utilization -eq 10.0)
    Check 'S7 apply -> reason carries util + budget' ($dOn.reason -match 'saturate:' -and $dOn.reason -match '10' -and $dOn.reason -match '50')
    $dFull = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 50 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S8 consumed>=budget -> no apply' (-not $dFull.apply)
    $dAt = Get-SaturationDecision -Saturate $true -Budget 100 -Consumed 100 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S9 util at/above target -> no apply' (-not $dAt.apply)
    $dOff = Get-SaturationDecision -Saturate $false -Budget 50 -Consumed 5 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S10 not opted-in -> no apply' (-not $dOff.apply)
    $dNoBud = Get-SaturationDecision -Saturate $true -Budget 0 -Consumed 0 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S11 no budget -> no apply' (-not $dNoBud.apply)
    $dCons = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 5 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $true
    Check 'S12 conserve -> no apply' (-not $dCons.apply)
    $dChamp = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 5 -Target 99.9 -State 'available' -SelectionMode 'champion' -Conserve $false
    Check 'S13 champion mode -> no apply' (-not $dChamp.apply)
    $dLim = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 5 -Target 99.9 -State 'limited' -SelectionMode 'economy' -Conserve $false
    Check 'S14 state != available -> no apply' (-not $dLim.apply)

    # ---- Get-EffectiveTierRank ----
    Check 'S15 saturating -> -1' ((Get-EffectiveTierRank 'free' $true) -eq -1)
    Check 'S16 not saturating -> real tier rank' ((Get-EffectiveTierRank 'local' $false) -eq (Get-CostTierRank 'local'))
    Check 'S17 saturating beats local' ((Get-EffectiveTierRank 'free' $true) -lt (Get-EffectiveTierRank 'local' $false))

    Write-Host ""
    if ($script:fail -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fail) FAILED"; exit 1 }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"; exit 1
}
