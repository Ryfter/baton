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
    Check 'E2 clean polish -> below accept floor (0.6999)' (Approx $qPolish 0.6999)
    $qReject = Get-QualityScalar -Verdict 'reject' -Counts @{ critical=1; important=0; minor=0 }
    Check 'E3 reject in (0,0.3] and floored > 0' (($qReject -gt 0) -and ($qReject -le 0.3))

    # ---- Get-QualityScalar: monotonic within band, never crosses boundary ----
    $qAcceptMinor = Get-QualityScalar -Verdict 'accept' -Counts @{ critical=0; important=0; minor=3 }
    Check 'E4 minors lower the accept score' ($qAcceptMinor -lt $qAccept)
    Check 'E5 refined accept stays in band (>=0.7)' ($qAcceptMinor -ge 0.7)
    $qAcceptManyMinor = Get-QualityScalar -Verdict 'accept' -Counts @{ critical=0; important=0; minor=999 }
    Check 'E6 saturated penalty clamps at band floor (0.7)' (Approx $qAcceptManyMinor 0.7)
    Check 'E6b worst accept stays above clean polish' ($qAcceptManyMinor -gt $qPolish)
    $qPolishManyMinor = Get-QualityScalar -Verdict 'polish' -Counts @{ critical=0; important=0; minor=999 }
    Check 'E6c saturated polish clamps at band floor (0.3)' (Approx $qPolishManyMinor 0.3)

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

    # ---- Get-WorkerEffectiveCost ----
    $leaderRecords = @(
        [ordered]@{
            run_id = 'r1'; effective_cost = 10.0; single_producer = $true
            workers = @([ordered]@{ worker = 'a'; share = 1.0 })
        }
        [ordered]@{
            run_id = 'r2'; effective_cost = 30.0; single_producer = $false
            workers = @(
                [ordered]@{ worker = 'a'; share = 0.25 }
                [ordered]@{ worker = 'b'; share = 0.75 }
            )
        }
        [ordered]@{
            run_id = 'r3'; effective_cost = 20.0; single_producer = $true
            workers = @([ordered]@{ worker = 'b'; share = 1.0 })
        }
        [ordered]@{
            run_id = 'r4'; effective_cost = 40.0; single_producer = $false
            workers = @(
                [ordered]@{ worker = 'c'; share = 0.5 }
                [ordered]@{ worker = 'd'; share = 0.5 }
            )
        }
        [ordered]@{
            run_id = 'r5'; effective_cost = 20.0; single_producer = $false
            workers = @(
                [ordered]@{ worker = 'c'; share = 0.5 }
                [ordered]@{ worker = 'd'; share = 0.5 }
            )
        }
        [ordered]@{
            run_id = 'r6'; effective_cost = 99.0; single_producer = $false
            workers = @()
        }
    )
    $leader = Get-WorkerEffectiveCost -Records $leaderRecords -MinConfidenceRuns 4
    Check 'E34 leaderboard has one row per attributed worker' (@($leader).Count -eq 4)
    Check 'E35 leaderboard sorts cheapest effective cost first' ($leader[0].worker -eq 'a')
    $rowA = @($leader | Where-Object { $_.worker -eq 'a' })[0]
    Check 'E36 mixed run contributes by share-weighted mean' (Approx $rowA.eff_cost_mean 14.0)
    Check 'E37 n_runs counts distinct attributed runs' ($rowA.n_runs -eq 2)
    Check 'E38 single_producer_runs counts clean attribution' ($rowA.single_producer_runs -eq 1)
    $rowC = @($leader | Where-Object { $_.worker -eq 'c' })[0]
    Check 'E39 mixed-only rows have lower confidence than same-count rows with a solo run' ($rowC.confidence -lt $rowA.confidence)
    $emptyLeader = Get-WorkerEffectiveCost -Records @()
    Check 'E40 empty records -> empty leaderboard' (@($emptyLeader).Count -eq 0)

    # ---- Format-EffectiveCostLeaderboard ----
    $board = Format-EffectiveCostLeaderboard -Rows $leader -RunCount 5
    Check 'E41 board starts with the heading' ($board -match '(?m)^## Effective-cost leaderboard')
    Check 'E42 board states the run count' ($board -match '\b5\b')
    Check 'E43 board lists each worker' (($board -match '(?m)^a\b') -and ($board -match '(?m)^b\b'))
    Check 'E44 board shows the cheapest worker before the dearest' ($board.IndexOf("`na ") -lt $board.IndexOf("`nd "))
    Check 'E45 low-confidence rows are flagged tentative' ($board -match 'tentative')
    $emptyBoard = Format-EffectiveCostLeaderboard -Rows @() -RunCount 0
    Check 'E46 empty rows -> guidance, no table' (($emptyBoard -match 'No effective-cost') -and ($emptyBoard -notmatch '(?m)^## Effective-cost leaderboard'))

    # Read-EffectiveCostRecords — shared reader
    $tmpR = Join-Path ([System.IO.Path]::GetTempPath()) "ec-rdr-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path (Join-Path $tmpR 'go-1') | Out-Null
    '{ "run_id":"go-1","effective_cost":0.5,"workers":[{"worker":"a","share":1.0}],"single_producer":true }' |
        Set-Content -LiteralPath (Join-Path $tmpR 'go-1/effective-cost.json') -Encoding utf8NoBOM
    New-Item -ItemType Directory -Force -Path (Join-Path $tmpR 'go-bad') | Out-Null
    '{ not json' | Set-Content -LiteralPath (Join-Path $tmpR 'go-bad/effective-cost.json') -Encoding utf8NoBOM
    $recs = Read-EffectiveCostRecords -RunsRoot $tmpR
    Check 'E_rdr1 reads good record, skips malformed' (@($recs).Count -eq 1 -and [string]$recs[0].run_id -eq 'go-1')
    Check 'E_rdr2 missing root -> empty array' (@(Read-EffectiveCostRecords -RunsRoot (Join-Path $tmpR 'nope')).Count -eq 0)
    Remove-Item -Recurse -Force $tmpR -ErrorAction SilentlyContinue

    $tmpF = Join-Path ([System.IO.Path]::GetTempPath()) "ec-cfg-$([System.IO.Path]::GetRandomFileName()).yaml"
    'learned_routing: true' | Set-Content -LiteralPath $tmpF -Encoding utf8NoBOM
    Check 'E_cfg1 true enables'  (Get-LearnedRoutingEnabled -FleetPath $tmpF)
    'learned_routing: no' | Set-Content -LiteralPath $tmpF -Encoding utf8NoBOM
    Check 'E_cfg2 non-canonical false token -> disabled' (-not (Get-LearnedRoutingEnabled -FleetPath $tmpF))
    'fleet: []' | Set-Content -LiteralPath $tmpF -Encoding utf8NoBOM
    Check 'E_cfg3 absent key -> disabled' (-not (Get-LearnedRoutingEnabled -FleetPath $tmpF))
    Check 'E_cfg4 missing file -> disabled' (-not (Get-LearnedRoutingEnabled -FleetPath (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such.yaml')))
    Remove-Item -Force $tmpF -ErrorAction SilentlyContinue

    # Get-LearnedCostAdjustment — bias math
    # Board: 'cheap' is much cheaper than median, 'dear' much dearer, both fully confident;
    # 'tent' is dear but below the confidence bar (must be inert AND not anchor the median).
    $board = @(
        [ordered]@{ worker='cheap'; n_runs=10; eff_cost_mean=1.0;  single_producer_runs=10; confidence=1.0 },
        [ordered]@{ worker='mid';   n_runs=10; eff_cost_mean=2.0;  single_producer_runs=10; confidence=1.0 },
        [ordered]@{ worker='dear';  n_runs=10; eff_cost_mean=8.0;  single_producer_runs=10; confidence=1.0 },
        [ordered]@{ worker='tent';  n_runs=1;  eff_cost_mean=99.0; single_producer_runs=0;  confidence=0.10 }
    )
    $cheap = Get-LearnedCostAdjustment -Worker 'cheap' -Board $board
    $dear  = Get-LearnedCostAdjustment -Worker 'dear'  -Board $board
    Check 'E_adj1 cheaper-than-median -> negative adjust' ($cheap.adjust -lt 0)
    Check 'E_adj2 dearer-than-median -> positive adjust'  ($dear.adjust  -gt 0)
    Check 'E_adj3 bounded by MaxShift' ([math]::Abs($dear.adjust) -le 1.0 -and [math]::Abs($cheap.adjust) -le 1.0)
    Check 'E_adj4 below-confidence worker is inert' ((Get-LearnedCostAdjustment -Worker 'tent' -Board $board).adjust -eq 0)
    Check 'E_adj5 absent worker is inert' ((Get-LearnedCostAdjustment -Worker 'ghost' -Board $board).adjust -eq 0)
    Check 'E_adj6 reason set only when adjust != 0' ($null -ne $dear.reason -and $null -eq (Get-LearnedCostAdjustment -Worker 'ghost' -Board $board).reason)
    Check 'E_adj7 empty board inert' ((Get-LearnedCostAdjustment -Worker 'cheap' -Board @()).adjust -eq 0)
    # Confidence-weighting: same ratio, lower confidence (but above bar) -> smaller magnitude.
    $board2 = @(
        [ordered]@{ worker='lo'; n_runs=3; eff_cost_mean=8.0; single_producer_runs=0; confidence=0.55 },
        [ordered]@{ worker='hi'; n_runs=9; eff_cost_mean=8.0; single_producer_runs=9; confidence=1.0  },
        [ordered]@{ worker='anchor'; n_runs=9; eff_cost_mean=2.0; single_producer_runs=9; confidence=1.0 }
    )
    $lo = Get-LearnedCostAdjustment -Worker 'lo' -Board $board2
    $hi = Get-LearnedCostAdjustment -Worker 'hi' -Board $board2
    Check 'E_adj8 confidence-weighted (just-cleared moves less)' ([math]::Abs($lo.adjust) -lt [math]::Abs($hi.adjust))
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green; exit 0
}
