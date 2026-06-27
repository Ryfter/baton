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
. "$PSScriptRoot/usage-lib.ps1"   # Sprint 2: Get-WorkerState/Get-ConserveMode for route-around
. "$PSScriptRoot/saturation-lib.ps1"   # d-wa-5 active saturation driver
. "$PSScriptRoot/effective-cost-lib.ps1"   # d060 learned-cost re-rank

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
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl'),
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl'),
        [string]$RunsRoot = (Join-Path (Get-BatonHome) 'runs')
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
                budget = $p.budget; saturate = $p.saturate; saturation_target = $p.saturation_target
                sat_util = $null
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

    # 3b. Usage governance (Sprint 2) + active saturation (d-wa-5).
    #     Route-around drops hard-stopped workers + down-ranks limited; saturation
    #     up-ranks an under-utilized opt-in budgeted worker (effective tier -1).
    #     Absent journal -> route-around no-op; saturation still applies (0 consumed).
    $usageRows = @()
    $conserve  = $false
    if (Get-Command Get-WorkerState -ErrorAction SilentlyContinue) {
        $usageRows = Read-UsageJournal -Path $UsagePath
        if (@($usageRows).Count -gt 0) {
            $conserve = Get-ConserveMode -Rows $usageRows
            $hardOut  = @('exhausted','cooling_down','waiting_for_reset')
            $filtered = foreach ($c in $filtered) {
                if ($c.source -ne 'fleet') { $c; continue }
                $st = (Get-WorkerState -Worker $c.name -Rows $usageRows).state
                if ($hardOut -contains $st) { continue }
                if ($st -eq 'limited') {
                    if ($conserve) { continue }
                    $c.quality = [double]$c.quality * 0.5   # soft down-rank
                }
                $c
            }
            if ($conserve) { $SelectionMode = 'economy' }
        }
        # Saturation boost: up-rank a surviving under-utilized opt-in budgeted worker.
        foreach ($c in $filtered) {
            if ($c.source -ne 'fleet') { continue }
            # Strict opt-in: only a literal boolean $true opts in. A non-canonical YAML
            # false token (no/off/n/0) parses as a string and would otherwise both skip
            # the guard AND read truthy in the [bool] sort key — normalize it to $false.
            if ($c.saturate -ne $true) { $c.saturate = $false; continue }
            $budget = if ($null -ne $c.budget) { [int]$c.budget } else { 0 }
            $target = if ($null -ne $c.saturation_target) { [double]$c.saturation_target } else { 99.9 }
            $st = (Get-WorkerState -Worker $c.name -Rows $usageRows).state
            $cu = Get-CandidateUtilization -Rows $usageRows -Worker $c.name -Budget $budget
            $decision = Get-SaturationDecision -Saturate $true -Budget $budget -Consumed $cu.consumed -Target $target -State $st -SelectionMode $SelectionMode -Conserve $conserve
            if ($decision.apply) {
                $c.saturate = $true
                $c.sat_util = $decision.utilization
                $c.why = $decision.reason
            } else {
                $c.saturate = $false
            }
        }
    }

    # 3c. Learned-cost re-rank (d060) — opt-in, economy-only, confidence-gated.
    $learnedOn = (Get-LearnedRoutingEnabled -FleetPath $FleetPath)
    $board = @()
    if ($learnedOn -and $SelectionMode -eq 'economy') {
        $records = Read-EffectiveCostRecords -RunsRoot $RunsRoot
        if (@($records).Count -gt 0) { $board = Get-WorkerEffectiveCost -Records $records }
    }
    $filtered = foreach ($c in $filtered) {
        $c | Add-Member -NotePropertyName learned_adjust -NotePropertyValue 0.0 -Force
        if ($learnedOn -and $SelectionMode -eq 'economy' -and @($board).Count -gt 0) {
            $ladj = (Get-LearnedCostAdjustment -Worker $c.name -Board $board)
            $c.learned_adjust = [double]$ladj.adjust
            if ($ladj.reason) { $c.why = "$($c.why); $($ladj.reason)" }
        }
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
            Select-Object *, @{n='score'; e={ (Get-LearnedTierRank $_.cost_tier ([bool]$_.saturate) ([double]$_.learned_adjust)) - ($_.quality * 0.001) }} |
            Sort-Object `
                @{e={ Get-LearnedTierRank $_.cost_tier ([bool]$_.saturate) ([double]$_.learned_adjust) }}, `
                @{e={ if ([bool]$_.saturate) { [double]$_.sat_util } else { 0 } }}, `
                @{e={ -$_.quality }}, `
                @{e='name'}
    }
    return ,([object[]]$ranked)
}
