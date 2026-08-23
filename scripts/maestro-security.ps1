#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Maestro tick hook: run security scanner spine for due projects.
  Optional LM interpret when scanner finds signal. Deep Opus on residue + med/high.
  Never walks Grimlore. Never Fable/Sol.
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [string]$DefaultRepo = '/Users/kev/Dev/Baton',
    [string]$FleetPath = $(Join-Path $HOME '.baton/overnight/fleet.yaml'),
    [int]$MaxScans = 3,
    [int]$MaxDeepScans = 1,
    [switch]$Interpret,
    [switch]$InterpretOnlyOnSignal,
    [switch]$SeedFromRegistry,
    [switch]$DeepOnResidue,
    [switch]$NoRecordQuality,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'officers-lib.ps1')

$windows = Get-SchedulerWindowSnapshot -BatonHome $BatonHome
$result = Invoke-SecurityDueScans `
    -BatonHome $BatonHome `
    -DefaultRepo $DefaultRepo `
    -MaxScans $MaxScans `
    -MaxDeepScans $MaxDeepScans `
    -SeedFromRegistry:$SeedFromRegistry `
    -DoInterpret:$Interpret `
    -InterpretOnlyOnSignal:$InterpretOnlyOnSignal `
    -DeepOnResidue:$DeepOnResidue `
    -FleetPath $FleetPath `
    -Windows $windows

if (-not $NoRecordQuality) {
    [void](Record-SecurityScanQuality -BatchResult $result -BatonHome $BatonHome)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    if ($result.due -eq 0) {
        Write-Host 'maestro-security: no due projects'
    } else {
        foreach ($r in @($result.results)) {
            $phase = if ($r.phase) { "$($r.phase):" } else { '' }
            $st = if ($r.skipped) { "skip:$($r.reason)" } elseif ($r.ok) { 'ok' } else { "fail:$($r.reason)" }
            $ix = if ($r.interpret -and $r.interpret.ok) { ' +interpret' } else { '' }
            Write-Host "maestro-security: ${phase}$($r.project) -> $st$ix"
        }
        if ($result.deep -gt 0) {
            Write-Host "maestro-security: deep scans=$($result.deep)"
        }
    }
}

exit 0
