#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Read helpers for references/instruments.yaml (baton-d133 registry wedge).
.DESCRIPTION
  Complements fleet.yaml (LM seats) and tools.yaml (deterministic tools).
  Maestro and Conductors resolve instrument rows by name or capability.
#>
. (Join-Path $PSScriptRoot 'baton-home.ps1')
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')   # ConvertFrom-FleetValue

function Get-InstrumentsRegistryPath {
    param(
        [string]$BatonHome = (Get-BatonHome),
        [string]$RepoRoot
    )
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    $homePath = Join-Path $BatonHome 'instruments.yaml'
    if (Test-Path -LiteralPath $homePath) { return $homePath }
    return (Join-Path $RepoRoot 'references/instruments.yaml')
}

function Read-Instruments {
    <# Parse instruments.yaml into an array of instrument hashtables. #>
    param([string]$Path = (Get-InstrumentsRegistryPath))
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "instruments.yaml not found at $Path"
    }
    $rows = [System.Collections.ArrayList]@()
    $current = $null
    foreach ($rawLine in (Get-Content -LiteralPath $Path)) {
        if ($rawLine -match '^\s*#') { continue }
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        if ($rawLine -match '^instruments:\s*$') { continue }
        if ($rawLine -match '^(\s*)-\s+name:\s*(.+?)\s*$') {
            if ($current) { [void]$rows.Add($current) }
            $current = @{ name = (ConvertFrom-FleetValue $matches[2]) }
            continue
        }
        if (-not $current) { continue }
        if ($rawLine -match '^\s+([\w.-]+):\s*(.*?)\s*$') {
            $current[$matches[1]] = (ConvertFrom-FleetValue $matches[2])
        }
    }
    if ($current) { [void]$rows.Add($current) }
    return $rows.ToArray()
}

function Get-InstrumentByName {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path = (Get-InstrumentsRegistryPath)
    )
    $want = [string]$Name
    foreach ($row in (Read-Instruments -Path $Path)) {
        if ([string]$row.name -eq $want) { return $row }
    }
    return $null
}

function Test-InstrumentSeatReady {
    param(
        [Parameter(Mandatory)]$Instrument,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml')
    )
    $kind = [string]$Instrument.kind
    if ($kind -eq 'officer') { return $true }
    $seat = [string]$Instrument.default_seat
    if ([string]::IsNullOrWhiteSpace($seat)) { return $false }
    if ($kind -eq 'tool') {
        if (-not (Test-Path -LiteralPath $ToolsPath)) { return $false }
        . (Join-Path $PSScriptRoot 'routing-lib.ps1')
        return @((Read-Tools -Path $ToolsPath) | Where-Object {
            [string]$_.name -eq $seat -and [string]$_.enabled -ne 'false'
        }).Count -gt 0
    }
    . (Join-Path $PSScriptRoot 'maestro-lib.ps1')
    return (Test-MaestroInstrumentReady -Name $seat)
}

function Get-EnabledInstruments {
    param([string]$Path = (Get-InstrumentsRegistryPath))
    return @((Read-Instruments -Path $Path) | Where-Object {
        $null -ne $_ -and [string]$_.enabled -ne 'false'
    })
}

function Resolve-InstrumentForJob {
    <# Resolve a Maestro job row to a registry instrument (by name or capability). #>
    param(
        [Parameter(Mandatory)]$Job,
        [string]$Path = (Get-InstrumentsRegistryPath)
    )
    $rows = @(Get-EnabledInstruments -Path $Path)
    if ($Job.PSObject.Properties['instrument'] -and -not [string]::IsNullOrWhiteSpace([string]$Job.instrument)) {
        $hit = @($rows | Where-Object { [string]$_.name -eq [string]$Job.instrument })[0]
        if ($hit) { return $hit }
    }
    $cap = if ($Job.PSObject.Properties['capability']) { [string]$Job.capability } else { '' }
    if ($cap) {
        $hit = @($rows | Where-Object { [string]$_.capability -eq $cap })[0]
        if ($hit) { return $hit }
    }
    return $null
}

function Get-UsableInstrumentSeats {
    <# Enabled instruments whose default seat (or officer kind) is ready. #>
    param(
        [string]$BatonHome = (Get-BatonHome),
        [string]$Path = (Get-InstrumentsRegistryPath -BatonHome $BatonHome)
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $fleetPath = Join-Path $BatonHome 'fleet.yaml'
    $toolsPath = Join-Path $BatonHome 'tools.yaml'
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($row in (Get-EnabledInstruments -Path $Path)) {
        if (-not (Test-InstrumentSeatReady -Instrument $row -FleetPath $fleetPath -ToolsPath $toolsPath)) { continue }
        $kind = [string]$row.kind
        if ($kind -eq 'officer') {
            if (-not $out.Contains([string]$row.name)) { [void]$out.Add([string]$row.name) }
            continue
        }
        $seat = [string]$row.default_seat
        if ($seat -and -not $out.Contains($seat)) { [void]$out.Add($seat) }
    }
    return @($out)
}

function Get-InstrumentInitBrief {
    param(
        [Parameter(Mandatory)]$Instrument,
        [string]$RepoRoot
    )
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    $rel = [string]$Instrument.init_brief
    if ([string]::IsNullOrWhiteSpace($rel)) { return '' }
    $path = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $RepoRoot $rel }
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return (Get-Content -LiteralPath $path -Raw)
}
