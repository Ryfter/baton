#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Maestro tick hook: run deterministic security scanner spine for due projects.
  No LM — spine only. Never walks Grimlore. Never seats Fable/Sol.
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [string]$DefaultRepo = '/Users/kev/Dev/Baton',
    [int]$MaxScans = 3,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'officers-lib.ps1')

$result = Invoke-SecurityDueScans -BatonHome $BatonHome -DefaultRepo $DefaultRepo -MaxScans $MaxScans
if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    if ($result.due -eq 0) {
        Write-Host 'maestro-security: no due projects'
    } else {
        foreach ($r in @($result.results)) {
            $st = if ($r.skipped) { "skip:$($r.reason)" } elseif ($r.ok) { 'ok' } else { "fail:$($r.reason)" }
            Write-Host "maestro-security: $($r.project) -> $st"
        }
    }
}

exit 0
