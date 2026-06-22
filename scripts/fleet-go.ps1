#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:go runner. Turns a natural-language goal into a planned, guarded,
  full-auto run: plan DAG -> walk under budget + destructive guards -> ledgers +
  report under BATON_HOME/runs/<run-id>/.
.NOTES
  The Claude session is the live Conductor; this CLI is its deterministic engine.
#>
param(
    [string]$Goal,
    [string]$Text,
    [double]$Budget,
    [switch]$Json,
    [string]$GateArtifact,
    [string]$GateDiff,
    [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$ToolsPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'tools.yaml' } else { Join-Path $HOME '.baton/tools.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'conductor-lib.ps1')

$theGoal = @($Goal, $Text | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($theGoal)) { Write-Error 'Provide a goal via -Goal "<text>" (or -Text).'; exit 2 }

$runDir = Initialize-RunDir -RunId (New-RunId)

$go = @{ Goal = $theGoal; RunDir = $runDir; MaxCostTier = $MaxCostTier; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
if ($PSBoundParameters.ContainsKey('Budget')) { $go['BudgetCap'] = $Budget }

# Test seams: a canned plan and/or forced-success spawner so the suite never calls a model.
if ($env:BATON_GO_TEST_PLAN) {
    $canned = $env:BATON_GO_TEST_PLAN
    $go['Planner'] = { param($g) $p = ConvertTo-PlanObject -RawStdout $canned; if ($p) { $p.goal = $g }; $p }.GetNewClosure()
}
if ($env:BATON_GO_TEST_SPAWN -eq '1') {
    $go['Spawner'] = { param($task) @{ ok = $true; spend = 0.0; chose = 'test-stub'; why = "ran $($task.id)"; alternatives = @() } }
}

if ($PSBoundParameters.ContainsKey('GateArtifact')) { $go['GateArtifact'] = $GateArtifact }
if ($PSBoundParameters.ContainsKey('GateDiff')) { $go['GateDiff'] = $GateDiff }
# Test seam: a canned gate verdict so the suite never calls real reviewers.
if ($env:BATON_GO_TEST_GATE) {
    $cannedVerdict = $env:BATON_GO_TEST_GATE
    $go['Gater'] = { param($art, $goal) @{ verdict = $cannedVerdict; reason = 'test-stub verdict'; counts = @{ critical = 0; important = 0; minor = 0 }; polish_brief = 'test brief'; findings = @(); reviews = @(); unparsed = @() } }.GetNewClosure()
    if (-not $go.ContainsKey('GateArtifact')) { $go['GateArtifact'] = 'test artifact' }
}

$result = Invoke-Conductor @go

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    Write-Host $result.report
    Write-Host ""
    Write-Host "Status: $($result.status)  ·  spend $('{0:0.00}' -f $result.spend)  ·  $($result.run_dir)"
    if ($result.status -like 'interrupted-*') {
        Write-Host "Paused at $($result.pending_task_id). Review, then resume to continue past this guard."
    }
}
