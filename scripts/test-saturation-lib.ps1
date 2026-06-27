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

    # ---- Select-Capability integration (Task 2) ----
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sat-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $toolsFx = Join-Path $tmp 'tools.yaml'
    Set-Content -LiteralPath $toolsFx -Encoding utf8 -Value "tools: []"
    $fleetFx = Join-Path $tmp 'fleet.yaml'
    Set-Content -LiteralPath $fleetFx -Encoding utf8 -Value @'
general_capabilities: [code-gen]
providers:
  - name: local-model
    kind: http
    enabled: true
    cost_tier: local
  - name: gh-budget
    kind: cli
    enabled: true
    cost_tier: free
    budget: 50
    saturate: true
'@
    $ratingsFx = Join-Path $tmp 'ratings.jsonl'
    $journalFx = Join-Path $tmp 'routing.jsonl'
    $usageFx   = Join-Path $tmp 'usage.jsonl'   # empty -> 0 consumed -> full headroom
    function Sel([string]$mode,[string]$usage){
        Select-Capability -Capability 'code-gen' -SelectionMode $mode -ToolsPath $toolsFx -FleetPath $fleetFx -RatingsPath $ratingsFx -JournalPath $journalFx -UsagePath $usage
    }

    # empty usage journal: gh-budget has full headroom -> boosted above local
    $econ = Sel 'economy' $usageFx
    Check 'S18 saturator ranks first (below local)' ($econ[0].name -eq 'gh-budget')
    Check 'S19 boosted candidate tagged saturate' ($econ[0].saturate -eq $true -and $null -ne $econ[0].sat_util)
    Check 'S20 boosted why explains saturation' ($econ[0].why -match 'saturate:')
    Check 'S21 local still present, not boosted' (($econ | Where-Object { $_.name -eq 'local-model' }).saturate -ne $true)

    # champion mode: no saturation -> local-vs-free ranked by quality/tier, gh not floored
    $champ = Sel 'champion' $usageFx
    Check 'S22 champion mode: saturator NOT floored' (($champ | Where-Object { $_.name -eq 'gh-budget' }).saturate -ne $true)

    # at/above target: consume the whole budget -> no boost
    1..50 | ForEach-Object { Add-Content -LiteralPath $usageFx -Encoding utf8 -Value ('{{"ts":"2026-06-21T0{0}:00:00Z","event":"tick","worker":"gh-budget","count":1,"unit":"requests"}}' -f ($_ % 10)) }
    $full = Sel 'economy' $usageFx
    Check 'S23 fully-consumed budget -> not boosted' (($full | Where-Object { $_.name -eq 'gh-budget' }).saturate -ne $true)
    Check 'S24 fully-consumed -> local ranks first' ($full[0].name -eq 'local-model')

    # conserve mode suppresses the boost (fresh empty usage journal + conserve event)
    $usageC = Join-Path $tmp 'usage-conserve.jsonl'
    Add-Content -LiteralPath $usageC -Encoding utf8 -Value '{"ts":"2026-06-21T00:00:00Z","event":"conserve","worker":"*","on":true}'
    $cons = Sel 'economy' $usageC
    Check 'S25 conserve suppresses saturation boost' (($cons | Where-Object { $_.name -eq 'gh-budget' }).saturate -ne $true)

    # exhausted worker is excluded by route-around, never boosted
    $usageX = Join-Path $tmp 'usage-exhausted.jsonl'
    Add-Content -LiteralPath $usageX -Encoding utf8 -Value '{"ts":"2026-06-21T00:00:00Z","event":"lockout","worker":"gh-budget","reason":"manual"}'
    $exh = Sel 'economy' $usageX
    Check 'S26 exhausted saturator excluded (route-around wins)' ($null -eq ($exh | Where-Object { $_.name -eq 'gh-budget' }))

    # non-opted-in fleet ranks exactly as today: local (tier 0) before free (tier 1)
    $fleetPlain = Join-Path $tmp 'fleet-plain.yaml'
    Set-Content -LiteralPath $fleetPlain -Encoding utf8 -Value @'
general_capabilities: [code-gen]
providers:
  - name: local-model
    kind: http
    enabled: true
    cost_tier: local
  - name: free-model
    kind: cli
    enabled: true
    cost_tier: free
'@
    $plain = Select-Capability -Capability 'code-gen' -SelectionMode 'economy' -ToolsPath $toolsFx -FleetPath $fleetPlain -RatingsPath $ratingsFx -JournalPath $journalFx -UsagePath $usageFx
    Check 'S27 no opt-in: local before free (unchanged economy order)' ($plain[0].name -eq 'local-model')

    # two saturators order by utilization ascending (most headroom first)
    $fleet2 = Join-Path $tmp 'fleet-two.yaml'
    Set-Content -LiteralPath $fleet2 -Encoding utf8 -Value @'
general_capabilities: [code-gen]
providers:
  - name: gh-a
    kind: cli
    enabled: true
    cost_tier: free
    budget: 100
    saturate: true
  - name: gh-b
    kind: cli
    enabled: true
    cost_tier: free
    budget: 100
    saturate: true
'@
    $usage2 = Join-Path $tmp 'usage-two.jsonl'
    1..40 | ForEach-Object { Add-Content -LiteralPath $usage2 -Encoding utf8 -Value '{"ts":"2026-06-21T00:00:00Z","event":"tick","worker":"gh-a","count":1,"unit":"requests"}' }
    1..10 | ForEach-Object { Add-Content -LiteralPath $usage2 -Encoding utf8 -Value '{"ts":"2026-06-21T00:00:00Z","event":"tick","worker":"gh-b","count":1,"unit":"requests"}' }
    $two = Select-Capability -Capability 'code-gen' -SelectionMode 'economy' -ToolsPath $toolsFx -FleetPath $fleet2 -RatingsPath $ratingsFx -JournalPath $journalFx -UsagePath $usage2
    Check 'S28 lower-utilization saturator ranks first' ($two[0].name -eq 'gh-b')

    # d-sat-2 hardening: a non-canonical YAML-false token (no/off) must NOT opt in.
    $fleetNo = Join-Path $tmp 'fleet-no.yaml'
    Set-Content -LiteralPath $fleetNo -Encoding utf8 -Value @'
general_capabilities: [code-gen]
providers:
  - name: local-model
    kind: http
    enabled: true
    cost_tier: local
  - name: gh-no
    kind: cli
    enabled: true
    cost_tier: free
    budget: 50
    saturate: no
'@
    $noSat = Select-Capability -Capability 'code-gen' -SelectionMode 'economy' -ToolsPath $toolsFx -FleetPath $fleetNo -RatingsPath $ratingsFx -JournalPath $journalFx -UsagePath $usageFx
    Check 'S29 saturate: no (non-canonical false) does NOT opt in' ((($noSat | Where-Object { $_.name -eq 'gh-no' }).saturate -ne $true) -and ($noSat[0].name -eq 'local-model'))

    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

    # ---- Get-LearnedTierRank (Task 3: saturation-floored effective rank) ----
    Check 'L1 saturating returns -1 ignoring Adjust' ((Get-LearnedTierRank -CostTier 'paid' -Saturating $true -Adjust -5) -eq -1)
    Check 'L2 non-saturating local +0.5 -> 0.5' ((Get-LearnedTierRank -CostTier 'local' -Adjust 0.5) -eq 0.5)
    Check 'L3 floored at -1 for large negative Adjust' ((Get-LearnedTierRank -CostTier 'local' -Adjust -9) -eq -1)
    Check 'L4 Adjust 0 equals Get-EffectiveTierRank' ((Get-LearnedTierRank -CostTier 'free' -Adjust 0) -eq (Get-EffectiveTierRank 'free' $false))

    Write-Host ""
    if ($script:fail -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fail) FAILED"; exit 1 }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"; exit 1
}
