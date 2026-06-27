#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Active Saturation Driver (d-wa-5). Pure decision layer that decides whether an
  under-utilized, opt-in, budgeted worker should be rank-boosted so routing spends
  its pre-paid/free allotment first. Wired into Select-Capability (routing-lib.ps1 §3b).
.DESCRIPTION
  Recommendation/ranking only — no dispatch, no filler work.
  See docs/superpowers/specs/2026-06-21-active-saturation-driver-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/usage-lib.ps1"   # ConvertTo-UsageDateTime

function Get-CandidateUtilization {
    <# consumed (ticks since the latest lockout|clear boundary at/under Now, else all)
       + budget + utilization% for a worker. Pure over the supplied rows. #>
    param(
        [object[]]$Rows,
        [Parameter(Mandatory)][string]$Worker,
        [int]$Budget = 0,
        [datetime]$Now = [datetime]::UtcNow
    )
    $nowUtc = $Now.ToUniversalTime()
    $rowsArr = @($Rows)
    $bounds = @($rowsArr | Where-Object {
        $_.worker -eq $Worker -and $_.event -in @('lockout','clear') -and (ConvertTo-UsageDateTime ([string]$_.ts)) -le $nowUtc
    })
    $windowStart = [datetime]::MinValue
    if ($bounds.Count -gt 0) {
        $windowStart = ConvertTo-UsageDateTime ([string](($bounds | Sort-Object { ConvertTo-UsageDateTime ([string]$_.ts) } | Select-Object -Last 1).ts))
    }
    $consumed = 0
    foreach ($t in @($rowsArr | Where-Object { $_.event -eq 'tick' -and $_.worker -eq $Worker })) {
        if ((ConvertTo-UsageDateTime ([string]$t.ts)) -ge $windowStart) { $consumed += [int]$t.count }
    }
    $util = $null
    if ($Budget -gt 0) { $util = [math]::Round(($consumed / $Budget) * 100, 1) }
    return @{ consumed = $consumed; budget = $Budget; utilization = $util }
}

function Get-SaturationDecision {
    <# Pure gate: should this candidate get the saturation boost? All d-sat rules. #>
    param(
        [bool]$Saturate = $false,
        [int]$Budget = 0,
        [int]$Consumed = 0,
        [double]$Target = 99.9,
        [string]$State = 'available',
        [string]$SelectionMode = 'economy',
        [bool]$Conserve = $false
    )
    $util = $null
    if ($Budget -gt 0) { $util = [math]::Round(($Consumed / $Budget) * 100, 1) }
    $apply = $Saturate -and ($Budget -gt 0) -and ($Consumed -lt $Budget) -and
             ($null -ne $util) -and ($util -lt $Target) -and
             ($State -eq 'available') -and ($SelectionMode -eq 'economy') -and (-not $Conserve)
    $reason = $null
    if ($apply) { $reason = "saturate: $util% of $Budget budget — spending pre-paid allotment first" }
    return @{ apply = [bool]$apply; utilization = $util; reason = $reason }
}

function Get-EffectiveTierRank {
    <# Effective cost-tier rank: -1 (below local's 0) when saturating, else the real rank. #>
    param([string]$CostTier, [bool]$Saturating = $false)
    if ($Saturating) { return -1 }
    return (Get-CostTierRank $CostTier)
}

function Get-LearnedTierRank {
    <# Effective tier rank with a learned-cost Adjust folded in. Saturation wins
       (-1); otherwise CostTierRank + Adjust, floored at -1 so learned bias never
       undercuts saturation. Returns a double (fractional ranks order same-tier
       workers by learned cost). #>
    param([string]$CostTier, [bool]$Saturating = $false, [double]$Adjust = 0.0)
    if ($Saturating) { return -1 }
    $r = (Get-CostTierRank $CostTier) + $Adjust
    if ($r -lt -1) { $r = -1 }
    return $r
}
