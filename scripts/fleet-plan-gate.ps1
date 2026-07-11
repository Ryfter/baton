#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:plan-gate runner. Runs a competitive review of a plan (task DAG)
  BEFORE any labor runs and prints an accept/revise/reject verdict with
  deduped findings + a revise brief. Sibling of fleet-gate.ps1 (Acceptance
  Gate), which reviews finished work instead of a not-yet-executed plan.
  Advisory only — never blocks.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'run',
    [string]$Goal,
    [string]$Plan,
    [string]$Reviewers,
    [switch]$Json,
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$ToolsPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'tools.yaml' } else { Join-Path $HOME '.baton/tools.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'plan-gate-lib.ps1')
try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }

switch ($Subcommand) {
    'run' {
        if (-not $Goal) { [Console]::Error.WriteLine('run requires --goal "<text>" (what the plan is meant to accomplish)'); exit 2 }
        if (-not $Plan) { [Console]::Error.WriteLine('run requires --plan <path to plan.json>'); exit 2 }
        if (-not (Test-Path -LiteralPath $Plan)) { [Console]::Error.WriteLine("run: plan file not found: $Plan"); exit 2 }
        $planJson = Get-Content -LiteralPath $Plan -Raw
        $revList = if ($Reviewers) { @($Reviewers -split '\s*,\s*' | Where-Object { $_ }) } else { @() }
        $callArgs = @{ Goal = $Goal; PlanJson = $planJson; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
        if ($revList.Count) { $callArgs['Reviewers'] = $revList }
        # Test seam: BATON_PLANGATE_TEST_DISPATCH names a .ps1 file defining
        # Invoke-TestPlanGateDispatch($name, $prompt); dot-source it and wire
        # a -Dispatcher scriptblock so the suite never calls a real model.
        if ($env:BATON_PLANGATE_TEST_DISPATCH) {
            . $env:BATON_PLANGATE_TEST_DISPATCH
            $callArgs['Dispatcher'] = { param($n, $p) Invoke-TestPlanGateDispatch $n $p }
        }
        $res = Invoke-PlanGate @callArgs
        if ($Json) {
            ConvertTo-Json -InputObject $res -Depth 8
        } else {
            Write-Host (Format-PlanGateReport -Result $res)
            if ($res.verdict -ne 'accept') {
                Write-Host '---'
                Write-Host $res.revise_brief
            }
            if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter }
        }
        if ($res.verdict -eq 'accept') { exit 0 } else { exit 1 }
    }
    default { [Console]::Error.WriteLine("unknown subcommand: $Subcommand (use run)"); exit 2 }
}
