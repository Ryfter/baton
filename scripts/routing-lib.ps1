#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing selector (Slice 1). Reads tools.yaml + fleet.yaml and ranks
  the candidates that can serve a capability, cheapest cost-tier first.
.DESCRIPTION
  Recommendation only — no dispatch (Slice 2) and no learned quality (Slice 3).
  See docs/superpowers/specs/2026-06-07-routing-s1-capability-selector-design.md.
#>

. "$PSScriptRoot/fleet-lib.ps1"   # for Read-Fleet + ConvertFrom-FleetValue

$script:DefaultToolsPath = (Join-Path $HOME '.claude/tools.yaml')

function Read-Tools {
    <# Parse tools.yaml into an array of tool hashtables. Flat schema (no env blocks). #>
    param([string]$Path = $script:DefaultToolsPath)
    if (-not (Test-Path $Path)) {
        throw "tools.yaml not found at $Path. Run scripts/bootstrap.ps1 to deploy the seed."
    }
    $tools = [System.Collections.ArrayList]@()
    $current = $null
    foreach ($rawLine in (Get-Content $Path)) {
        if ($rawLine -match '^\s*#') { continue }
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        if ($rawLine -match '^tools:\s*$') { continue }
        if ($rawLine -match '^(\s*)-\s+name:\s*(.+?)\s*$') {
            if ($current) { [void]$tools.Add($current) }
            $current = @{ name = (ConvertFrom-FleetValue $matches[2]) }
            continue
        }
        if (-not $current) { continue }
        if ($rawLine -match '^\s+([\w.-]+):\s*(.*?)\s*$') {
            $current[$matches[1]] = (ConvertFrom-FleetValue $matches[2])
        }
    }
    if ($current) { [void]$tools.Add($current) }
    return $tools.ToArray()
}

function Get-GeneralCapabilities {
    <# Read the top-level `general_capabilities: [a, b, c]` inline list from fleet.yaml.
       Returns string[] (empty if the key is absent). Mirrors Get-FleetResearchDefault. #>
    param([string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'))
    if (-not (Test-Path $FleetPath)) { return @() }
    foreach ($line in (Get-Content $FleetPath)) {
        if ($line -match '^\s*general_capabilities:\s*\[(.*)\]\s*$') {
            $inner = $matches[1].Trim()
            if (-not $inner) { return @() }
            return @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
        }
    }
    return @()
}

function Get-KnownCapabilities {
    <# Union of every tools.yaml capability + fleet.yaml general_capabilities. #>
    param(
        [string]$ToolsPath = $script:DefaultToolsPath,
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml')
    )
    $caps = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $ToolsPath) {
        foreach ($t in (Read-Tools -Path $ToolsPath)) {
            if ($t.capability) { [void]$caps.Add([string]$t.capability) }
        }
    }
    foreach ($g in (Get-GeneralCapabilities -FleetPath $FleetPath)) { [void]$caps.Add($g) }
    return @($caps | Select-Object -Unique)
}
