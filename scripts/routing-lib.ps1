#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing selector (Slice 1). Reads tools.yaml + fleet.yaml and ranks
  the candidates that can serve a capability, cheapest cost-tier first.
.DESCRIPTION
  Recommendation only — no dispatch (Slice 2) and no learned quality (Slice 3).
  See docs/superpowers/specs/2026-06-07-routing-s1-capability-selector-design.md.
#>

. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"   # for Read-Fleet + ConvertFrom-FleetValue
. "$PSScriptRoot/routing-learn.ps1"   # Slice 3 learning loop (ratings + learned quality + judge)

$script:DefaultToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml')

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
    param([string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'))
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

function Get-CapabilityFloors {
    <# Top-level `capability_floors:` block map (capability -> min context tokens).
       A claim is filtered when the provider's loaded context is KNOWN and below
       the floor; unknown context never disqualifies. Returns hashtable. #>
    param([string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'))
    $floors = @{}
    if (-not (Test-Path $FleetPath)) { return $floors }
    $inBlock = $false
    foreach ($line in (Get-Content $FleetPath)) {
        if ($line -match '^capability_floors:\s*$') { $inBlock = $true; continue }
        if (-not $inBlock) { continue }
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') { continue }
        if ($line -match '^\s+([\w.-]+):\s*(\d+)') { $floors[$matches[1]] = [int]$matches[2]; continue }
        $inBlock = $false   # dedented to the next top-level key — block over
    }
    return $floors
}

function Get-KnownCapabilities {
    <# Union of every tools.yaml capability + fleet.yaml general_capabilities. #>
    param(
        [string]$ToolsPath = $script:DefaultToolsPath,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')
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
        [ValidateSet('economy','champion')][string]$SelectionMode = 'economy',
        [switch]$RequireLocal,
        [string]$ToolsPath = $script:DefaultToolsPath,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$RatingsPath = (Join-Path $HOME '.claude/knowledge/universal/routing-ratings.jsonl'),
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl')
    )
    $candidates = [System.Collections.ArrayList]@()

    # 1. Specialized candidates from tools.yaml
    if (Test-Path $ToolsPath) {
        foreach ($t in (Read-Tools -Path $ToolsPath)) {
            if ($t.enabled -ne $true) { continue }
            if ([string]$t.capability -ne $Capability) { continue }
            $prior = if ($null -ne $t.quality) { [double]$t.quality } else { 0.5 }
            $detail = Get-CapabilityQualityDetail -Capability $Capability -Candidate ([string]$t.name) -Prior $prior -JournalPath $JournalPath -RatingsPath $RatingsPath
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$t.name; kind = [string]$t.kind; source = 'tools'
                cost_tier = [string]$t.cost_tier; quality = $detail.quality
                quality_detail = $detail
                role = $t.role; platform = $t.platform   # Slice B passthrough (null when absent)
                why = "specialized tool for $Capability ($($t.cost_tier))"
            })
        }
    }

    # 2. Fleet candidates — claims-aware. A provider WITH a `capabilities:` list is
    #    a candidate for exactly those (even non-general ones, e.g. judge); a provider
    #    WITHOUT the field keeps the blanket general_capabilities grant (frontier CLIs).
    #    Context floors filter claims whose loaded context is known-too-small.
    $general = Get-GeneralCapabilities -FleetPath $FleetPath
    $floors  = Get-CapabilityFloors -FleetPath $FleetPath
    if (Test-Path $FleetPath) {
        foreach ($p in (Read-Fleet -Path $FleetPath)) {
            if ($p.enabled -ne $true) { continue }
            $claims = $p.capabilities
            $isCandidate = if ($null -ne $claims) { @($claims) -contains $Capability }
                           else { $general -contains $Capability }
            if (-not $isCandidate) { continue }
            if ($floors.ContainsKey($Capability) -and $p.context) {
                if ([int]$p.context -lt $floors[$Capability]) { continue }
            }
            $prior = if ($null -ne $p.quality) { [double]$p.quality } else { 0.5 }
            $detail = Get-CapabilityQualityDetail -Capability $Capability -Candidate ([string]$p.name) -Prior $prior -JournalPath $JournalPath -RatingsPath $RatingsPath
            $why = if ($null -ne $claims) { "claims $Capability ($($p.cost_tier) tier)" }
                   else { "general model for $Capability ($($p.cost_tier) tier)" }
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$p.name; kind = [string]$p.kind; source = 'fleet'
                cost_tier = [string]$p.cost_tier; quality = $detail.quality
                quality_detail = $detail
                role = $p.role; platform = $p.platform
                why = $why
            })
        }
    }

    # 3. Filter by constraints
    $filtered = foreach ($c in $candidates) {
        if ($RequireLocal -and $c.cost_tier -ne 'local') { continue }
        if ($MaxCostTier -and (Get-CostTierRank $c.cost_tier) -gt (Get-CostTierRank $MaxCostTier)) { continue }
        $c
    }

    # 4. Rank. economy: cost tier asc, quality desc ("smallest that clears the bar").
    #    champion: quality desc, cost tier asc tiebreak ("just the best" — BoB slot).
    if ($SelectionMode -eq 'champion') {
        $ranked = $filtered |
            Select-Object *, @{n='score'; e={ -$_.quality + ((Get-CostTierRank $_.cost_tier) * 0.001) }} |
            Sort-Object @{e={ -$_.quality }}, @{e={ Get-CostTierRank $_.cost_tier }}, @{e='name'}
    } else {
        $ranked = $filtered |
            Select-Object *, @{n='score'; e={ (Get-CostTierRank $_.cost_tier) - ($_.quality * 0.001) }} |
            Sort-Object @{e='score'}, @{e={ -$_.quality }}, @{e='name'}
    }
    return ,([object[]]$ranked)
}
