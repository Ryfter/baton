#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One Maestro scheduler tick: admit queued jobs, then fire admitted jobs (parallel fan-out).
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [string]$FleetGo = '/Users/kev/Dev/Baton/scripts/fleet-go.ps1',
    [string]$DefaultRepo = '/Users/kev/Dev/Baton',
    [string]$FleetPath = $(Join-Path $HOME '.baton/overnight/fleet.yaml'),
    [int]$MaxParallel = 8
)

$ErrorActionPreference = 'Stop'
$admitScript = Join-Path $PSScriptRoot 'maestro-admit.ps1'
$fireScript = Join-Path $PSScriptRoot 'maestro-fire.ps1'

& pwsh -NoProfile -File $admitScript -BatonHome $BatonHome -MaxParallel $MaxParallel | Out-Null
& pwsh -NoProfile -File $fireScript `
    -BatonHome $BatonHome `
    -FleetGo $FleetGo `
    -DefaultRepo $DefaultRepo `
    -FleetPath $FleetPath `
    -MaxParallel $MaxParallel

exit $LASTEXITCODE
