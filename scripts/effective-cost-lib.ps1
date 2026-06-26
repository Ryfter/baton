#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Quality-adjusted effective cost (slice 1). Pure layer: realized cost / realized
  quality per run. effective_cost = cost / quality; lower is better.
.DESCRIPTION
  Recommendation/legibility only — no dispatch, no routing change. All inputs are
  parameters (no I/O). Wired into conductor-lib.ps1 Complete-Run.
  See docs/superpowers/specs/2026-06-22-effective-cost-metric-design.md.
#>

function Get-QualityScalar {
    <# Verdict + finding counts -> (0,1] scalar. Banded by verdict, refined within
       the band by counts, floored > 0. Monotonic with the verdict. #>
    param(
        [Parameter(Mandatory)][string]$Verdict,
        $Counts = @{},
        [hashtable]$Weights = @{ critical = 0.5; important = 0.2; minor = 0.05 },
        [hashtable]$Bands = @{ accept = @(0.7, 1.0); polish = @(0.3, 0.7); reject = @(0.0, 0.3) },
        [double]$Floor = 0.05
    )
    if ($null -eq $Counts) { $Counts = @{} }
    $v = ([string]$Verdict).ToLowerInvariant()
    if (-not $Bands.Contains($v)) { $v = 'reject' }   # unknown verdict -> worst band
    $lo = [double]$Bands[$v][0]
    $hi = [double]$Bands[$v][1]
    if ($v -ne 'accept') { $hi = [math]::Max($lo, $hi - 0.0001) }  # lower bands are half-open at report precision
    $w  = $hi - $lo
    $crit = [int]($Counts['critical']); $imp = [int]($Counts['important']); $min = [int]($Counts['minor'])
    $penalty = ([double]$Weights['critical'] * $crit) + ([double]$Weights['important'] * $imp) + ([double]$Weights['minor'] * $min)
    if ($penalty -lt 0) { $penalty = 0.0 }
    if ($penalty -gt 1) { $penalty = 1.0 }
    $q = $hi - ($penalty * $w)
    if ($q -lt $lo) { $q = $lo }
    if ($q -lt $Floor) { $q = $Floor }
    return [math]::Round($q, 4)
}

function Get-RunCost {
    <# Per-task cost list (@[{id;worker;cost}]) -> @{cost;basis;attempts}.
       v1 basis='estimate' (sum of per-task cost); -CostResolver overrides per task
       and flips basis to 'measured'. #>
    param(
        [object[]]$Tasks = @(),
        [scriptblock]$CostResolver,
        [int]$Attempts = 1
    )
    $sum = 0.0
    $basis = if ($CostResolver) { 'measured' } else { 'estimate' }
    foreach ($t in @($Tasks)) {
        if ($CostResolver) { $sum += [double](& $CostResolver $t) }
        else { $sum += [double]$t.cost }
    }
    return @{ cost = [math]::Round($sum, 4); basis = $basis; attempts = [int]$Attempts }
}

function Get-EffectiveCost {
    <# cost / quality. Quality is floored > 0 upstream; guard <= 0 -> +Inf. #>
    param(
        [Parameter(Mandatory)][double]$Cost,
        [Parameter(Mandatory)][double]$Quality
    )
    if ($Quality -le 0) { return [double]::PositiveInfinity }
    return [math]::Round($Cost / $Quality, 4)
}

function Get-WorkerBreakdown {
    <# Per-task cost list -> @[{worker; share}] summing to 1.0. Share by cost; if the
       total cost is 0, fall back to task-count share. Tasks without a worker are
       excluded. Empty -> @(). #>
    param([object[]]$Tasks = @())
    $arr = @(@($Tasks) | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.worker) })
    if ($arr.Count -eq 0) { return @() }
    $byWorker = [ordered]@{}
    $totalCost = 0.0
    foreach ($t in $arr) {
        $wk = [string]$t.worker
        $cost = [double]$t.cost
        if (-not $byWorker.Contains($wk)) { $byWorker[$wk] = @{ cost = 0.0; count = 0 } }
        $byWorker[$wk].cost  += $cost
        $byWorker[$wk].count += 1
        $totalCost += $cost
    }
    $useCost = ($totalCost -gt 0)
    $totalCount = $arr.Count
    $out = foreach ($wk in $byWorker.Keys) {
        $share = if ($useCost) { $byWorker[$wk].cost / $totalCost } else { $byWorker[$wk].count / $totalCount }
        @{ worker = $wk; share = [math]::Round($share, 4) }
    }
    return ,@($out)   # unary comma: preserve a 1-element result as an array across the return boundary
}

function New-EffectiveCostRecord {
    <# Assemble the per-run outcome record — the join surface slice 2 folds over. #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][double]$Quality,
        [Parameter(Mandatory)][double]$Cost,
        [string]$CostBasis = 'estimate',
        [int]$Attempts = 1,
        [double]$EffectiveCost = 0.0,
        [object[]]$Workers = @()
    )
    return [ordered]@{
        run_id          = $RunId
        verdict         = $Verdict
        quality         = $Quality
        cost            = $Cost
        cost_basis      = $CostBasis
        attempts        = $Attempts
        effective_cost  = $EffectiveCost
        workers         = @($Workers)
        single_producer = (@($Workers).Count -eq 1)
    }
}

function Format-EffectiveCostSection {
    <# The '## Effective cost' report block from a record (ordered dict/hashtable). #>
    param([Parameter(Mandatory)]$Record)
    $eff = if ([double]$Record.effective_cost -eq [double]::PositiveInfinity) { '∞' } else { '{0:0.00}' -f [double]$Record.effective_cost }
    $cost = '{0:0.00}' -f [double]$Record.cost
    $q = '{0:0.00}' -f [double]$Record.quality
    $basisNote = if ($Record.cost_basis -eq 'measured') { 'cost is metered spend' } else { 'cost is a cost-tier estimate, not metered spend' }
    $shareStr = (@($Record.workers) | ForEach-Object { "$($_.worker) $([math]::Round([double]$_.share * 100))%" }) -join ', '
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Effective cost')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Effective cost **$eff** = cost $cost ($($Record.cost_basis)) / quality $q ($($Record.verdict)).")
    [void]$sb.AppendLine("Attempts: $($Record.attempts). Basis: $($Record.cost_basis) — $basisNote.")
    if ($shareStr) { [void]$sb.AppendLine("Per-worker share: $shareStr.") }
    return $sb.ToString().TrimEnd()
}

function Get-WorkerEffectiveCost {
    <# Fold per-run effective-cost records into a per-worker learned leaderboard.
       A mixed run contributes by worker share; a single-producer run contributes
       full attribution and raises confidence more strongly. Advisory only. #>
    param(
        [object[]]$Records = @(),
        [int]$MinConfidenceRuns = 5
    )
    if ($MinConfidenceRuns -lt 1) { $MinConfidenceRuns = 1 }

    $byWorker = [ordered]@{}
    foreach ($rec in @($Records)) {
        if ($null -eq $rec) { continue }
        $workers = @($rec.workers)
        if ($workers.Count -eq 0) { continue }

        $eff = [double]$rec.effective_cost
        if ([double]::IsNaN($eff) -or [double]::IsInfinity($eff)) { continue }

        $isSingle = [bool]$rec.single_producer
        foreach ($w in $workers) {
            $name = [string]$w.worker
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $share = [double]$w.share
            if ($share -le 0) { continue }
            if ($share -gt 1) { $share = 1.0 }

            if (-not $byWorker.Contains($name)) {
                $byWorker[$name] = @{
                    weighted_cost = 0.0
                    weight = 0.0
                    run_ids = @{}
                    single_run_ids = @{}
                }
            }

            $byWorker[$name].weighted_cost += ($eff * $share)
            $byWorker[$name].weight += $share

            $runId = [string]$rec.run_id
            if ([string]::IsNullOrWhiteSpace($runId)) { $runId = "__record_$($byWorker[$name].run_ids.Count)" }
            $byWorker[$name].run_ids[$runId] = $true
            if ($isSingle -and $workers.Count -eq 1) {
                $byWorker[$name].single_run_ids[$runId] = $true
            }
        }
    }

    if ($byWorker.Count -eq 0) { return @() }

    $rows = foreach ($name in $byWorker.Keys) {
        $state = $byWorker[$name]
        if ([double]$state.weight -le 0) { continue }

        $nRuns = [int]$state.run_ids.Count
        $singleRuns = [int]$state.single_run_ids.Count
        $runConfidence = [math]::Min(1.0, [double]$nRuns / [double]$MinConfidenceRuns)
        $singleFraction = if ($nRuns -gt 0) { [double]$singleRuns / [double]$nRuns } else { 0.0 }
        $confidence = $runConfidence * (0.5 + (0.5 * $singleFraction))

        [ordered]@{
            worker               = $name
            n_runs               = $nRuns
            eff_cost_mean        = [math]::Round(([double]$state.weighted_cost / [double]$state.weight), 4)
            single_producer_runs = $singleRuns
            confidence           = [math]::Round($confidence, 4)
        }
    }

    $sorted = @($rows) | Sort-Object @{ Expression = 'eff_cost_mean'; Ascending = $true }, @{ Expression = 'confidence'; Descending = $true }, @{ Expression = 'worker'; Ascending = $true }
    return ,@($sorted)
}

function Format-EffectiveCostLeaderboard {
    <# Render a Get-WorkerEffectiveCost leaderboard as a plain-text report block.
       Rows arrive already cheapest-first (do not re-sort). Low-confidence rows
       (< 0.50) are flagged 'tentative'. Empty rows -> one-line guidance. #>
    param(
        [object[]]$Rows = @(),
        [int]$RunCount = 0,
        [double]$TentativeBelow = 0.5
    )
    $rows = @($Rows)
    if ($rows.Count -eq 0) {
        return "No effective-cost records found. Run /baton:go with a gate (--gate-artifact or --gate-diff) to produce them."
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Effective-cost leaderboard')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Across $RunCount run(s). Cheapest quality-adjusted worker first (lower eff_cost = better).")
    [void]$sb.AppendLine('')
    $wCol = [math]::Max(6, (@($rows | ForEach-Object { ([string]$_.worker).Length }) | Measure-Object -Maximum).Maximum)
    [void]$sb.AppendLine(("{0}  {1}  {2}  {3}" -f 'worker'.PadRight($wCol), 'runs'.PadLeft(4), 'eff_cost'.PadLeft(10), 'confidence'))
    foreach ($r in $rows) {
        $tent = if ([double]$r.confidence -lt $TentativeBelow) { '  tentative' } else { '' }
        [void]$sb.AppendLine(("{0}  {1}  {2}  {3}{4}" -f `
            ([string]$r.worker).PadRight($wCol), `
            ([string][int]$r.n_runs).PadLeft(4), `
            ('{0:0.0000}' -f [double]$r.eff_cost_mean).PadLeft(10), `
            ('{0:0.00}' -f [double]$r.confidence), `
            $tent))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Confidence rises with run count and single-producer (clean-attribution) runs; rows marked tentative (confidence < $('{0:0.00}' -f $TentativeBelow)) have too little clean data to trust yet.")
    return $sb.ToString().TrimEnd()
}
