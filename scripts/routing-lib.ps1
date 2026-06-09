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
. "$PSScriptRoot/routing-learn.ps1"   # Slice 3 learning loop (ratings + learned quality + judge)

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

function Get-CostTierRank([string]$Tier) {
    switch ($Tier) {
        'local' { return 0 }
        'free'  { return 1 }
        'paid'  { return 2 }
        default { return 3 }   # unknown tiers sort last
    }
}

function Select-Capability {
    <# Return ranked candidates (tools + general models) that serve a capability.
       Cheapest cost-tier first; quality is unrated in Slice 1 (neutral 0.5).
       Recommendation only — no dispatch. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [ValidateSet('local','free','paid')][string]$MaxCostTier,
        [switch]$RequireLocal,
        [string]$ToolsPath = $script:DefaultToolsPath,
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml')
    )
    $candidates = [System.Collections.ArrayList]@()

    # 1. Specialized candidates from tools.yaml
    if (Test-Path $ToolsPath) {
        foreach ($t in (Read-Tools -Path $ToolsPath)) {
            if ($t.enabled -ne $true) { continue }
            if ([string]$t.capability -ne $Capability) { continue }
            $q = if ($null -ne $t.quality) { [double]$t.quality } else { 0.5 }
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$t.name; kind = [string]$t.kind; source = 'tools'
                cost_tier = [string]$t.cost_tier; quality = $q
                why = "specialized tool for $Capability ($($t.cost_tier))"
            })
        }
    }

    # 2. General candidates from fleet.yaml when the capability is a general one
    $general = Get-GeneralCapabilities -FleetPath $FleetPath
    if ($general -contains $Capability -and (Test-Path $FleetPath)) {
        foreach ($p in (Read-Fleet -Path $FleetPath)) {
            if ($p.enabled -ne $true) { continue }
            $q = if ($null -ne $p.quality) { [double]$p.quality } else { 0.5 }
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$p.name; kind = [string]$p.kind; source = 'fleet'
                cost_tier = [string]$p.cost_tier; quality = $q
                why = "general model for $Capability ($($p.cost_tier) tier)"
            })
        }
    }

    # 3. Filter by constraints
    $filtered = foreach ($c in $candidates) {
        if ($RequireLocal -and $c.cost_tier -ne 'local') { continue }
        if ($MaxCostTier -and (Get-CostTierRank $c.cost_tier) -gt (Get-CostTierRank $MaxCostTier)) { continue }
        $c
    }

    # 4. Rank: cost tier asc, then quality desc, then name. Attach a numeric score.
    $ranked = $filtered |
        Select-Object *, @{n='score'; e={ (Get-CostTierRank $_.cost_tier) - ($_.quality * 0.001) }} |
        Sort-Object @{e='score'}, @{e={ -$_.quality }}, @{e='name'}
    return ,([object[]]$ranked)
}
