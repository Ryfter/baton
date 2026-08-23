#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:security-researcher — scheduled security sweep cadence (sliding scale).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('due','tick','state')][string]$Action = 'due',
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [switch]$WriteState,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'security-researcher-lib.ps1')

switch ($Action) {
    'state' {
        $out = Read-SecurityResearcherState -BatonHome $BatonHome
    }
    'tick' {
        $out = Invoke-SecurityResearcherTick -BatonHome $BatonHome -WriteState:($WriteState -or $true)
    }
    default {
        $out = [ordered]@{
            due = @(Get-SecurityResearcherDueProjects -BatonHome $BatonHome)
        }
    }
}

if ($Json) { $out | ConvertTo-Json -Depth 6 } else {
    if ($Action -eq 'due') {
        foreach ($row in @($out.due)) {
            Write-Host ("{0} heat={1} cadence={2}" -f $row.project, $row.heat, $row.cadence)
        }
    } else {
        $out | ConvertTo-Json -Depth 6
    }
}
exit 0
