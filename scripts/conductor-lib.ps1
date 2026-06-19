#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Conductor engine (/baton:go). Parses a model-produced task DAG, walks it under
  two interrupt guards (budget cap + reversible:false), logs event/decision
  ledgers, and renders a report. Pure layer + seamed Invoke-Conductor.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-go.ps1 wraps it for
  /baton:go. routing-lib brings Select-Capability and (via fleet-lib) Invoke-Fleet.
.NOTES
  See docs/superpowers/specs/2026-06-18-conductor-go-mode-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability (+ fleet-lib: Invoke-Fleet)

function New-RunId {
    param([datetime]$Now = (Get-Date))
    return 'go-' + $Now.ToString('yyyy-MM-ddTHH-mm-ss')
}

function Get-JsonBlock {
    <# First '{' to last '}' from a possibly fenced/prose-wrapped reply; '' if none. #>
    param([Parameter(Mandatory)][string]$Raw)
    $open = $Raw.IndexOf('{'); $close = $Raw.LastIndexOf('}')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}

function ConvertTo-PlanObject {
    <# Parse a planner reply into a normalized plan hashtable, or $null when there
       is no valid JSON object or no tasks. Tasks get defaulted fields. #>
    param([Parameter(Mandatory)][string]$RawStdout)
    $block = Get-JsonBlock -Raw $RawStdout
    if (-not $block) { return $null }
    try { $o = $block | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $o.tasks) { return $null }
    $tasks = foreach ($t in @($o.tasks)) {
        [pscustomobject]@{
            id            = [string]$t.id
            desc          = [string]$t.desc
            command       = [string]$t.command
            capability    = [string]$t.capability
            model_pick    = [string]$t.model_pick
            depends_on    = @($t.depends_on | Where-Object { $_ })
            est_cost_tier = if ($t.est_cost_tier) { [string]$t.est_cost_tier } else { 'free' }
            reversible    = if ($null -eq $t.reversible) { $true } else { [bool]$t.reversible }
        }
    }
    if (@($tasks).Count -lt 1) { return $null }
    return @{
        run_id     = [string]$o.run_id
        goal       = [string]$o.goal
        budget_cap = if ($null -eq $o.budget_cap) { $null } else { [double]$o.budget_cap }
        tasks      = @($tasks)
    }
}

function Resolve-TaskOrder {
    <# Stable topological order via Kahn's algorithm. Throws on a dependency cycle
       or a dependency on an unknown id. Ready tasks are emitted in original order. #>
    param([Parameter(Mandatory)][array]$Tasks)
    $byId = @{}; foreach ($t in $Tasks) { if ($t.id) { $byId[$t.id] = $t } }
    $indeg = @{}; foreach ($t in $Tasks) { $indeg[$t.id] = 0 }
    foreach ($t in $Tasks) {
        foreach ($d in @($t.depends_on)) {
            if (-not $byId.ContainsKey($d)) { throw "Task '$($t.id)' depends on unknown id '$d'." }
            $indeg[$t.id]++
        }
    }
    $ordered = [System.Collections.ArrayList]@()
    $ready   = [System.Collections.ArrayList]@()
    foreach ($t in $Tasks) { if ($indeg[$t.id] -eq 0) { [void]$ready.Add($t.id) } }
    while ($ready.Count -gt 0) {
        $id = $ready[0]; $ready.RemoveAt(0)
        [void]$ordered.Add($byId[$id])
        foreach ($t in $Tasks) {
            if (@($t.depends_on) -contains $id) {
                $indeg[$t.id]--
                if ($indeg[$t.id] -eq 0) { [void]$ready.Add($t.id) }
            }
        }
    }
    if ($ordered.Count -ne $Tasks.Count) { throw 'Plan has a dependency cycle.' }
    return ,([array]$ordered)
}

function Get-TaskCostEstimate {
    <# Coarse v1 estimate: paid -> per-call figure; local/free/unknown -> 0. #>
    param([Parameter(Mandatory)][string]$Tier, [double]$PaidPerCall = 0.05)
    if ($Tier -eq 'paid') { return $PaidPerCall }
    return 0.0
}

function Test-BudgetExceeded {
    <# True when cumulative + this task's estimate would cross the cap. Null cap -> never. #>
    param([double]$CumulativeSpend, [double]$TaskEstimate, $BudgetCap)
    if ($null -eq $BudgetCap) { return $false }
    return (($CumulativeSpend + $TaskEstimate) -gt [double]$BudgetCap)
}

function Test-TaskDestructive {
    <# A node tagged reversible:false always interrupts. #>
    param([Parameter(Mandatory)]$Task)
    return ($Task.reversible -eq $false)
}
