#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Inspect factory officers (scheduler / efficiency / vram / systems).
#>
[CmdletBinding()]
param(
    [ValidateSet('status', 'systems', 'vram', 'registry')][string]$Action = 'status',
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'officers-lib.ps1')

switch ($Action) {
    'registry' {
        Get-OfficerRegistry | ConvertTo-Json -Depth 6
    }
    'systems' {
        $inv = Get-SystemsInventory
        $path = Save-SystemsInventory -Inventory $inv -BatonHome $BatonHome
        [ordered]@{ inventory = $inv; path = $path; stt = (Get-SystemsPlacementAdvice -Kind stt -Inventory $inv); codegen = (Get-SystemsPlacementAdvice -Kind codegen -Inventory $inv) } | ConvertTo-Json -Depth 6
    }
    'vram' {
        Get-VramInventory -BatonHome $BatonHome | ConvertTo-Json -Depth 6
    }
    default {
        Get-OfficersDoctorLines -BatonHome $BatonHome | ForEach-Object { Write-Host $_ }
        $reg = Test-OfficerRegistry
        if (-not $reg.ok) { Write-Host "registry: $($reg.reason)"; exit 1 }
    }
}
