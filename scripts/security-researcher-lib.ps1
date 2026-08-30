#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Security-researcher scheduled instrument — sliding-scale cadence state (baton-d133 §5).
.DESCRIPTION
  Deterministic spine: track per-project heat (hot/warm/cold) and emit due projects.
  Scanners + LM interpretation land in later wedges; this wedge owns cadence math.
#>
. (Join-Path $PSScriptRoot 'baton-home.ps1')
. (Join-Path $PSScriptRoot 'instruments-lib.ps1')

$script:SecurityHotDays = 1
$script:SecurityWarmDays = 7
$script:SecurityColdDays = 28

function Get-SecurityResearcherStatePath {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'officers/security-researcher-state.json')
}

function Read-SecurityResearcherState {
    param([string]$BatonHome = (Get-BatonHome))
    $path = Get-SecurityResearcherStatePath -BatonHome $BatonHome
    $empty = [ordered]@{ schema_version = 1; projects = [ordered]@{}; last_tick = $null }
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $projects = [ordered]@{}
        if ($doc.projects) {
            foreach ($prop in $doc.projects.PSObject.Properties) {
                $projects[$prop.Name] = [ordered]@{
                    last_run   = [string]$prop.Value.last_run
                    last_clean = [string]$prop.Value.last_clean
                    heat       = [string]$prop.Value.heat
                }
            }
        }
        return [ordered]@{
            schema_version = [int]($doc.schema_version ?? 1)
            projects       = $projects
            last_tick      = [string]$doc.last_tick
        }
    } catch {
        return $empty
    }
}

function Write-SecurityResearcherState {
    param(
        [Parameter(Mandatory)]$State,
        [string]$BatonHome = (Get-BatonHome)
    )
    $path = Get-SecurityResearcherStatePath -BatonHome $BatonHome
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($State | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function ConvertTo-SecurityUtc {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        return [datetime]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
    } catch { return $null }
}

function Get-SecurityProjectTouchUtc {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$BatonHome = (Get-BatonHome)
    )
    $recPath = Join-Path $BatonHome "projects/$ProjectId/project.json"
    if (-not (Test-Path -LiteralPath $recPath)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json
        foreach ($key in @('last_touched_at', 'updated_at', 'last_activity_at')) {
            if ($doc.PSObject.Properties[$key]) {
                $dt = ConvertTo-SecurityUtc $doc.$key
                if ($dt) { return $dt }
            }
        }
    } catch { }
    return $null
}

function Get-SecurityProjectHeat {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        $State,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$BatonHome = (Get-BatonHome)
    )
    $touch = Get-SecurityProjectTouchUtc -ProjectId $ProjectId -BatonHome $BatonHome
    $rec = $null
    if ($State.projects -and $State.projects.Contains($ProjectId)) { $rec = $State.projects[$ProjectId] }
    $lastRun = if ($rec) { ConvertTo-SecurityUtc $rec.last_run } else { $null }
    if ($touch -and $lastRun -and $touch -gt $lastRun) { return 'hot' }
    if ($touch -and (-not $lastRun -or ($Now - $touch).TotalDays -le $script:SecurityWarmDays)) { return 'warm' }
    if ($touch -and ($Now - $touch).TotalDays -ge $script:SecurityColdDays) { return 'cold' }
    return 'warm'
}

function Get-SecurityResearcherDueProjects {
    param(
        [string]$BatonHome = (Get-BatonHome),
        [datetime]$Now = [datetime]::UtcNow
    )
    $state = Read-SecurityResearcherState -BatonHome $BatonHome
    $projectsDir = Join-Path $BatonHome 'projects'
    if (-not (Test-Path -LiteralPath $projectsDir)) { return @() }
    $due = [System.Collections.ArrayList]@()
    foreach ($dir in Get-ChildItem -LiteralPath $projectsDir -Directory) {
        $id = $dir.Name
        $heat = Get-SecurityProjectHeat -ProjectId $id -State $state -Now $Now -BatonHome $BatonHome
        $rec = if ($state.projects.Contains($id)) { $state.projects[$id] } else { $null }
        $lastRun = if ($rec) { ConvertTo-SecurityUtc $rec.last_run } else { $null }
        $cadenceDays = switch ($heat) {
            'hot' { 1 }
            'warm' { 7 }
            'cold' { 28 }
            default { 7 }
        }
        $overdue = (-not $lastRun) -or (($Now - $lastRun).TotalDays -ge $cadenceDays)
        if (-not $overdue) { continue }
        [void]$due.Add([ordered]@{
            project = $id
            heat    = $heat
            cadence = "${cadenceDays}d"
            tags    = if ($heat -eq 'cold') { @('excess_capacity') } else { @() }
        })
    }
    return @($due)
}

function Invoke-SecurityResearcherTick {
    param(
        [string]$BatonHome = (Get-BatonHome),
        [datetime]$Now = [datetime]::UtcNow,
        [switch]$WriteState
    )
    $inst = Get-InstrumentByName -Name 'security-researcher'
    $due = @(Get-SecurityResearcherDueProjects -BatonHome $BatonHome -Now $Now)
    $state = Read-SecurityResearcherState -BatonHome $BatonHome
    if ($WriteState) {
        foreach ($row in $due) {
            $id = [string]$row.project
            if (-not $state.projects.Contains($id)) {
                $state.projects[$id] = [ordered]@{ last_run = $null; last_clean = $null; heat = [string]$row.heat }
            }
            $state.projects[$id].last_run = $Now.ToString('o')
            $state.projects[$id].heat = [string]$row.heat
        }
        $state.last_tick = $Now.ToString('o')
        Write-SecurityResearcherState -State $state -BatonHome $BatonHome | Out-Null
    }
    return [ordered]@{
        instrument = if ($inst) { [string]$inst.name } else { 'security-researcher' }
        seat       = if ($inst) { [string]$inst.default_seat } else { 'openrouter-glm' }
        due        = $due
        count      = $due.Count
    }
}
