#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Maestro tick hook: run security scanner spine for due projects.
  Optional LM interpret when scanner finds signal. Never walks Grimlore. Never Fable/Sol.
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [string]$DefaultRepo = '/Users/kev/Dev/Baton',
    [string]$FleetPath = $(Join-Path $HOME '.baton/overnight/fleet.yaml'),
    [int]$MaxScans = 3,
    [switch]$Interpret,
    [switch]$InterpretOnlyOnSignal,
    [switch]$SeedFromRegistry,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'officers-lib.ps1')

$windows = Get-SchedulerWindowSnapshot -BatonHome $BatonHome
$result = Invoke-SecurityDueScans `
    -BatonHome $BatonHome `
    -DefaultRepo $DefaultRepo `
    -MaxScans $MaxScans `
    -SeedFromRegistry:$SeedFromRegistry `
    -DoInterpret:$Interpret `
    -InterpretOnlyOnSignal:$InterpretOnlyOnSignal `
    -FleetPath $FleetPath `
    -Windows $windows

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    if ($result.due -eq 0) {
        Write-Host 'maestro-security: no due projects'
    } else {
        foreach ($r in @($result.results)) {
            $st = if ($r.skipped) { "skip:$($r.reason)" } elseif ($r.ok) { 'ok' } else { "fail:$($r.reason)" }
            $ix = if ($r.interpret -and $r.interpret.ok) { ' +interpret' } elseif ($r.interpret -and $r.interpret.skipped) { '' } else { '' }
            Write-Host "maestro-security: $($r.project) -> $st$ix"
        }
    }
}

exit 0
