#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/effective-cost-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

function Approx($a,$b){ [math]::Abs([double]$a - [double]$b) -lt 0.0005 }

try {
    # ---- Get-QualityScalar: bands ----
    $qAccept = Get-QualityScalar -Verdict 'accept' -Counts @{ critical=0; important=0; minor=0 }
    Check 'E1 clean accept -> top of band (1.0)' (Approx $qAccept 1.0)
    $qPolish = Get-QualityScalar -Verdict 'polish' -Counts @{ critical=0; important=0; minor=0 }
    Check 'E2 clean polish -> top of polish band (0.7)' (Approx $qPolish 0.7)
    $qReject = Get-QualityScalar -Verdict 'reject' -Counts @{ critical=1; important=0; minor=0 }
    Check 'E3 reject in (0,0.3] and floored > 0' (($qReject -gt 0) -and ($qReject -le 0.3))

    # ---- Get-QualityScalar: monotonic within band, never crosses boundary ----
    $qAcceptMinor = Get-QualityScalar -Verdict 'accept' -Counts @{ critical=0; important=0; minor=3 }
    Check 'E4 minors lower the accept score' ($qAcceptMinor -lt $qAccept)
    Check 'E5 refined accept stays in band (>=0.7)' ($qAcceptMinor -ge 0.7)
    $qAcceptManyMinor = Get-QualityScalar -Verdict 'accept' -Counts @{ critical=0; important=0; minor=999 }
    Check 'E6 saturated penalty clamps at band floor (0.7)' (Approx $qAcceptManyMinor 0.7)

    # ---- Get-QualityScalar: floor + unknown verdict + null counts ----
    $qWorst = Get-QualityScalar -Verdict 'reject' -Counts @{ critical=999; important=0; minor=0 }
    Check 'E7 reject penalty never goes below global floor 0.05' (Approx $qWorst 0.05)
    $qUnknown = Get-QualityScalar -Verdict 'banana' -Counts @{}
    Check 'E8 unknown verdict -> reject band (<=0.3)' ($qUnknown -le 0.3 -and $qUnknown -gt 0)
    $qNullCounts = Get-QualityScalar -Verdict 'accept' -Counts $null
    Check 'E9 null counts -> clean (1.0)' (Approx $qNullCounts 1.0)

    # ---- Get-RunCost ----
    $tasks = @(
        @{ id='t1'; worker='haiku';  cost=2.0 }
        @{ id='t2'; worker='sonnet'; cost=1.0 }
    )
    $rc = Get-RunCost -Tasks $tasks
    Check 'E10 estimate basis sums per-task cost' (Approx $rc.cost 3.0)
    Check 'E11 default basis = estimate' ($rc.basis -eq 'estimate')
    Check 'E12 default attempts = 1' ($rc.attempts -eq 1)
    $rcMeasured = Get-RunCost -Tasks $tasks -CostResolver { param($t) 10.0 }
    Check 'E13 CostResolver overrides cost' (Approx $rcMeasured.cost 20.0)
    Check 'E14 CostResolver flips basis to measured' ($rcMeasured.basis -eq 'measured')
    $rcEmpty = Get-RunCost -Tasks @()
    Check 'E15 empty tasks -> cost 0' (Approx $rcEmpty.cost 0.0)

    # ---- Get-EffectiveCost ----
    Check 'E16 cost / quality' (Approx (Get-EffectiveCost -Cost 3.0 -Quality 0.5) 6.0)
    Check 'E17 quality <= 0 guard -> +Inf' ((Get-EffectiveCost -Cost 3.0 -Quality 0.0) -eq [double]::PositiveInfinity)

    # ---- Get-WorkerBreakdown ----
    $bd = Get-WorkerBreakdown -Tasks $tasks
    Check 'E18 one entry per worker' (@($bd).Count -eq 2)
    $sumShare = (@($bd) | Measure-Object -Property share -Sum).Sum
    Check 'E19 shares sum to 1.0' (Approx $sumShare 1.0)
    $haiku = @($bd | Where-Object { $_.worker -eq 'haiku' })[0]
    Check 'E20 share is cost-weighted (haiku 2/3)' (Approx $haiku.share 0.6667)
    $single = Get-WorkerBreakdown -Tasks @(@{ id='t1'; worker='solo'; cost=5.0 })
    Check 'E21 single producer -> one worker at 1.0' (@($single).Count -eq 1 -and (Approx $single[0].share 1.0))
    $zeroCost = Get-WorkerBreakdown -Tasks @(@{id='a';worker='x';cost=0.0}; @{id='b';worker='y';cost=0.0})
    Check 'E22 zero total cost -> count-share fallback (0.5/0.5)' (Approx (@($zeroCost | Where-Object {$_.worker -eq 'x'})[0]).share 0.5)
    $noWorker = Get-WorkerBreakdown -Tasks @(@{ id='t1'; worker=''; cost=2.0 })
    Check 'E23 tasks without a worker are excluded' (@($noWorker).Count -eq 0)
    $bdEmpty = Get-WorkerBreakdown -Tasks @()
    Check 'E24 empty tasks -> empty array' (@($bdEmpty).Count -eq 0)

    # ---- New-EffectiveCostRecord ----
    $rec = New-EffectiveCostRecord -RunId 'go-x' -Verdict 'polish' -Quality 0.52 -Cost 3.0 -CostBasis 'estimate' -Attempts 1 -EffectiveCost 5.77 -Workers $bd
    Check 'E25 record carries run_id' ($rec.run_id -eq 'go-x')
    Check 'E26 record carries effective_cost' (Approx $rec.effective_cost 5.77)
    Check 'E27 single_producer false for 2 workers' ($rec.single_producer -eq $false)
    $recSolo = New-EffectiveCostRecord -RunId 'go-y' -Verdict 'accept' -Quality 1.0 -Cost 1.0 -EffectiveCost 1.0 -Workers $single
    Check 'E28 single_producer true for 1 worker' ($recSolo.single_producer -eq $true)
    $recJson = $rec | ConvertTo-Json -Depth 8
    Check 'E29 record round-trips through JSON' (($recJson | ConvertFrom-Json).run_id -eq 'go-x')

    # ---- Format-EffectiveCostSection ----
    $sec = Format-EffectiveCostSection -Record $rec
    Check 'E30 section starts with the heading' ($sec -match '(?m)^## Effective cost')
    Check 'E31 section shows the effective cost number' ($sec -match '5\.77')
    Check 'E32 section names the basis honestly' ($sec -match 'estimate')
    Check 'E33 section shows per-worker share' ($sec -match 'haiku')
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green; exit 0
}
