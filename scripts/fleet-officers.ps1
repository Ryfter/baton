#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Inspect factory officers (scheduler / efficiency / vram / systems).
#>
[CmdletBinding()]
param(
    [ValidateSet('status', 'systems', 'vram', 'registry', 'security', 'profiles', 'scan')][string]$Action = 'status',
    [string]$RepoPath = '',
    [string]$Project = 'baton',
    [string]$FleetPath = $(Join-Path $HOME '.baton/overnight/fleet.yaml'),
    [switch]$Interpret,
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
    'security' {
        Get-SecurityRecipe -Project $Project -BatonHome $BatonHome | ConvertTo-Json -Depth 6
    }
    'scan' {
        if ([string]::IsNullOrWhiteSpace($RepoPath)) { $RepoPath = Split-Path -Parent $PSScriptRoot }
        $r = Invoke-SecurityProjectScan -Project $Project -RepoPath $RepoPath -BatonHome $BatonHome -Force `
            -DoInterpret:$Interpret -FleetPath $FleetPath
        if ($r.reason -eq 'forbidden-seat') { throw "refusing forbidden seat $($r.recipe.seat)" }
        [ordered]@{
            recipe = $r.recipe; scan = $r.scan; interpret = $r.interpret
            report = $r.report; ok = $r.ok; reason = $r.reason
        } | ConvertTo-Json -Depth 8
    }
    'profiles' {
        $root = Split-Path -Parent $PSScriptRoot
        Invoke-EfficiencyProfileReview -RepoRoot $root | ConvertTo-Json -Depth 6
    }
    default {
        Get-OfficersDoctorLines -BatonHome $BatonHome | ForEach-Object { Write-Host $_ }
        $reg = Test-OfficerRegistry
        if (-not $reg.ok) { Write-Host "registry: $($reg.reason)"; exit 1 }
    }
}
