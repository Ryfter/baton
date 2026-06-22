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
    $w  = $hi - $lo
    $crit = [int]($Counts['critical']); $imp = [int]($Counts['important']); $min = [int]($Counts['minor'])
    $penalty = ([double]$Weights['critical'] * $crit) + ([double]$Weights['important'] * $imp) + ([double]$Weights['minor'] * $min)
    if ($penalty -lt 0) { $penalty = 0.0 }
    if ($penalty -gt 1) { $penalty = 1.0 }
    $q = $hi - ($penalty * $w)
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
