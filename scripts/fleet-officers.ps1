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
        $recipe = Get-SecurityRecipe -Project $Project -BatonHome $BatonHome
        if (Test-SecuritySeatForbidden -Seat $recipe.seat) { throw "refusing forbidden seat $($recipe.seat)" }
        $scan = Invoke-SecurityScannerSpine -RepoPath $RepoPath
        $touched = $null
        try { $touched = [datetime](& git -C $RepoPath log -1 --format=%cI 2>$null) } catch { }
        $upd = @{ Project = $Project; BatonHome = $BatonHome }
        if ($touched) { $upd.Touched = $touched }
        [void](Update-SecurityScale @upd)
        $dir = Join-Path $BatonHome 'officers/security-runs'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        $path = Join-Path $dir "$Project-$stamp.json"
        [ordered]@{ recipe = $recipe; scan = $scan } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        [ordered]@{ recipe = $recipe; scan = $scan; report = $path } | ConvertTo-Json -Depth 8
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
